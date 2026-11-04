defmodule Elia.Agent.Session do
  @moduledoc """
  One conversation: owns the message history, runs `Elia.Agent.Loop` in a
  task, gates tool approvals and broadcasts progress on
  `Elia.Agent.topic(id)` as `{:agent, id, event}`. History is saved with
  `Elia.Store` after every change and reloaded when the session restarts.

  The session keeps the **full** history (COMPACT-1) and compacts it when a turn
  starts and the request exceeds the trigger (COMPACT-5, COMPACT-6). The loop is
  handed that history and derives the smaller **request view** from it at every
  step with `Elia.LLM.Compaction` (COMPACT-2, COMPACT-29), telling the session
  when its mid-turn pass advances so the state it owns stays the one the model
  was sent.

  Events: `{:message, message}`, `{:delta, :text | :reasoning, text}`,
  `{:notice, text}`, `{:status, status}`, `{:tool_status, call_id, status}`,
  `{:usage, usage}`, `{:compaction, state}`, `{:error, text}` (a stop, whose
  transcript message is STOP-1's, STOP-4),
  `{:reset, messages}`, `{:model, selection}`, `{:auto_approve, names}`,
  `{:jail, on?}`, `{:limits, limits}`, `{:title, title}`, `{:done, on?}`,
  `{:paused, message}`, `{:task, metadata}`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Elia.LLM.{Compaction, Context, Message}

  defstruct [
    :id,
    # The project the chat belongs to (PROJ-9): a `%{id, name, folder, harness?}`.
    :project,
    # The workspace root of this chat (PROJ-12): for a chat in Elia's own
    # project its own git worktree (DEPLOY-1), else the project's folder.
    :workspace,
    :task,
    # The turn this session is running: `%{id, started_at}` while one is in
    # flight, `nil` otherwise. It is saved with the chat so that a later session
    # can see that a restart cut the turn short (INTR-1, STORE-30).
    :turn,
    :turn_start,
    # The chat's own title (TITLE-1, STORE-32), nil when it has none and its
    # title is the first user message (STORE-7).
    :title,
    # The chat's own model selection (MODEL-1); nil until chosen or pinned.
    :selection,
    # Sub-task metadata when the chat was started by `spawn_task` (STORE-16).
    :task_meta,
    messages: [],
    status: :idle,
    # The chat's compaction state (COMPACT-24): how far the ladder has gone, the
    # summary, the ledger, the pins and the chat's own options. It is the single
    # source of truth for the request view; the loop's mid-turn pass reports back
    # into it (COMPACT-29).
    compaction: %Compaction{},
    # Tool names the user lets run without asking in this chat (APPR-8).
    auto_approve: MapSet.new(),
    # Whether this chat's commands run in the jail (ISOL-16): on by default,
    # and the host's own switch can only turn it off (ISOL-20).
    jail: true,
    # This chat's turn limits (LIMIT-1, LIMIT-2): a step limit, a time budget, a
    # token budget and whether a limit pauses the turn. Empty means the loop's
    # own default.
    limits: %{max_steps: nil, max_minutes: nil, max_tokens: nil, pause_on_limit: false},
    # call_id => :awaiting_approval | :awaiting_input | :answered | :running | :done
    tool_status: %{},
    # Provider-reported usage of the last completed model request (CTX-6).
    last_usage: nil,
    approval: nil,
    # The questions the turn is waiting on (SESS-34, ASK-6): {loop pid,
    # %{call_id => answer | nil}}. nil when none is open.
    input: nil,
    # The message of a turn paused at a limit (SESS-27), nil when not paused.
    pause: nil,
    loop_opts: [],
    persist: true,
    # Whether the chat is marked done (DONE-1, STORE-34): its work has landed
    # and it needs nothing more, though a message still continues it (DONE-8).
    done: false
  ]

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {Elia.Agent.Registry, id}}

  @impl true
  def init(opts) do
    persist = Keyword.get(opts, :persist, true)
    loop_opts = Keyword.get(opts, :loop_opts, [])
    project = opts[:project] || load_project(opts[:id], persist)

    state = %__MODULE__{
      id: opts[:id],
      project: project,
      workspace:
        opts[:workspace] || Keyword.get(loop_opts, :workspace) ||
          Elia.Deploy.workspace(project, opts[:id]),
      loop_opts: loop_opts,
      persist: persist,
      messages: if(persist, do: Elia.Store.load(opts[:id]), else: []),
      selection: opts[:selection] || if(persist, do: Elia.Store.load_model(opts[:id])),
      task_meta: opts[:task] || if(persist, do: Elia.Store.load_task(opts[:id])),
      compaction: initial_compaction(opts[:id], persist, opts[:compaction]),
      jail: initial_jail(opts[:id], persist, opts[:jail]),
      limits: initial_limits(opts[:id], persist, opts[:limits]),
      title: if(persist, do: Elia.Store.load_title(opts[:id])),
      done: if(persist, do: Elia.Store.load_done(opts[:id]), else: false)
    }

    # APPR-14: whether the chat is new is only known once its messages are
    # loaded, so the default set is worked out here.
    state = %{state | auto_approve: initial_auto_approve(state, opts[:auto_approve])}

    # SESS-21: tool calls the app stopped in the middle of never got a result.
    state = close_dangling_tool_calls(state, "The app restarted while this tool was running.")
    # INTR-3: and if the chat still carried a turn record, that turn was cut
    # short by the restart, so the chat says so.
    {:ok, note_interrupted_turn(state)}
  end

  @impl true
  # SESS-15: upgrade state from before `:selection`, `:auto_approve`, `:task_meta`,
  # `:project`, `:workspace`, `:compaction`, `:pause`, `:jail`, `:limits`,
  # `:turn` (INTR-1), `:title`, `:input` (ASK) or `:done` (DONE-1) existed (a
  # session that outlived a hot reload). Fields it already has are kept; `:turn`
  # is not loaded from disk, since it belongs to the process that is running the
  # turn.
  def handle_call(msg, from, state)
      when not is_map_key(state, :selection) or not is_map_key(state, :auto_approve) or
             not is_map_key(state, :task_meta) or not is_map_key(state, :project) or
             not is_map_key(state, :workspace) or not is_map_key(state, :compaction) or
             not is_map_key(state, :pause) or not is_map_key(state, :jail) or
             not is_map_key(state, :limits) or not is_map_key(state, :turn) or
             not is_map_key(state, :title) or not is_map_key(state, :input) or
             not is_map_key(state, :done) do
    upgraded = Map.merge(%__MODULE__{}, Map.from_struct(state))

    upgraded =
      if is_map_key(state, :project),
        do: upgraded,
        else: %{upgraded | project: load_project(upgraded.id, upgraded.persist)}

    upgraded =
      if is_map_key(state, :workspace),
        do: upgraded,
        else: %{upgraded | workspace: Elia.Deploy.workspace(upgraded.project, upgraded.id)}

    upgraded =
      if is_map_key(state, :task_meta),
        do: upgraded,
        else: %{
          upgraded
          | task_meta: if(upgraded.persist, do: Elia.Store.load_task(upgraded.id))
        }

    upgraded =
      if is_map_key(state, :selection),
        do: upgraded,
        else: %{
          upgraded
          | selection: if(upgraded.persist, do: Elia.Store.load_model(upgraded.id))
        }

    upgraded =
      if is_map_key(state, :auto_approve),
        do: upgraded,
        else: %{upgraded | auto_approve: initial_auto_approve(upgraded, nil)}

    upgraded =
      if is_map_key(state, :compaction),
        do: upgraded,
        else: %{upgraded | compaction: initial_compaction(upgraded.id, upgraded.persist, nil)}

    upgraded =
      if is_map_key(state, :jail),
        do: upgraded,
        else: %{upgraded | jail: initial_jail(upgraded.id, upgraded.persist, nil)}

    upgraded =
      if is_map_key(state, :limits),
        do: upgraded,
        else: %{upgraded | limits: initial_limits(upgraded.id, upgraded.persist, nil)}

    upgraded =
      if is_map_key(state, :title),
        do: upgraded,
        else: %{upgraded | title: if(upgraded.persist, do: Elia.Store.load_title(upgraded.id))}

    upgraded =
      if is_map_key(state, :done),
        do: upgraded,
        else: %{
          upgraded
          | done: if(upgraded.persist, do: Elia.Store.load_done(upgraded.id), else: false)
        }

    handle_call(msg, from, upgraded)
  end

  def handle_call(:snapshot, _from, state) do
    snapshot =
      Map.take(state, [
        :id,
        :messages,
        :status,
        :tool_status,
        :last_usage,
        :selection,
        :project,
        :compaction,
        :pause,
        :jail,
        :limits,
        :title,
        :done
      ])
      |> Map.put(:task, Map.get(state, :task_meta))

    {:reply, Map.put(snapshot, :auto_approve, names(state.auto_approve)), state}
  end

  def handle_call({:send_message, _text}, _from, %{status: status} = state)
      when status != :idle do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text}, _from, state) do
    message = Message.user(text)
    explicit = Keyword.get(state.loop_opts, :llm, %{})

    # A chat without a selection pins the one it resolves to now (MODEL-16),
    # unless an explicit provider replaces the selection anyway.
    state =
      if state.selection == nil and not is_map_key(explicit, :provider),
        do: %{state | selection: Elia.LLM.pinnable_selection()},
        else: state

    # COMPACT-5: compaction happens at the start of the turn, before the user
    # message, and again at every step of the loop below (COMPACT-29).
    state = compact_at_turn_start(state)

    session = self()
    turn_id = "#{state.id}-#{System.unique_integer([:positive])}"

    # INTR-1: the turn is recorded in the chat as it starts — the save the user
    # message triggers writes it — and cleared when it ends (finish_turn).
    state = %{
      state
      | turn_start: length(state.messages),
        turn: %{id: turn_id, started_at: DateTime.utc_now()}
    }

    # SESS-36, DONE-9: a message continues a done chat, so starting the turn
    # takes the flag with it — the save the user message triggers writes it away.
    state =
      if state.done do
        broadcast(state, {:done, false})
        %{state | done: false}
      else
        state
      end

    state = append(state, message)
    # The chat's model selected now is used for the whole turn. An explicit
    # provider replaces the selection; other explicit options are merged over it.
    llm = llm_request(state)

    opts =
      Keyword.merge(state.loop_opts,
        session_id: state.id,
        turn_id: turn_id,
        llm: llm,
        project: project(state),
        workspace: workspace(state),
        # ISOL-15: the tool context carries this chat's jail setting, so the
        # shell tools and `run_tests` follow it.
        jail: Map.get(state, :jail, true),
        # COMPACT-2, COMPACT-29: the loop is given the full history and derives
        # the request view from it at every step, with the trigger, target and
        # overhead of this chat's request (COMPACT-6, COMPACT-8, CTX-1).
        compaction: state.compaction,
        compaction_trigger: auto_trigger(state),
        compaction_target: target(state),
        compaction_overhead: overhead(state)
      )

    # LIMIT-3: the chat's own limits are the turn's, unless the caller passed
    # its own (a sub-task's spawn, or a test driving a limit directly).
    opts = Keyword.merge(Elia.Limits.loop_opts(Map.get(state, :limits, %{})), opts)

    task =
      Task.Supervisor.async_nolink(Elia.Agent.TaskSupervisor, fn ->
        Elia.Agent.Loop.run(session, state.messages, opts)
      end)

    {:reply, :ok, set_status(%{state | task: task}, :running)}
  end

  def handle_call({:select_model, selection}, _from, state) do
    state = %{state | selection: selection}
    # A chat with no messages isn't written to disk; the selection is saved
    # with its first message.
    state = if state.messages == [], do: state, else: save(state)
    broadcast(state, {:model, selection})
    {:reply, :ok, state}
  end

  # COMPACT-10: compact an idle chat on demand, ignoring the threshold and the
  # target (and without needing a window, which only gates COMPACT-7).
  def handle_call(:compact, _from, %{status: status} = state) when status != :idle do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:compact, _from, state) do
    {:reply, :ok, compact(state, target: nil, overhead: overhead(state))}
  end

  # COMPACT-9: this chat's own budget, fraction, target, working set, user cap
  # and whether automatic compaction is on.
  def handle_call({:set_compaction, options}, _from, state) do
    compaction = %{
      state.compaction
      | options: Map.merge(state.compaction.options, Map.new(options))
    }

    state = %{state | compaction: compaction}
    # As with the chat's other settings, an empty chat is saved with its first
    # message (CSET-6).
    state = if state.messages == [], do: state, else: save(state)
    broadcast(state, {:compaction, compaction})
    {:reply, :ok, state}
  end

  # COMPACT-21: pin a message or one of its blocks, so no rule may elide it.
  def handle_call({:set_pin, index, block, on?}, _from, state) when is_integer(index) do
    if index < 0 or index >= length(state.messages) do
      {:reply, {:error, :no_such_message}, state}
    else
      compaction =
        if on?,
          do: Compaction.pin(state.compaction, index, block),
          else: Compaction.unpin(state.compaction, index, block)

      state = save(%{state | compaction: compaction})
      broadcast(state, {:compaction, compaction})
      {:reply, :ok, state}
    end
  end

  # COMPACT-22: exact facts, appended (and trimmed) but never re-summarized, so
  # the identifiers that matter survive folding. The model writes them with the
  # `update_ledger` tool, mid-turn as well.
  def handle_call({:add_ledger, entries}, _from, state) do
    compaction = Compaction.add_ledger(state.compaction, entries)

    if compaction == state.compaction do
      {:reply, {:ok, compaction.ledger}, state}
    else
      state = save(%{state | compaction: compaction})
      broadcast(state, {:compaction, compaction})
      {:reply, {:ok, compaction.ledger}, state}
    end
  end

  def handle_call({:update_task, _changes}, _from, %{task_meta: nil} = state) do
    {:reply, {:error, :not_a_task}, state}
  end

  def handle_call({:update_task, changes}, _from, state) do
    # SESS-18, SESS-20
    state = save(%{state | task_meta: Map.merge(state.task_meta, changes)})
    broadcast(state, {:task, state.task_meta})
    {:reply, :ok, state}
  end

  def handle_call({:decide, call_id, decision}, _from, %{approval: {pid, decisions}} = state)
      when is_map_key(decisions, call_id) and decision in [:approve, :deny] do
    decisions = Map.put(decisions, call_id, decision)
    status = if decision == :approve, do: :approved, else: :done
    state = put_tool_status(state, call_id, status)
    {:reply, :ok, settle(state, pid, decisions)}
  end

  def handle_call({:decide, _call_id, _decision}, _from, state) do
    {:reply, {:error, :not_pending}, state}
  end

  # ASK-4, ASK-6, SESS-34: the user's answer to a question the loop is waiting
  # on. A blank answer is refused, and the loop only hears back once every
  # pending question has an answer.
  def handle_call({:answer, call_id, answer}, _from, %{input: {pid, answers}} = state)
      when is_map_key(answers, call_id) and is_binary(answer) do
    case String.trim(answer) do
      "" ->
        {:reply, {:error, :blank}, state}

      answer ->
        state = put_tool_status(state, call_id, :answered)
        {:reply, :ok, settle_input(state, pid, Map.put(answers, call_id, answer))}
    end
  end

  # ASK-7, SESS-34: no question is open, or not this one (an answer that arrives
  # after the turn ended lands here).
  def handle_call({:answer, _call_id, _answer}, _from, state) do
    {:reply, {:error, :not_pending}, state}
  end

  def handle_call({:set_auto_approve, name, on?}, _from, state) do
    if on? and not approvable?(state, name) do
      {:reply, {:error, :not_approvable}, state}
    else
      auto =
        if on?,
          do: MapSet.put(state.auto_approve, name),
          else: MapSet.delete(state.auto_approve, name)

      state = %{state | auto_approve: auto}
      # As with the model selection, an empty chat is saved with its first message.
      state = if state.messages == [], do: state, else: save(state)
      broadcast(state, {:auto_approve, names(auto)})
      {:reply, :ok, if(on?, do: approve_pending(state, name), else: state)}
    end
  end

  # SESS-30, ISOL-16: the chat's jail setting. Allowed mid-turn (ISOL-19): a
  # command already running isn't killed, and later calls follow the new value.
  def handle_call({:set_jail, on?}, _from, state) when is_boolean(on?) do
    state = %{state | jail: on?}
    # As with the model selection, an empty chat is saved with its first message.
    state = if state.messages == [], do: state, else: save(state)
    broadcast(state, {:jail, on?})
    {:reply, :ok, state}
  end

  # SESS-31, LIMIT-2: this chat's turn limits (LIMIT-1), which the next turn is
  # started with (LIMIT-3). A value that isn't valid is rejected and changes
  # nothing (LIMIT-7).
  def handle_call({:set_limits, changes}, _from, state) do
    case Elia.Limits.validate(changes) do
      {:ok, changes} ->
        limits = Elia.Limits.new(Map.merge(Map.get(state, :limits, %{}), changes))
        state = %{state | limits: limits}
        # As with the model selection, an empty chat is saved with its first message.
        state = if state.messages == [], do: state, else: save(state)
        broadcast(state, {:limits, limits})
        {:reply, :ok, state}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  # SESS-33, TITLE-4: the chat's own title, set by the model's `set_title` tool
  # (TITLE-5). A sub-task is named by its parent's `spawn_task` title (TITLE-3),
  # and a blank title is no title at all (TITLE-2, TITLE-6).
  def handle_call({:set_title, _text}, _from, %{task_meta: task_meta} = state)
      when task_meta != nil do
    {:reply, {:error, "This chat is a sub-task: it is named by its task title."}, state}
  end

  def handle_call({:set_title, text}, _from, state) do
    case Elia.Store.shape_title(text) do
      nil ->
        {:reply, {:error, "The title must not be blank."}, state}

      title ->
        state = %{state | title: title}
        # As with the model selection, an empty chat is saved with its first
        # message.
        state = if state.messages == [], do: state, else: save(state)
        broadcast(state, {:title, title})
        {:reply, {:ok, title}, state}
    end
  end

  # SESS-35, DONE-1, DONE-6: the chat's done flag, set by the model's
  # `mark_done` tool (DONE-6) or the page's control (DONE-4). A sub-task is
  # finished by its task status, so it has no flag of its own (DONE-3).
  def handle_call({:set_done, _on?}, _from, %{task_meta: task_meta} = state)
      when task_meta != nil do
    {:reply, {:error, "This chat is a sub-task: its status is its task's."}, state}
  end

  def handle_call({:set_done, on?}, _from, state) do
    state = %{state | done: on?}
    # As with the model selection, an empty chat is saved with its first message.
    state = if state.messages == [], do: state, else: save(state)
    broadcast(state, {:done, on?})
    {:reply, {:ok, on?}, state}
  end

  def handle_call(:stop, _from, %{task: nil} = state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state) do
    # SESS-22: a stopped sub-task is cancelled; stopping its parent stops it.
    Elia.Tasks.note_stop(state.id)
    Task.Supervisor.terminate_child(Elia.Agent.TaskSupervisor, state.task.pid)
    Process.demonitor(state.task.ref, [:flush])

    state =
      state
      |> close_dangling_tool_calls("Cancelled by the user.")
      |> append(stop_notice(:stopped, "Stopped by the user."))
      |> finish_turn()

    {:reply, :ok, state}
  end

  # SESS-27: the user's decision on a turn paused at a limit (LOOP-19).
  def handle_call(:resume, _from, %{pause: nil} = state),
    do: {:reply, {:error, :not_paused}, state}

  def handle_call(:resume, _from, %{pause: _message, task: %Task{pid: pid}} = state) do
    send(pid, {:pause_decision, :continue})
    {:reply, :ok, set_status(%{state | pause: nil}, :running)}
  end

  def handle_call(:fail_task, _from, %{pause: nil} = state),
    do: {:reply, {:error, :not_paused}, state}

  def handle_call(:fail_task, _from, %{pause: _message, task: %Task{pid: pid}} = state) do
    send(pid, {:pause_decision, :fail})
    {:reply, :ok, set_status(%{state | pause: nil}, :running)}
  end

  # Messages a stopped loop sent before it died.
  @impl true
  def handle_info({tag, _}, %{task: nil} = state)
      when tag in [:loop_event, :loop_append, :loop_compaction] do
    {:noreply, state}
  end

  def handle_info({tag, _, _}, %{task: nil} = state)
      when tag in [:loop_tool_status, :loop_await_approval, :loop_await_input] do
    {:noreply, state}
  end

  def handle_info({:loop_event, event}, state) do
    case event do
      {:text_delta, text} -> broadcast(state, {:delta, :text, text})
      {:reasoning_delta, text} -> broadcast(state, {:delta, :reasoning, text})
      {:notice, text} -> broadcast(state, {:notice, text})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:loop_append, message}, state), do: {:noreply, append(state, message)}

  # COMPACT-29: the loop's mid-turn pass advanced the ladder. The session owns
  # the state, so it takes the reported one, saves it and broadcasts it, exactly
  # as an automatic compaction at the turn start does — the transcript's
  # annotations and the estimate stay honest (COMPACT-24..COMPACT-26) and the
  # CTX-10 adjustment of the old view is dropped (COMPACT-27).
  def handle_info({:loop_compaction, compaction}, state) when is_struct(compaction, Compaction) do
    {:noreply, apply_compaction(state, compaction)}
  end

  def handle_info({:loop_usage, usage}, state) when is_map(usage) do
    # CTX-10, COMPACT-26: remember what we estimated for the request view this
    # step sent — the pure derivation of the history under the chat's compaction
    # state, which is what the loop sent (COMPACT-2, COMPACT-29) — so the context
    # indicator can calibrate against the provider's figure over those messages.
    estimate = context(state, Compaction.view(state.messages, state.compaction).messages).total

    usage = Map.put(usage, "estimated_input_tokens", estimate)

    broadcast(state, {:usage, usage})
    {:noreply, %{state | last_usage: usage}}
  end

  def handle_info({:loop_tool_status, call_id, status}, state) do
    {:noreply, put_tool_status(state, call_id, status)}
  end

  def handle_info({:loop_await_approval, pid, calls}, state) do
    # APPR-8: calls for auto-approved tools skip the user.
    decisions =
      Map.new(calls, fn call ->
        {call.id, if(auto_approved?(state, call.name), do: :approve, else: :pending)}
      end)

    state =
      Enum.reduce(decisions, state, fn
        {id, :pending}, state -> put_tool_status(state, id, :awaiting_approval)
        {id, :approve}, state -> put_tool_status(state, id, :approved)
      end)

    {:noreply, settle(state, pid, decisions)}
  end

  # ASK-3, ASK-6, SESS-34: the loop put this step's questions to the user and
  # waits. Every one of them is shown at once, as approvals are (APPR-3), and
  # the loop is released once all of them have an answer.
  def handle_info({:loop_await_input, pid, calls}, state) do
    pending = Map.new(calls, &{&1.id, nil})
    state = Enum.reduce(calls, state, &put_tool_status(&2, &1.id, :awaiting_input))
    {:noreply, set_status_if_changed(%{state | input: {pid, pending}}, :awaiting_input)}
  end

  # SESS-27, SESS-37: the loop paused at a limit (LOOP-19) and waits for the
  # user. The pause is written into the transcript as well (LIMIT-10), so a chat
  # waiting on a decision says why however long afterwards it is opened.
  def handle_info({:loop_pause, pid, limit}, %{task: %Task{pid: pid}} = state) do
    message = pause_message(limit)
    state = append(state, pause_notice(limit))
    state = set_status(%{state | pause: message}, :paused)
    broadcast(state, {:paused, message})
    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        :done ->
          state

        :refused ->
          # Roll back to the prefix before this turn; nothing in it was edited.
          # The rolled-back request's usage no longer describes the context (CTX-6).
          # STOP-2: the rollback is what the refusal needs; the stop is written
          # after it, so the message is the last thing the transcript holds.
          state =
            save(%{
              state
              | messages: Enum.take(state.messages, state.turn_start),
                last_usage: nil
            })

          broadcast(state, {:reset, state.messages})
          stop(state, :refused, "The model declined this request.")

        {:limit, limit} ->
          stop(state, :limit, limit_message(limit))

        {:error, reason} ->
          stop(state, :error, to_string(reason))
      end

    {:noreply, finish_turn(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    state =
      state
      |> close_dangling_tool_calls("The harness crashed while running this tool.")
      |> stop(:crash, "The harness crashed: " <> crash_reason(reason))
      |> finish_turn()

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Helpers

  # Waits for the remaining decisions, or releases the loop once there are none
  # (APPR-5, APPR-10).
  defp settle(state, pid, decisions) do
    if Enum.any?(decisions, fn {_, d} -> d == :pending end) do
      set_status_if_changed(%{state | approval: {pid, decisions}}, :awaiting_approval)
    else
      send(pid, {:approval_decisions, decisions})
      set_status_if_changed(%{state | approval: nil}, :running)
    end
  end

  defp set_status_if_changed(%{status: status} = state, status), do: state
  defp set_status_if_changed(state, status), do: set_status(state, status)

  # ASK-6, SESS-34: waits for the remaining answers, or releases the loop once
  # every question has one.
  defp settle_input(state, pid, answers) do
    if Enum.any?(answers, fn {_call_id, answer} -> answer == nil end) do
      set_status_if_changed(%{state | input: {pid, answers}}, :awaiting_input)
    else
      send(pid, {:input_answers, answers})
      set_status_if_changed(%{state | input: nil}, :running)
    end
  end

  # APPR-11: approve this tool's calls that are waiting right now.
  defp approve_pending(%{approval: {pid, decisions}} = state, name) do
    ids =
      case List.last(state.messages) do
        %Message{role: :assistant} = last ->
          for call <- Message.tool_calls(last),
              call.name == name and decisions[call.id] == :pending,
              do: call.id

        _ ->
          []
      end

    state = Enum.reduce(ids, state, &put_tool_status(&2, &1, :approved))
    settle(state, pid, Enum.reduce(ids, decisions, &Map.put(&2, &1, :approve)))
  end

  defp approve_pending(state, _name), do: state

  # APPR-13: only tools that can need approval.
  defp approvable?(state, name), do: name in approvable_names(state)

  # APPR-13, APPR-14: the names of the tools that can need approval in this
  # chat, which is also what a new chat auto-approves.
  defp approvable_names(state) do
    skills = Elia.Skills.resolve(Keyword.get(state.loop_opts, :skills), project(state))

    skills
    |> Elia.Skills.tools()
    |> Enum.filter(&(&1.approval != :never))
    |> Enum.map(& &1.name)
  end

  # `auto_approve` is missing from state that predates it (see SESS-15).
  defp auto_approved?(state, name),
    do: MapSet.member?(Map.get(state, :auto_approve, MapSet.new()), name)

  defp names(set), do: set |> MapSet.to_list() |> Enum.sort()

  # SESS-17: a caller may set the new session's auto-approved tools (APPR-8,
  # SUBTASK-6) instead of loading the chat's saved ones.
  defp initial_auto_approve(_state, names) when is_list(names), do: MapSet.new(names)

  # APPR-8, APPR-14: a new chat — no messages and nothing saved (STORE-15) —
  # starts with every tool that can need approval (APPR-13) in its set, which
  # the jail (ISOL-1) is what makes safe. Any other chat starts from its file.
  defp initial_auto_approve(state, nil) do
    saved = if state.persist, do: Elia.Store.load_auto_approve(state.id), else: []

    cond do
      saved != [] -> MapSet.new(saved)
      state.messages == [] -> MapSet.new(approvable_names(state))
      true -> MapSet.new()
    end
  end

  # SESS-30, SUBTASK-30: a caller may set the new session's jail setting (the
  # child's copy of its parent's) instead of loading the chat's saved one.
  defp initial_jail(id, persist, nil), do: initial_jail(id, persist)
  defp initial_jail(_id, _persist, on?) when is_boolean(on?), do: on?

  defp initial_jail(id, true), do: Elia.Store.load_jail(id)
  defp initial_jail(_id, false), do: true

  # SESS-31, LIMIT-5, SESS-17: a caller may set the new session's turn limits
  # (the budget a sub-task is spawned with) instead of the chat's saved ones.
  defp initial_limits(id, persist, nil), do: initial_limits(id, persist)
  defp initial_limits(_id, _persist, limits) when is_map(limits), do: Elia.Limits.new(limits)

  defp initial_limits(id, true), do: Elia.Store.load_limits(id)
  defp initial_limits(_id, false), do: Elia.Limits.defaults()

  # COMPACT-9, COMPACT-24: the chat's saved compaction state, with any options
  # its session was started with.
  defp initial_compaction(id, true, overrides) do
    id |> Elia.Store.load_compaction() |> Compaction.from_map() |> put_options(overrides)
  end

  defp initial_compaction(_id, false, overrides),
    do: %Compaction{} |> put_options(overrides)

  defp put_options(state, nil), do: state

  defp put_options(state, overrides),
    do: %{state | options: Map.merge(state.options, Map.new(overrides))}

  # COMPACT-6: a turn compacts first when the request view's estimate exceeds
  # the trigger. Without a known window nothing automatic happens (COMPACT-7).
  defp compact_at_turn_start(state) do
    options = Compaction.options(state.compaction.options)
    trigger = trigger(state)
    overhead = overhead(state)
    tokens = Compaction.view(state.messages, state.compaction).tokens + overhead

    if options.auto and trigger != nil and tokens > trigger do
      compact(state, target: target(state), overhead: overhead)
    else
      state
    end
  end

  # COMPACT-6, COMPACT-8, COMPACT-17: run the ladder and, if it cannot reach the
  # target, fold the summary. Saving, and the `{:compaction, state}` broadcast
  # that lets a UI redraw its annotations and its estimate, happen only when the
  # state actually changed.
  defp compact(state, opts) do
    before = state.compaction
    llm = llm_request(state)
    summarizer = Keyword.get(state.loop_opts, :summarizer, Compaction.default_summarizer(llm))

    opts = opts |> Map.new() |> Map.merge(%{summarizer: summarizer, llm: llm})
    apply_compaction(state, Compaction.compact(state.messages, before, opts))
  end

  # The compaction state this chat's request view follows, taken from either path
  # that produces one. Nothing is saved or broadcast when it did not change;
  # otherwise the `{:compaction, state}` broadcast lets a UI redraw its
  # annotations and its estimate. `Elia.Agent.Loop` reports the mid-turn pass's
  # state the same way (COMPACT-29), so the session stays the single source of
  # truth.
  defp apply_compaction(%{compaction: compaction} = state, compaction), do: state

  defp apply_compaction(state, compaction) do
    # COMPACT-27: the adjustment described the old view, so it is cleared.
    state = %{state | compaction: compaction} |> drop_estimate() |> save()
    broadcast(state, {:compaction, compaction})
    state
  end

  # The trigger of this chat's request, or nil without a known window
  # (COMPACT-6, COMPACT-7).
  defp trigger(state),
    do: Compaction.trigger(window(state), Compaction.options(state.compaction.options))

  # The target to reduce to when the trigger is exceeded (COMPACT-8).
  defp target(state),
    do: Compaction.target(window(state), Compaction.options(state.compaction.options))

  # COMPACT-5, COMPACT-9, COMPACT-29: the trigger for the loop's mid-turn pass.
  # Nothing automatic happens there when automatic compaction is off for this
  # chat, or when the window is unknown.
  defp auto_trigger(state) do
    if Compaction.options(state.compaction.options).auto, do: trigger(state), else: nil
  end

  # COMPACT-27: a different request view makes the CTX-10 adjustment (which
  # described the old one) meaningless, so it is cleared, as on a reset.
  defp drop_estimate(%{last_usage: nil} = state), do: state

  defp drop_estimate(state),
    do: %{state | last_usage: Map.delete(state.last_usage, "estimated_input_tokens")}

  # The selected model's context window, or nil when it is unknown (CTX-7).
  defp window(state), do: Elia.LLM.context_window(state.selection).context_length

  # The system prompt and tool definitions of the request, which are not part of
  # the view's messages but are part of the estimated request (CTX-1).
  defp overhead(state), do: Context.build([], skills(state), instructions(state)).total

  defp context(state, messages),
    do: Context.build(messages, skills(state), instructions(state))

  defp skills(state),
    do: Elia.Skills.resolve(Keyword.get(state.loop_opts, :skills), project(state))

  defp instructions(state), do: Elia.Skills.project_instructions(project(state).folder)

  # The provider request of the turn (MODEL-1): an explicit `:llm` wins.
  defp llm_request(state) do
    case Keyword.get(state.loop_opts, :llm, %{}) do
      %{provider: _} = llm -> llm
      llm -> Map.merge(Elia.LLM.selection_request(state.selection), llm)
    end
  end

  # The chat's project (PROJ-9): the saved one, else Elia's own. Read through
  # `Elia.Projects.get/1` so a project deleted since still resolves to harness.
  defp load_project(_id, false), do: Elia.Projects.harness()

  defp load_project(id, true) do
    with project_id when is_binary(project_id) <- Elia.Store.load_project(id),
         project when not is_nil(project) <- Elia.Projects.get(project_id) do
      project
    else
      _ -> Elia.Projects.harness()
    end
  end

  # The chat's project, for state that predates the field (SESS-15).
  defp project(state), do: Map.get(state, :project) || Elia.Projects.harness()

  # The chat's workspace root (PROJ-12): its own worktree in Elia's own project
  # (DEPLOY-1), else the project's folder (DEPLOY-3). State from before the
  # field existed (SESS-15) resolves it here.
  defp workspace(state),
    do: Map.get(state, :workspace) || Elia.Deploy.workspace(project(state), state.id)

  defp append(state, %Message{content: []}), do: state

  defp append(state, message) do
    broadcast(state, {:message, message})

    state = %{state | messages: state.messages ++ [message]}
    save(state)
  end

  defp save(%{persist: false} = state), do: state

  defp save(state) do
    auto = names(Map.get(state, :auto_approve, MapSet.new()))

    with {:error, reason} <-
           Elia.Store.save(state.id, state.messages,
             model: state.selection,
             auto_approve: auto,
             task: Map.get(state, :task_meta),
             project: project(state).id,
             compaction: saved_compaction(Map.get(state, :compaction)),
             jail: Map.get(state, :jail, true),
             limits: Map.get(state, :limits, Elia.Limits.defaults()),
             # STORE-30, INTR-1: the turn in flight, or nothing when there is
             # none (which takes the entry off the file).
             turn: Map.get(state, :turn),
             title: Map.get(state, :title),
             done: Map.get(state, :done, false)
           ) do
      Logger.error("Could not save session #{state.id}: #{inspect(reason)}")
    end

    state
  end

  # COMPACT-24: nothing is written for a chat that has never compacted or
  # pinned anything.
  defp saved_compaction(nil), do: nil

  defp saved_compaction(%Compaction{} = compaction),
    do: if(Compaction.empty?(compaction), do: nil, else: Compaction.to_map(compaction))

  # Every tool call needs a result before the next model call.
  defp close_dangling_tool_calls(state, reason) do
    case List.last(state.messages) do
      %Message{role: :assistant} = last ->
        results =
          for call <- Message.tool_calls(last), do: Message.tool_result(call.id, reason, true)

        state = Enum.reduce(results, state, &put_tool_status(&2, &1.tool_call_id, :done))
        append(state, %Message{role: :tool, content: results})

      _ ->
        state
    end
  end

  # INTR-1: the turn is over, so the record it wrote goes with it. Saving is
  # needed only when there was one: everything else the turn changed was saved
  # as it happened.
  # ASK-7: ending the turn also clears the session's pending question.
  defp finish_turn(state) do
    state = %{state | task: nil, approval: nil, pause: nil, input: nil}

    state = if Map.get(state, :turn), do: save(%{state | turn: nil}), else: state

    set_status(state, :idle)
  end

  # INTR-3: the app stopped while the chat's last turn ran — the record is still
  # there (STORE-30) and no session of this one owned it — so the chat says so.
  # The notice goes into the history, where the transcript keeps it (UI-73), and
  # appending it saves the chat, which clears the record (INTR-1). The status
  # broadcast (SESS-19) is what drops the chat list's marker (UI-72) in every
  # page, including the ones that are not showing this chat.
  defp note_interrupted_turn(%{persist: false} = state), do: state

  defp note_interrupted_turn(state) do
    if Elia.Store.load_turn(state.id) do
      state |> append(interrupted_notice()) |> set_status(:idle)
    else
      state
    end
  end

  # INTR-3, UI-73: a harness message (UI-9), marked so the transcript can show
  # it as an error rather than as one of the loop's notices.
  defp interrupted_notice do
    text = "The app restarted while this turn was running. Send a message to carry on."
    message = Message.harness(text)
    %{message | meta: Map.put(message.meta, :interrupted, true)}
  end

  # SESS-27: the message shown while a turn is paused at a limit (LOOP-19).
  defp pause_message({:steps, max}), do: "Step limit reached (#{max} steps)."

  defp pause_message({:time, ms}),
    do: "Time limit reached (#{Elia.Agent.Loop.minutes(ms)})."

  defp pause_message({:tokens, tokens}),
    do: "Token limit reached (#{Elia.LLM.Tokens.format(tokens)} tokens)."

  # STOP-2, LOOP-3, LOOP-20, LOOP-22: what a turn that a limit ended says it was.
  defp limit_message({:steps, max}), do: "Stopped after #{max} steps without finishing"

  defp limit_message({:time, ms}),
    do: "Stopped after #{Elia.Agent.Loop.minutes(ms)}: the time budget ran out"

  defp limit_message({:tokens, tokens}),
    do: "Stopped after #{Elia.LLM.Tokens.format(tokens)} tokens: the token budget ran out"

  # STOP-1, SESS-38: a turn that didn't finish says so in the transcript, marked
  # with the kind of stop it was (STOP-2), saved as any appended message is and
  # rendered as an error row (UI-82).
  defp stop_notice(kind, text) do
    message = Message.harness(text)
    %{message | meta: Map.put(message.meta, :stopped, kind)}
  end

  # STOP-4: the transcript gets the message and the watchers that read a chat's
  # events get the same text, which is how a sub-task's parent reads a child's
  # failure (SUBTASK-13). The page renders the message, not the event (UI-82).
  defp stop(state, kind, text) do
    state = append(state, stop_notice(kind, text))
    broadcast(state, {:error, text})
    state
  end

  # STOP-2: the reason the loop died with, as the one-line banner a crash is
  # reported with — not a stacktrace, which is neither what a transcript wants
  # nor what a sub-task's result wants.
  defp crash_reason({exception, _stacktrace}) when is_exception(exception),
    do: Exception.format_banner(:error, exception)

  defp crash_reason(reason), do: Exception.format_banner(:exit, reason)

  # LIMIT-10, SESS-37: the same pause written into the transcript, so a chat
  # waiting on the user's decision says why — now and whenever it is opened
  # again. Marked (`meta.limit`) so its row reads as an error rather than as one
  # of the loop's notices (UI-81).
  defp pause_notice(limit) do
    message = Message.harness(pause_notice_text(limit))
    %{message | meta: Map.put(message.meta, :limit, limit)}
  end

  defp pause_notice_text({:steps, max}),
    do:
      pause_message({:steps, max}) <>
        " The turn is paused: Continue starts the count over, Fail ends it."

  defp pause_notice_text({:time, ms}),
    do:
      pause_message({:time, ms}) <>
        " The turn is paused: Continue starts the clock over, Fail ends it."

  defp pause_notice_text({:tokens, tokens}),
    do:
      pause_message({:tokens, tokens}) <>
        " The turn is paused: Continue starts the count over, Fail ends it."

  defp set_status(state, status) do
    broadcast(state, {:status, status})
    # SESS-19
    Registry.update_value(Elia.Agent.Registry, state.id, fn _ -> status end)

    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      Elia.Agent.activity_topic(),
      {:chat_status, state.id, status}
    )

    %{state | status: status}
  end

  defp put_tool_status(state, call_id, status) do
    broadcast(state, {:tool_status, call_id, status})
    put_in(state.tool_status[call_id], status)
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(Elia.PubSub, Elia.Agent.topic(state.id), {:agent, state.id, event})
  end
end
