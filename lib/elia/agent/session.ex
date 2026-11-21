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
  `{:usage, usage}`, `{:compaction, state}`, `{:retry, info}` (a failed model
  call is being retried, RETRY-3), `{:error, text}` (a stop, whose
  transcript message is STOP-1's, STOP-4),
  `{:reset, messages}`, `{:settings, settings}` (one of the chat's per-chat
  settings changed, SESS-41), `{:title, title}`, `{:done, on?}`,
  `{:paused, message}`. A chat's task metadata is not among them: it is set when
  the chat is created and once when its result is saved with it (SESS-18,
  SUBTASK-13), and no view draws it live (the retired SESS-20).
  """

  use GenServer, restart: :temporary

  require Logger

  # SESS-41: the settings the chat's one map holds, and the only keys a change
  # to it may name (SESS-42).
  @setting_keys [:model, :auto_approve, :jail, :network, :limits, :effort]

  # SUBTASK-9: what a child says about itself when it marked its chat done
  # without a last message to say it with.
  @no_summary "The task ended without a summary."

  alias Elia.LLM.{Compaction, Context, Message}

  defstruct [
    :id,
    # The project the chat belongs to (PROJ-9): a `%{id, name, folder, harness?}`.
    :project,
    # The workspace root of this chat (PROJ-12, DEPLOY-1): the folder of the
    # project it is in — the live tree for a chat in Elia's own project. A chat
    # that changes code makes itself a worktree inside it (DEPLOY-28) and moves
    # there with its working directory (WD-1).
    :workspace,
    # The chat's working directory (WD-1): an absolute path inside `workspace`
    # that its `shell` call resolves relative paths against, or `nil` while it
    # is the workspace root itself (WD-7). It is saved with the chat (STORE-46),
    # so it outlives the process (WD-2).
    :cwd,
    :task,
    # The turn this session is running: `%{id, started_at}` while one is in
    # flight, `nil` otherwise. It is saved with the chat so that a later session
    # can see that a restart cut the turn short (INTR-1, STORE-30).
    :turn,
    :turn_start,
    # The chat's own title (TITLE-1, STORE-32), nil when it has none and its
    # title is the first user message (STORE-7).
    :title,
    # Sub-task metadata when the chat was started by `spawn_task` (STORE-16).
    :task_meta,
    messages: [],
    status: :idle,
    # The chat's compaction state (COMPACT-24): how far the ladder has gone, the
    # summary, the ledger, the pins and the chat's own options. It is the single
    # source of truth for the request view; the loop's mid-turn pass reports back
    # into it (COMPACT-29).
    compaction: %Compaction{},
    # The chat's per-chat settings as one map (SESS-41, SESS-7): the model
    # selection of the chat (MODEL-1), the tool names it auto-approves (APPR-8),
    # whether its commands run in the jail (ISOL-16), what its commands may
    # reach (NET-1), its turn limits (LIMIT-1) and its own reasoning effort
    # (LLM-39), each at its own default until the chat sets it. One write path
    # sets any of them (SESS-41).
    settings: %{
      model: nil,
      auto_approve: MapSet.new(),
      jail: true,
      network: Elia.Net.default(),
      limits: Elia.Limits.defaults(),
      effort: nil
    },
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
    done: false,
    # SESS-44: `{timer, token}` while messages the loop appended wait for their
    # save, or while a save that failed waits to be tried again (SESS-46); nil
    # when everything is saved. Read with `Map.get/2`: a session
    # that outlived a hot reload has no such key.
    save_timer: nil,
    # COMPACT-42: the turn id of a turn whose start began a fold, waiting for
    # that fold's result before its loop runs; nil when no turn is waiting. Read
    # with `Map.get/2`, as `save_timer` is.
    pending_turn: nil,
    # COMPACT-40: `%{ref: ref, pid: pid, opts: opts}` while a summary is being
    # folded in a worker of this session's; nil otherwise. Read with `Map.get/2`.
    fold: nil
  ]

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {Elia.Agent.Registry, id}}

  @impl true
  def init(opts) do
    # SESS-44: a shutdown reaches `terminate/2`, which saves what is unsaved.
    Process.flag(:trap_exit, true)
    persist = Keyword.get(opts, :persist, true)
    loop_opts = Keyword.get(opts, :loop_opts, [])
    project = opts[:project] || load_project(opts[:id], persist)

    workspace =
      opts[:workspace] || Keyword.get(loop_opts, :workspace) || project.folder

    state = %__MODULE__{
      id: opts[:id],
      project: project,
      workspace: workspace,
      # WD-2, WD-7: the chat's own working directory, saved with it, read back
      # only while it is still a directory inside the workspace.
      cwd: if(persist, do: load_cwd(opts[:id], workspace)),
      loop_opts: loop_opts,
      persist: persist,
      messages: if(persist, do: Elia.Store.load(opts[:id]), else: []),
      settings: initial_settings(opts[:id], persist, opts),
      task_meta: opts[:task] || if(persist, do: Elia.Store.load_task(opts[:id])),
      compaction: initial_compaction(opts[:id], persist, opts[:compaction]),
      title: if(persist, do: Elia.Store.load_title(opts[:id])),
      done: if(persist, do: Elia.Store.load_done(opts[:id]), else: false)
    }

    # COMPACT-38, `## Stored data`: a saved state carries the items the ladder
    # elided; one saved before the item list existed carries only its level and
    # boundaries, so the elision they describe is materialised here, when the
    # chat loads, and nothing a chat had already elided comes back.
    state = %{state | compaction: Compaction.materialise(state.compaction, state.messages)}

    # APPR-14: whether the chat is new is only known once its messages are
    # loaded, so the default set is worked out here.
    state = %{
      state
      | settings: %{
          state.settings
          | auto_approve: initial_auto_approve(state, opts[:auto_approve])
        }
    }

    # RESUME-2: the record of a turn the restart cut short is read before
    # anything saves the chat — a session's own state carries no turn (SESS-15),
    # so the save below would take the record off the file (INTR-1) before
    # anything could decide what to do with it.
    turn = if persist, do: Elia.Store.load_turn(opts[:id])

    # SESS-21: tool calls the app stopped in the middle of never got a result.
    state = close_dangling_tool_calls(state, "The app restarted while this tool was running.")
    # INTR-3, RESUME-2: and if the chat carried a turn record, that turn was cut
    # short by the restart: it carries on when automatic resume applies
    # (RESUME-3) and says so otherwise.
    {:ok, resume_or_note(state, turn)}
  end

  @impl true
  # SESS-15: upgrade state from before `:settings` (SESS-41), `:task_meta`,
  # `:project`, `:workspace`, `:compaction`, `:pause`, `:turn` (INTR-1),
  # `:title`, `:input` (ASK), `:done` (DONE-1) or `:cwd` (WD-1) existed (a
  # session that outlived a hot reload). Fields it already has are kept —
  # including the five values a state from before the one map holds as fields of
  # its own — and `:turn` is not loaded from disk, since it belongs to the
  # process that is running the turn.
  def handle_call(msg, from, state)
      when not is_map_key(state, :settings) or
             not is_map_key(state, :task_meta) or not is_map_key(state, :project) or
             not is_map_key(state, :workspace) or not is_map_key(state, :compaction) or
             not is_map_key(state, :pause) or
             not is_map_key(state, :turn) or
             not is_map_key(state, :title) or not is_map_key(state, :input) or
             not is_map_key(state, :done) or not is_map_key(state, :cwd) do
    upgraded = Map.merge(%__MODULE__{}, Map.from_struct(state))

    upgraded =
      if is_map_key(state, :project),
        do: upgraded,
        else: %{upgraded | project: load_project(upgraded.id, upgraded.persist)}

    upgraded =
      if is_map_key(state, :workspace),
        do: upgraded,
        else: %{upgraded | workspace: upgraded.project.folder}

    upgraded =
      if is_map_key(state, :task_meta),
        do: upgraded,
        else: %{
          upgraded
          | task_meta: if(upgraded.persist, do: Elia.Store.load_task(upgraded.id))
        }

    upgraded =
      if is_map_key(state, :settings),
        do: upgraded,
        else: %{upgraded | settings: upgraded_settings(state, upgraded)}

    upgraded =
      if is_map_key(state, :compaction),
        do: upgraded,
        else: %{upgraded | compaction: initial_compaction(upgraded.id, upgraded.persist, nil)}

    # COMPACT-38, `## Stored data`: an upgraded session materialises its items
    # the same way a loading one does.
    upgraded = %{
      upgraded
      | compaction: Compaction.materialise(upgraded.compaction, upgraded.messages)
    }

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

    upgraded =
      if is_map_key(state, :cwd),
        do: upgraded,
        else: %{
          upgraded
          | cwd: if(upgraded.persist, do: load_cwd(upgraded.id, upgraded.workspace))
        }

    handle_call(msg, from, upgraded)
  end

  # WD-1, WD-10: the chat's working directory, which the loop reads at the start
  # of every step, so a `cd` applies from the next one.
  def handle_call(:cwd, _from, state), do: {:reply, cwd(state), state}

  # WD-3, WD-4: `cd` sets the chat's working directory — or reports it, when it
  # names no path. WD-5 is the refusal, which changes nothing.
  def handle_call({:set_cwd, path}, _from, state) when path in [nil, ""] do
    {:reply, {:ok, label(state)}, state}
  end

  def handle_call({:set_cwd, path}, _from, state) when is_binary(path) do
    case Elia.Workdir.resolve(path, cwd(state), workspace(state)) do
      {:ok, dir} ->
        state = %{state | cwd: stored_cwd(dir, state)}
        # WD-2: the new directory is saved with the chat. As with its other
        # settings, an empty chat is saved with its first message (SESS-14,
        # CSET-6).
        state = if state.messages == [], do: state, else: save(state)
        {:reply, {:ok, label(state)}, state}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot =
      Map.take(state, [
        :id,
        :messages,
        :status,
        :tool_status,
        :last_usage,
        :project,
        :compaction,
        :pause,
        :title,
        :done
      ])
      |> Map.put(:settings, public_settings(state))
      |> Map.put(:task, Map.get(state, :task_meta))

    {:reply, snapshot, state}
  end

  # NET-6: the chat's network setting as it stands, for the proxy that decides a
  # running command's requests. A chat with no session answers nil, and its
  # caller falls back to the list it started with.
  def handle_call(:network, _from, state), do: {:reply, settings(state).network, state}

  def handle_call({:send_message, text}, _from, state),
    do: reply_to_send(state, Message.user(text))

  # UPLOAD-10, UPLOAD-11: a message that carries files says what the user wrote
  # and names the paths of what it carries.
  def handle_call({:send_message, text, attachments}, _from, state),
    do: reply_to_send(state, Message.user(text, attachments))

  # UPLOAD-6 - UPLOAD-11: the chat's own settings — its model, auto-approved
  # tools, jail, turn limits and effort — have one write path. A change is
  # validated as a whole, applied as a whole, saved once and broadcast as one
  # event; a change with anything wrong in it is no change at all.
  def handle_call({:set_settings, changes}, _from, state) do
    case validate_settings(state, changes) do
      {:ok, changes} ->
        state = apply_settings(state, changes)
        # As with the model selection, an empty chat is saved with its first
        # message (SESS-14, CSET-6).
        state = if state.messages == [], do: state, else: save(state)
        broadcast(state, {:settings, public_settings(state)})
        {:reply, :ok, approve_newly_allowed(state, changes)}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  # COMPACT-10, COMPACT-45: compact an idle chat on demand, ignoring the threshold
  # and the target (and without needing a window, which only gates COMPACT-7). A
  # chat that is mid-turn, or whose summary is still being folded, is busy.
  def handle_call(:compact, _from, %{status: status} = state) when status != :idle do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:compact, _from, %{fold: fold} = state) when fold != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:compact, _from, state) do
    {state, _fold?} = compact(state, target: nil, overhead: overhead(state))
    {:reply, :ok, state}
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

  # SESS-33, TITLE-4: the chat's own title, set by the model's `set_title` tool
  # (TITLE-5). A blank title is no title at all (TITLE-2, TITLE-6). A sub-task
  # may name itself like any chat (TITLE-3): its spawn's title is its first
  # name, saved as its own when the chat was created (STORE-32), not a rule.
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
  # `mark_done` tool (DONE-6) or the page's control (DONE-4). It is the chat's
  # own flag on every chat, and on a task chat it is what ends the task
  # (SUBTASK-33): the harness builds the result (SUBTASK-9) and this chat's own
  # session saves it with its metadata (SESS-18, SUBTASK-13). There is no task
  # status beside the flag.
  def handle_call({:set_done, on?}, _from, state) do
    state = %{state | done: on?}
    # As with the model selection, an empty chat is saved with its first message.
    state = if state.messages == [], do: state, else: save(state)
    state = if on?, do: end_task(state), else: state
    announce_done(state, on?)
    {:reply, {:ok, on?}, state}
  end

  def handle_call(:stop, _from, %{task: nil} = state) do
    # COMPACT-43: with no loop running, what a stop ends is a summary in flight
    # and the turn that was waiting on it.
    {:reply, :ok, end_pending_turn(stop_children(cancel_fold(state)))}
  end

  def handle_call(:stop, _from, state) do
    Task.Supervisor.terminate_child(Elia.Agent.TaskSupervisor, state.task.pid)
    Process.demonitor(state.task.ref, [:flush])

    state =
      state
      |> stop_children()
      |> cancel_fold()
      |> Map.put(:pending_turn, nil)
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

  # SESS-44: the save interval is over. A token that isn't the pending one is a
  # timer an earlier save already covered.
  @impl true
  def handle_info({:save_due, token}, state) do
    case Map.get(state, :save_timer) do
      {_timer, ^token} -> {:noreply, save(state)}
      _ -> {:noreply, state}
    end
  end

  # Messages a stopped loop sent before it died.
  def handle_info({tag, _}, %{task: nil} = state)
      when tag in [:loop_event, :loop_append, :loop_compaction, :loop_retry] do
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

  # SESS-5, SESS-44: the loop's messages are saved once per interval, not one
  # write of the whole chat each.
  def handle_info({:loop_append, message}, state),
    do: {:noreply, append(state, message, :later)}

  # COMPACT-29: the loop's mid-turn pass advanced the ladder. The session owns
  # the state, so it takes the reported one, saves it and broadcasts it, exactly
  # as an automatic compaction at the turn start does — the transcript's
  # annotations and the estimate stay honest (COMPACT-24..COMPACT-26) and the
  # CTX-10 adjustment of the old view is dropped (COMPACT-27).
  def handle_info({:loop_compaction, compaction}, state) when is_struct(compaction, Compaction) do
    {:noreply, apply_compaction(state, take_ladder(state.compaction, compaction))}
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

  # TIME-1, TIME-6, TIME-7: a step's measurements, written beside the chat as
  # the step finishes. Nothing is broadcast or saved: the transcript, the chat
  # and the page are unaffected, and a record that can't be written is dropped
  # (TIME-8, `Elia.StepTiming.record/2`).
  def handle_info({:loop_step_timing, entry}, state) when is_map(entry) do
    Elia.StepTiming.record(state.id, entry)
    {:noreply, state}
  end

  # SESS-39, RETRY-3: a failed model call is being retried. Nothing is
  # appended or saved — a turn that recovered reads as one that ran without
  # interruption — and the turn keeps running.
  def handle_info({:loop_retry, info}, state) do
    broadcast(state, {:retry, info})
    {:noreply, state}
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

  # COMPACT-40, COMPACT-41: the summary the worker folded has landed. It is
  # applied as a summary alone, and the turn that was waiting on it — if there
  # was one — starts from it (COMPACT-42).
  def handle_info({ref, result}, %{fold: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_fold(state, result)}
  end

  # COMPACT-20, COMPACT-42: a fold whose worker died leaves the pruned view and
  # no error, and a turn waiting on it goes on without a summary.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{fold: %{ref: ref}} = state) do
    {:noreply, start_pending_turn(%{state | fold: nil})}
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

  # The loop derived what it reports from the state the session handed it when
  # the turn started (COMPACT-29), so it owns how far down the ladder the view
  # has been taken — `level`, `covered` and the rung inside the turn being run
  # (COMPACT-31, COMPACT-33) — and the session keeps what it has changed since:
  # the ledger a tool wrote (COMPACT-22), a pin (COMPACT-21), this chat's
  # options (COMPACT-9) and the summary.
  defp take_ladder(session, reported) do
    %{
      reported
      | summary: session.summary,
        folded: session.folded,
        ledger: session.ledger,
        pins: session.pins,
        options: session.options
    }
  end

  ## Helpers

  # SESS-14, SESS-36, DONE-9, MODEL-16, UPLOAD-11: starts the turn a message
  # begins — with the text the user wrote and the files it carries (UPLOAD-10) —
  # unless the chat is busy, which is the only reason a message is refused.
  defp reply_to_send(%{status: status} = state, _message) when status != :idle,
    do: {:reply, {:error, :busy}, state}

  defp reply_to_send(state, message) do
    explicit = Keyword.get(state.loop_opts, :llm, %{})

    # A chat without a selection pins the one it resolves to now (MODEL-16),
    # unless an explicit provider replaces the selection anyway.
    state =
      if settings(state).model == nil and not is_map_key(explicit, :provider),
        do: put_setting(state, :model, Elia.LLM.pinnable_selection()),
        else: state

    # SESS-36, DONE-9: a message continues a done chat, so starting the turn
    # takes the flag with it — the save the user message triggers writes it away.
    state =
      if state.done do
        announce_done(state, false)
        %{state | done: false}
      else
        state
      end

    {:reply, :ok, start_turn(state, message: message)}
  end

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

  # APPR-8: whether a tool runs without asking in this chat. SESS-15: a state
  # that predates the one map has none of its own.
  defp auto_approved?(state, name), do: MapSet.member?(settings(state).auto_approve, name)

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

  # SESS-40, STORE-38: the chat's own reasoning effort, nil when it has none
  # and the configured one applies (LLM-38).
  defp initial_effort(id, true), do: Elia.Store.load_effort(id)
  defp initial_effort(_id, false), do: nil

  # SESS-41, SESS-7: the per-chat settings a session starts with — what its
  # caller gave it (SESS-17, SUBTASK-30), else what the chat has saved, else
  # each one's own default. The auto-approved set is worked out by the caller,
  # once the chat's messages are loaded (APPR-14).
  defp initial_settings(id, persist, opts) do
    %{
      model: opts[:selection] || if(persist, do: Elia.Store.load_model(id)),
      auto_approve: MapSet.new(),
      jail: initial_jail(id, persist, opts[:jail]),
      network: initial_network(id, persist, opts[:network]),
      limits: initial_limits(id, persist, opts[:limits]),
      effort: initial_effort(id, persist)
    }
  end

  # SESS-41, SUBTASK-30, NET-4: a caller may set the new session's network
  # setting (a sub-task's copy of its parent's) instead of loading the chat's
  # saved one.
  defp initial_network(id, persist, nil), do: initial_network(id, persist)
  defp initial_network(_id, _persist, setting) when is_map(setting), do: Elia.Net.load(setting)

  defp initial_network(id, true), do: Elia.Store.load_network(id)
  defp initial_network(_id, false), do: Elia.Net.default()

  # SESS-41: the chat's per-chat settings. A state that predates the one map is
  # upgraded on its next call (SESS-15); one that reaches this without it from
  # somewhere else (a message from a loop rather than a call, say) falls back to
  # each setting's default, as it did when they were fields of their own.
  defp settings(state), do: Map.get(state, :settings, default_settings())
  defp default_settings, do: %__MODULE__{}.settings

  # MODEL-16: the selection a chat pins at its first turn goes into the same map
  # as any other setting; it is saved by the message that starts the turn, not
  # here (SESS-14).
  defp put_setting(state, key, value),
    do: %{state | settings: Map.put(settings(state), key, value)}

  # SESS-7, SESS-41: the settings as the snapshot and the `{:settings, …}` event
  # carry them, with the auto-approved tools as their sorted names — the shape
  # the snapshot has always given them.
  defp public_settings(state) do
    %{settings(state) | auto_approve: names(settings(state).auto_approve)}
  end

  # SESS-15: the one settings map of a state that predates it. A value the state
  # already holds as a field of its own is kept, and only the ones it doesn't
  # have are loaded from the chat.
  defp upgraded_settings(old, upgraded) do
    %{
      model:
        from_state(old, :selection, fn ->
          if upgraded.persist, do: Elia.Store.load_model(upgraded.id)
        end),
      auto_approve: from_state(old, :auto_approve, fn -> initial_auto_approve(upgraded, nil) end),
      jail: from_state(old, :jail, fn -> initial_jail(upgraded.id, upgraded.persist, nil) end),
      network:
        from_state(old, :network, fn ->
          initial_network(upgraded.id, upgraded.persist, nil)
        end),
      limits:
        from_state(old, :limits, fn -> initial_limits(upgraded.id, upgraded.persist, nil) end),
      effort: from_state(old, :effort, fn -> initial_effort(upgraded.id, upgraded.persist) end)
    }
  end

  defp from_state(old, key, load),
    do: if(is_map_key(old, key), do: Map.get(old, key), else: load.())

  # SESS-41: the changes of a validated request applied to the one map. The
  # limits and the auto-approved tools are changed by key, the others set whole.
  defp apply_settings(state, changes) do
    settings =
      Enum.reduce(changes, settings(state), fn
        {:model, selection}, settings ->
          Map.put(settings, :model, selection)

        {:jail, on?}, settings ->
          Map.put(settings, :jail, on?)

        {:network, setting}, settings ->
          Map.put(settings, :network, Elia.Net.setting(setting))

        {:effort, effort}, settings ->
          Map.put(settings, :effort, effort)

        {:limits, limits}, settings ->
          Map.put(settings, :limits, Elia.Limits.new(Map.merge(settings.limits, limits)))

        {:auto_approve, tools}, settings ->
          %{settings | auto_approve: put_auto_approve(settings.auto_approve, tools)}
      end)

    %{state | settings: settings}
  end

  # APPR-8: a tool turned on joins the chat's set, one turned off leaves it.
  defp put_auto_approve(set, tools) do
    Enum.reduce(tools, set, fn
      {name, true}, set -> MapSet.put(set, name)
      {name, false}, set -> MapSet.delete(set, name)
    end)
  end

  # APPR-11: turning auto-approval on for a tool approves that tool's calls that
  # are waiting right now, as part of the same change (SESS-16). Nothing more is
  # saved or broadcast for it.
  defp approve_newly_allowed(state, %{auto_approve: tools}) do
    tools
    |> Enum.filter(fn {_name, on?} -> on? end)
    |> Enum.map(fn {name, _on?} -> name end)
    |> Enum.reduce(state, fn name, state -> approve_pending(state, name) end)
  end

  defp approve_newly_allowed(state, _changes), do: state

  # SESS-42: every key of a change is checked before any of it is applied, so a
  # change with something wrong in it changes nothing at all.
  defp validate_settings(state, changes) do
    changes = Map.new(changes)

    with :ok <- check_keys(changes),
         :ok <- check_model(changes),
         :ok <- check_jail(changes),
         :ok <- check_network(changes),
         :ok <- check_effort(changes),
         :ok <- check_auto_approve(state, changes),
         {:ok, limits} <- check_limits(changes) do
      changes =
        if Map.has_key?(changes, :limits), do: Map.put(changes, :limits, limits), else: changes

      {:ok, changes}
    end
  end

  defp check_keys(changes) do
    case Enum.reject(Map.keys(changes), &(&1 in @setting_keys)) do
      [] -> :ok
      keys -> {:error, "Unknown setting: #{Enum.map_join(keys, ", ", &inspect/1)}"}
    end
  end

  # MODEL-1: the chat's selection, or nil for none of its own.
  defp check_model(changes) do
    case Map.fetch(changes, :model) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, selection} when is_map(selection) -> :ok
      {:ok, _other} -> {:error, "model must be a selection or nil"}
    end
  end

  # ISOL-16: on or off.
  defp check_jail(changes) do
    case Map.fetch(changes, :jail) do
      :error -> :ok
      {:ok, on?} when is_boolean(on?) -> :ok
      {:ok, _other} -> {:error, "jail must be true or false"}
    end
  end

  # NET-1, NET-11: one of the three modes, with a list of hosts that are the
  # forms NET-7 gives.
  defp check_network(changes) do
    case Map.fetch(changes, :network) do
      :error ->
        :ok

      {:ok, %{mode: mode} = setting} when mode in [:unrestricted, :allowlist, :none] ->
        case Elia.Net.Allowlist.parse(Map.get(setting, :hosts, [])) do
          {:ok, _hosts} -> :ok
          {:error, entry} -> {:error, network_error(entry)}
        end

      {:ok, _other} ->
        {:error, "network must be unrestricted, allowlist or none"}
    end
  end

  defp network_error(entry) do
    "network hosts: #{inspect(entry)} is not a host, a *.suffix or one of those with a port"
  end

  # LLM-39, LLM-38: one of the three efforts, or nil for the configured one.
  defp check_effort(changes) do
    case Map.fetch(changes, :effort) do
      :error -> :ok
      {:ok, effort} when effort in [nil, "low", "medium", "high"] -> :ok
      {:ok, _other} -> {:error, "Reasoning effort must be low, medium or high"}
    end
  end

  # APPR-8, APPR-13: the tool names to turn on or off. A name can always be
  # turned off; turning one on needs a tool that can need approval in this chat.
  defp check_auto_approve(state, changes) do
    case Map.fetch(changes, :auto_approve) do
      :error ->
        :ok

      {:ok, tools} when is_map(tools) or is_list(tools) ->
        tools |> Map.new() |> Enum.find_value(:ok, &check_tool(state, &1))

      {:ok, _other} ->
        {:error, "auto_approve must name the tools to turn on or off"}
    end
  end

  defp check_tool(_state, {name, _on?}) when not is_binary(name),
    do: {:error, "auto_approve must name its tools by name"}

  defp check_tool(_state, {name, on?}) when not is_boolean(on?),
    do: {:error, "auto_approve: #{name} must be true or false"}

  defp check_tool(_state, {_name, false}), do: nil

  defp check_tool(state, {name, true}) do
    if approvable?(state, name),
      do: nil,
      else: {:error, "auto_approve: #{name} cannot need approval in this chat"}
  end

  # LIMIT-1, LIMIT-7: the limits of a change, checked by the module that owns
  # them.
  defp check_limits(changes) do
    case Map.fetch(changes, :limits) do
      :error -> {:ok, %{}}
      {:ok, limits} when is_map(limits) or is_list(limits) -> Elia.Limits.validate(limits)
      {:ok, _other} -> {:error, "limits must name the limits to change"}
    end
  end

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
  # Returns the state and whether the pass began a fold, which is what decides
  # whether the turn's loop waits for it (COMPACT-42).
  defp compact_at_turn_start(state) do
    options = Compaction.options(state.compaction.options)
    trigger = trigger(state)
    overhead = overhead(state)
    tokens = Compaction.view(state.messages, state.compaction).tokens + overhead

    if options.auto and trigger != nil and tokens > trigger do
      compact(state, target: target(state), overhead: overhead)
    else
      {state, false}
    end
  end

  # COMPACT-6, COMPACT-8, COMPACT-17, COMPACT-40: elide here — a sort and an
  # estimate per item, in the session's own callback — and, when the ladder
  # could not reach the target, fold the summary in a worker of the session's
  # (`start_fold/2`): the fold is a model call, and one that can outlast the
  # seconds a caller waits for. Saving, and the `{:compaction, state}` broadcast
  # that lets a UI redraw its annotations and its estimate, happen only when the
  # state actually changed. Returns the state and whether this pass began a fold.
  defp compact(state, opts) do
    before = state.compaction
    llm = llm_request(state)
    summarizer = Keyword.get(state.loop_opts, :summarizer, Compaction.default_summarizer(llm))

    opts = opts |> Map.new() |> Map.merge(%{summarizer: summarizer, llm: llm})
    {elided, fold?} = Compaction.elide(state.messages, before, opts)

    state = apply_compaction(state, elided)
    if fold?, do: start_fold(state, opts), else: {state, false}
  end

  # COMPACT-40, COMPACT-44: the fold runs in a task under
  # `Elia.Agent.TaskSupervisor` — the supervisor the turn's own loop task runs
  # under — so the session goes on answering its calls while the summary is made,
  # and `own_fold/2` ends the task when the session does, as
  # `Elia.Agent.Loop.own/1` ends the loop (SESS-45). The task is given the state
  # the elision left, which is what its summary describes (COMPACT-18).
  #
  # COMPACT-45, COMPACT-46: one fold is in flight per chat — a manual pass that
  # finds one is refused as busy (the caller checks) and a turn-start pass folds
  # nothing of its own — so a state that already has one keeps it, and the pass
  # reports that it began no fold. Read with `Map.get/2`, as `save_timer` is: a
  # session that outlived a hot reload has no such key.
  defp start_fold(state, opts) do
    if Map.get(state, :fold) == nil do
      session = self()
      messages = state.messages
      compaction = state.compaction

      task =
        Task.Supervisor.async_nolink(Elia.Agent.TaskSupervisor, fn ->
          Compaction.summarize(messages, compaction, opts)
        end)

      own_fold(session, task)
      {Map.put(state, :fold, %{ref: task.ref, pid: task.pid, opts: opts}), true}
    else
      {state, false}
    end
  end

  # COMPACT-44: the fold belongs to the session that started it. The task is
  # started unlinked, so nothing else would end it: the session's `terminate/2`
  # saves and returns (SESS-44) and a kill runs nothing at all. Ends with
  # whichever goes first, the shape `Elia.Agent.Loop.own/1` uses.
  defp own_fold(session, %Task{pid: pid}) do
    spawn(fn ->
      session_ref = Process.monitor(session)
      task_ref = Process.monitor(pid)

      receive do
        {:DOWN, ^session_ref, :process, _, _} -> Process.exit(pid, :kill)
        {:DOWN, ^task_ref, :process, _, _} -> :ok
      end
    end)
  end

  # COMPACT-43: a stop ends a summary in flight — the worker is ended and its
  # result is applied nowhere — and a turn that was waiting on it never starts.
  # Read with `Map.get/2`: a session that outlived a hot reload has no `:fold`.
  defp cancel_fold(state) do
    case Map.get(state, :fold) do
      nil ->
        state

      %{ref: ref, pid: pid} ->
        Task.Supervisor.terminate_child(Elia.Agent.TaskSupervisor, pid)
        Process.demonitor(ref, [:flush])
        Map.put(state, :fold, nil)
    end
  end

  # COMPACT-41: what landed is a summary alone — its text and the boundary it
  # covered — applied to the compaction state as it stands now, so a pin, a
  # ledger entry, a deeper elision or a newer summary written while the fold ran
  # is kept. A fold that produced nothing (COMPACT-20), or one whose boundary is
  # already covered, leaves the state as it is.
  defp apply_fold(state, result) do
    state = %{state | fold: nil}

    state =
      case result do
        {:folded, text, folded} when folded > state.compaction.folded ->
          apply_compaction(state, %{state.compaction | summary: text, folded: folded})

        _ ->
          state
      end

    start_pending_turn(state)
  end

  # COMPACT-42: a turn whose start began a fold starts its loop from that fold's
  # result — whether it landed (COMPACT-41) or not (COMPACT-20). Read with
  # `Map.get/2`, as `save_timer` is.
  defp start_pending_turn(state) do
    case Map.get(state, :pending_turn) do
      nil -> state
      turn_id -> run_turn(%{state | pending_turn: nil}, turn_id)
    end
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
  defp window(state), do: Elia.LLM.context_window(settings(state).model).context_length

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
    llm =
      case Keyword.get(state.loop_opts, :llm, %{}) do
        %{provider: _} = llm -> llm
        llm -> Map.merge(Elia.LLM.selection_request(settings(state).model), llm)
      end

    # VISION-4, VISION-7: whether this turn's model accepts images travels with
    # the request, decided here where the chat's selection is known.
    llm = Map.put_new(llm, :vision, vision(llm, state))

    # SESS-40, LLM-39: the chat's own reasoning effort travels as the request's
    # `:effort`, unless the caller named one, which wins.
    if settings(state).effort,
      do: Map.put_new(llm, :effort, settings(state).effort),
      else: llm
  end

  # VISION-7: the chat's own selection answers when the request is the
  # selection's; a request that names its provider (MODEL-3) is answered by the
  # module it names; and a chat with no selection of its own takes the answer
  # `Elia.LLM` resolves for it (MODEL-15, MODEL-2).
  defp vision(llm, state) do
    selection = settings(state).model

    cond do
      is_nil(llm[:provider]) -> Elia.LLM.vision?(selection)
      is_map(selection) and selection[:model] == llm[:model] -> Elia.LLM.vision?(selection)
      true -> Elia.LLM.module_vision(llm[:provider], llm[:model])
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

  # The chat's workspace root (PROJ-12): the folder of its project, the live
  # tree for a chat in Elia's own project (DEPLOY-1, DEPLOY-3). State from
  # before the field existed (SESS-15) resolves it here.
  defp workspace(state), do: Map.get(state, :workspace) || project(state).folder

  # WD-1, WD-7: the chat's working directory — the one it has, or its workspace
  # root while it works there.
  defp cwd(state), do: Map.get(state, :cwd) || Elia.Workdir.real_root(workspace(state))

  # WD-3: the directory named relative to the workspace root, `.` for the root.
  defp label(state), do: Elia.Workdir.label(cwd(state), workspace(state))

  # WD-7, STORE-46: a chat working in its workspace root carries no entry of its
  # own, so moving back to the root drops the key from the file.
  defp stored_cwd(nil, _state), do: nil

  defp stored_cwd(dir, state) do
    if dir == Elia.Workdir.real_root(workspace(state)), do: nil, else: dir
  end

  # WD-2, WD-7: the working directory saved with the chat, used only while it is
  # still a directory inside the workspace: one a workspace that has moved left
  # behind reads as the workspace root, which is where the chat's tools then run.
  defp load_cwd(id, workspace) do
    case Elia.Store.load_cwd(id) do
      nil ->
        nil

      saved ->
        case Elia.Workdir.resolve(saved, workspace, workspace) do
          {:ok, dir} -> if dir == Elia.Workdir.real_root(workspace), do: nil, else: dir
          {:error, _message} -> nil
        end
    end
  end

  # `when` is `:now` for a message that is a boundary of the turn — what starts
  # it, a stop, a pause, the results that close dangling calls — and `:later`
  # for the loop's own (SESS-44).
  defp append(state, message, timing \\ :now)

  defp append(state, %Message{content: []}, _timing), do: state

  defp append(state, message, timing) do
    # MSGAT-2: the one place a message is stamped as it enters the history, so
    # the item the page is told about and the message saved carry the same moment.
    message = Message.stamp(message)
    broadcast(state, {:message, message})

    state = %{state | messages: state.messages ++ [message]}
    if timing == :later, do: save_later(state), else: save(state)
  end

  # SESS-44: the first unsaved message starts the interval, and the one save at
  # its end writes all of them. SESS-46: a save that failed starts it again, so
  # a pending save means the chat is unsaved whichever way it got that way. The
  # exit trap is set here too, for a session that outlived a hot reload and so
  # never ran this `init/1`.
  defp save_later(%{persist: false} = state), do: state

  defp save_later(state) do
    case Map.get(state, :save_timer) do
      nil ->
        Process.flag(:trap_exit, true)
        token = make_ref()
        timer = Process.send_after(self(), {:save_due, token}, save_interval())
        Map.put(state, :save_timer, {timer, token})

      _pending ->
        state
    end
  end

  defp save_interval,
    do: Application.get_env(:elia, __MODULE__, [])[:save_interval_ms] || 5_000

  # SESS-44: a shutdown — the app stopping or restarting, the chat deleted —
  # saves what the interval had not yet, and a save an earlier failure left
  # unsaved (SESS-46). So does a crash in a callback: the state `terminate/2`
  # gets is the last one a callback returned, which holds only messages that
  # were appended whole.
  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :save_timer), do: save(state, false)
    :ok
  end

  defp save(state), do: save(state, true)

  defp save(%{persist: false} = state, _retry?), do: state

  # `retry?` is false for the one save a shutdown makes: there is no later
  # attempt for a failure to be kept for (SESS-44).
  defp save(state, retry?) do
    # SESS-44: every save writes the whole chat, so it covers any message that
    # was waiting for the interval.
    state =
      case Map.get(state, :save_timer) do
        {timer, _token} ->
          Process.cancel_timer(timer)
          Map.put(state, :save_timer, nil)

        nil ->
          state
      end

    auto = names(settings(state).auto_approve)

    result =
      Elia.Store.save(state.id, state.messages,
        model: settings(state).model,
        auto_approve: auto,
        task: Map.get(state, :task_meta),
        project: project(state).id,
        compaction: saved_compaction(Map.get(state, :compaction)),
        jail: settings(state).jail,
        network: settings(state).network,
        limits: settings(state).limits,
        effort: settings(state).effort,
        # STORE-30, INTR-1: the turn in flight, or nothing when there is
        # none (which takes the entry off the file).
        turn: Map.get(state, :turn),
        title: Map.get(state, :title),
        done: Map.get(state, :done, false),
        # STORE-46, WD-2: the chat's working directory, saved so it
        # outlives this process.
        cwd: stored_cwd(Map.get(state, :cwd), state)
      )

    case result do
      :ok ->
        state

      # SESS-13, SESS-46: logged and not fatal, and the chat is still unsaved —
      # the interval starts again from here, so a pending save is what says so
      # (a shutdown reads it for its own save, SESS-44) and storage that
      # recovers gets the chat written without another change.
      error ->
        Logger.error("Could not save session #{state.id}: #{inspect(error)}")
        if retry?, do: save_later(state), else: state
    end
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

  # SESS-3, INTR-1: a turn starts here. Its record goes into the chat first — the
  # save the message that starts it triggers writes it — then that message, and
  # the loop runs over the history in a task of its own. `message` is what the
  # turn starts with: the user's, or the notice a resumed turn carries
  # (RESUME-3, UI-73), and `resumed: true` says the turn was an automatic resume
  # (RESUME-5, STORE-30).
  #
  # COMPACT-42: the turn-start pass folds its summary in a worker (COMPACT-40), so
  # when it began one the turn waits for it: the record and the message are
  # already in the chat and the turn shows as running, its loop starts from the
  # fold's result, and a stop ends it there like any other turn.
  defp start_turn(state, opts) do
    # COMPACT-5: compaction happens at the start of the turn, before the message
    # that starts it, and again at every step of the loop (COMPACT-29).
    {state, fold?} = compact_at_turn_start(state)

    turn_id = "#{state.id}-#{System.unique_integer([:positive])}"

    # INTR-1: the turn is recorded in the chat as it starts and cleared when it
    # ends (finish_turn).
    turn = %{id: turn_id, started_at: DateTime.utc_now()}
    turn = if opts[:resumed], do: Map.put(turn, :resumed, true), else: turn

    state = %{state | turn_start: length(state.messages), turn: turn}
    state = append(state, Keyword.fetch!(opts, :message))

    if fold?,
      do: set_status(Map.put(state, :pending_turn, turn_id), :running),
      else: run_turn(state, turn_id)
  end

  defp run_turn(state, turn_id) do
    session = self()

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
        # WD-10: the loop reads the chat's working directory at the start of each
        # step, through `{:cwd}` — this is where it stands as the turn begins.
        cwd: cwd(state),
        # ISOL-15: the tool context carries this chat's jail setting, so the
        # shell tools follow it, and its network setting (NET-1), so they follow
        # that too.
        jail: settings(state).jail,
        network: settings(state).network,
        # TIME-2: the turn's start goes into every step's timing record, so the
        # record needs nothing from the chat's saved term, whose turn entry is
        # taken off when the turn ends (STORE-30, INTR-1).
        turn_started_at: state.turn.started_at,
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
    opts = Keyword.merge(Elia.Limits.loop_opts(settings(state).limits), opts)

    task =
      Task.Supervisor.async_nolink(Elia.Agent.TaskSupervisor, fn ->
        Elia.Agent.Loop.run(session, state.messages, opts)
      end)

    set_status(%{state | task: task}, :running)
  end

  # INTR-3: the app stopped while the chat's last turn ran — the record is still
  # there (STORE-30) and no session of this one owned it — so the chat says so.
  # The notice goes into the history, where the transcript keeps it (UI-73), and
  # appending it saves the chat, which clears the record (INTR-1). The status
  # broadcast (SESS-19) is what drops the chat list's marker (UI-72) in every
  # page, including the ones that are not showing this chat. Only a chat that
  # carried such a record gets here (RESUME-2), so it is written unconditionally.
  defp note_interrupted_turn(%{persist: false} = state), do: state

  defp note_interrupted_turn(state) do
    state |> append(interrupted_notice()) |> set_status(:idle)
  end

  # RESUME-2: a session starting for an interrupted chat carries its turn on
  # (RESUME-3) instead of only announcing it — unless the record says the turn
  # was itself resumed automatically (RESUME-5), automatic resume is off
  # (RESUME-6) or the turn had paused at a limit (RESUME-8), when INTR-3's notice
  # is what the chat gets. Which caller started the session makes no difference,
  # so a page opening the chat and the boot scan agree.
  defp resume_or_note(state, nil), do: state
  defp resume_or_note(state, %{resumed: true}), do: note_interrupted_turn(state)

  defp resume_or_note(state, _turn) do
    if resumable?(state), do: resume_turn(state), else: note_interrupted_turn(state)
  end

  defp resumable?(state), do: Elia.Agent.Resumer.enabled?() and not paused?(state)

  # RESUME-8: a turn that was paused at a limit (SESS-27) was waiting for the
  # user's decision, which is the last thing the chat's history holds (LIMIT-10).
  defp paused?(state) do
    case List.last(state.messages) do
      %Message{meta: %{limit: _limit}} -> true
      _ -> false
    end
  end

  # RESUME-3, RESUME-7: the turn carries on over the history the chat already
  # holds, with the notice that says so. A sub-task chat is resumed like any
  # other: nothing has to be put back first, since a child is a child because
  # its saved chat says so (STORE-16, STORE-17).
  defp resume_turn(state) do
    state
    |> put_child_skills()
    |> start_turn(resumed: true, message: resumed_notice())
  end

  # SUBTASK-1, LOOP-17: a sub-task chat's own skill set — the ordinary registry
  # minus the `tasks` skill, so a child can't start a sub-task (SUBTASK-6). A
  # session started again has no skill set of its own to inherit.
  defp put_child_skills(%{task_meta: nil} = state), do: state

  defp put_child_skills(state) do
    project = project(state)

    %{
      state
      | loop_opts:
          Keyword.put_new(state.loop_opts, :skills, fn -> Elia.Skills.for_child(project) end)
    }
  end

  # RESUME-3, UI-73: the notice a resumed turn starts with, marked as INTR-3's is
  # so the transcript shows it as an error row, and part of the history the model
  # is sent (STOP-3).
  defp resumed_notice do
    text = "The app restarted while this turn was running. Carrying on with it."
    message = Message.harness(text)
    %{message | meta: Map.put(message.meta, :interrupted, true)}
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

  # LIMIT-13: the turn has made the same call for the same answer once too
  # often (LOOP-24, LOOP-25).
  defp pause_message({:repetition, name, n}),
    do: "Standing still: #{name} returned the same result #{n} times."

  # STOP-2, LOOP-3, LOOP-20, LOOP-22, LIMIT-13: what a turn that a limit ended
  # says it was.
  defp limit_message({:steps, max}), do: "Stopped after #{max} steps without finishing"

  defp limit_message({:time, ms}),
    do: "Stopped after #{Elia.Agent.Loop.minutes(ms)}: the time budget ran out"

  defp limit_message({:tokens, tokens}),
    do: "Stopped after #{Elia.LLM.Tokens.format(tokens)} tokens: the token budget ran out"

  defp limit_message({:repetition, name, n}),
    do: "Stopped standing still: #{name} returned the same result #{n} times"

  # STOP-1, SESS-38: a turn that didn't finish says so in the transcript, marked
  # with the kind of stop it was (STOP-2), saved as any appended message is and
  # rendered as an error row (UI-82).
  defp stop_notice(kind, text) do
    message = Message.harness(text)
    %{message | meta: Map.put(message.meta, :stopped, kind)}
  end

  # STOP-4: the transcript gets the message and the watchers that read a chat's
  # events get the same text, which is how a sub-task's parent reads a child's
  # failure. The page renders the message, not the event (UI-82).
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

  # LIMIT-13: the standing-still limit is worded as the others are (LIMIT-10).
  defp pause_notice_text({:repetition, name, n}),
    do:
      pause_message({:repetition, name, n}) <>
        " The turn is paused: Continue starts the count over, Fail ends it."

  defp set_status(state, status) do
    broadcast(state, {:status, status})
    # SESS-19
    Registry.update_value(Elia.Agent.Registry, state.id, fn _ -> status end)

    announce_status(state.id, status)

    %{state | status: status}
  end

  # SUBTASK-33, SUBTASK-13, SESS-18: marking a sub-task chat done is what ends
  # the task — the harness builds the result (SUBTASK-9) and it is saved here,
  # with this chat's own metadata, by the one session that owns the chat. A
  # waiting `await_task` returns it (SUBTASK-27). A chat whose result is already
  # saved keeps it (SUBTASK-13), and a chat that isn't a sub-task's is left
  # alone.
  defp end_task(%{task_meta: nil} = state), do: state

  defp end_task(state) do
    if Map.has_key?(state.task_meta, :result) do
      state
    else
      result = %{
        "task_id" => state.id,
        "summary" => last_text(state) || @no_summary
      }

      save(%{state | task_meta: Map.put(state.task_meta, :result, result)})
    end
  end

  # SUBTASK-9: the child's last assistant message — its report of what it did,
  # which is the summary of the result — or nil when it said nothing.
  defp last_text(state) do
    state.messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant} = message ->
        case String.trim(Message.text_content(message)) do
          "" -> nil
          text -> text
        end

      _message ->
        nil
    end)
  end

  # STOP-1, SESS-22, SUBTASK-17, COMPACT-43: what a stop ends besides the turn
  # that is running. Stopping this chat's turn stops the turn of every child of
  # it whose chat isn't marked done, read from the saved chats (STORE-18) — a
  # stop ends a turn and nothing more, so nothing is recorded for it and each
  # child goes on as a sub-task (SUBTASK-16).
  defp stop_children(state) do
    for %{id: child_id, done: false} <- Elia.Store.children(state.id),
        do: stop_session(child_id)

    state
  end

  # COMPACT-42, COMPACT-43: the turn whose start was waiting on a fold, ended as
  # a stop ends a turn whose loop was running — the notice stays after its
  # message, and the turn record goes with the flag (STOP-1, STOP-2, INTR-1).
  # Read with `Map.get/2`: a session that outlived a hot reload has no such key,
  # and then no turn is waiting.
  defp end_pending_turn(state) do
    if Map.get(state, :pending_turn) == nil do
      state
    else
      state
      |> Map.put(:pending_turn, nil)
      |> append(stop_notice(:stopped, "Stopped by the user."))
      |> finish_turn()
    end
  end

  defp stop_session(id) do
    if Elia.Agent.live?(id), do: Elia.Agent.stop(id)
  catch
    :exit, _ -> :ok
  end

  # SESS-19, SESS-35: a change to the chat's done flag reaches this chat's own
  # views and, on the activity topic, the pages that show other chats — which is
  # how a parent's sidebar follows a child being marked done, and how a waiting
  # `await_task` is answered (SUBTASK-27, UI-46, UI-49).
  # What is announced is `:done` when the flag is set, and the chat's own status
  # when it is cleared: either way it is the status its row shows, since a chat
  # marked done shows `done` in place of `idle` (UI-59, UI-80).
  defp announce_done(state, on?) do
    broadcast(state, {:done, on?})
    announce_status(state.id, if(on?, do: :done, else: state.status))
  end

  defp announce_status(id, status) do
    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      Elia.Agent.activity_topic(),
      {:chat_status, id, status}
    )
  end

  defp put_tool_status(state, call_id, status) do
    broadcast(state, {:tool_status, call_id, status})
    put_in(state.tool_status[call_id], status)
  end

  defp broadcast(state, event) do
    Phoenix.PubSub.broadcast(Elia.PubSub, Elia.Agent.topic(state.id), {:agent, state.id, event})
  end
end
