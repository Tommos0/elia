defmodule Elia.Agent.Session do
  @moduledoc """
  One conversation: owns the message history, runs `Elia.Agent.Loop` in a
  task, gates tool approvals and broadcasts progress on
  `Elia.Agent.topic(id)` as `{:agent, id, event}`. History is saved with
  `Elia.Store` after every change and reloaded when the session restarts.

  Events: `{:message, message}`, `{:delta, :text | :reasoning, text}`,
  `{:notice, text}`, `{:status, status}`, `{:tool_status, call_id, status}`,
  `{:usage, usage}`, `{:error, text}`, `{:reset, messages}`,
  `{:model, selection}`, `{:auto_approve, names}`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Elia.LLM.Message

  defstruct [
    :id,
    :task,
    :turn_start,
    # The chat's own model selection (MODEL-1); nil until chosen or pinned.
    :selection,
    messages: [],
    status: :idle,
    # Tool names the user lets run without asking in this chat (APPR-8).
    auto_approve: MapSet.new(),
    # call_id => :awaiting_approval | :running | :done
    tool_status: %{},
    # Provider-reported usage of the last completed model request (CTX-6).
    last_usage: nil,
    approval: nil,
    loop_opts: [],
    persist: true
  ]

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {Elia.Agent.Registry, id}}

  @impl true
  def init(opts) do
    persist = Keyword.get(opts, :persist, true)

    {:ok,
     %__MODULE__{
       id: opts[:id],
       loop_opts: Keyword.get(opts, :loop_opts, []),
       persist: persist,
       messages: if(persist, do: Elia.Store.load(opts[:id]), else: []),
       selection: if(persist, do: Elia.Store.load_model(opts[:id])),
       auto_approve: initial_auto_approve(opts[:id], persist)
     }}
  end

  @impl true
  # SESS-15: upgrade state from before `:selection` or `:auto_approve` existed
  # (a session that outlived a hot reload). Fields it already has are kept.
  def handle_call(msg, from, state)
      when not is_map_key(state, :selection) or not is_map_key(state, :auto_approve) do
    upgraded = Map.merge(%__MODULE__{}, Map.from_struct(state))

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
        else: %{upgraded | auto_approve: initial_auto_approve(upgraded.id, upgraded.persist)}

    handle_call(msg, from, upgraded)
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = Map.take(state, [:id, :messages, :status, :tool_status, :last_usage, :selection])
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

    state = %{state | turn_start: length(state.messages)} |> append(message)
    session = self()
    history = state.messages
    turn_id = "#{state.id}-#{System.unique_integer([:positive])}"
    # The chat's model selected now is used for the whole turn. An explicit
    # provider replaces the selection; other explicit options are merged over it.
    llm =
      case explicit do
        %{provider: _} = llm -> llm
        llm -> Map.merge(Elia.LLM.selection_request(state.selection), llm)
      end

    opts = Keyword.merge(state.loop_opts, session_id: state.id, turn_id: turn_id, llm: llm)

    task =
      Task.Supervisor.async_nolink(Elia.Agent.TaskSupervisor, fn ->
        Elia.Agent.Loop.run(session, history, opts)
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

  def handle_call(:stop, _from, %{task: nil} = state), do: {:reply, :ok, state}

  def handle_call(:stop, _from, state) do
    Task.Supervisor.terminate_child(Elia.Agent.TaskSupervisor, state.task.pid)
    Process.demonitor(state.task.ref, [:flush])

    state =
      state
      |> close_dangling_tool_calls("Cancelled by the user.")
      |> finish_turn()

    broadcast(state, {:notice, "Stopped."})
    {:reply, :ok, state}
  end

  # Messages a stopped loop sent before it died.
  @impl true
  def handle_info({tag, _}, %{task: nil} = state) when tag in [:loop_event, :loop_append] do
    {:noreply, state}
  end

  def handle_info({tag, _, _}, %{task: nil} = state)
      when tag in [:loop_tool_status, :loop_await_approval] do
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

  def handle_info({:loop_usage, usage}, state) when is_map(usage) do
    # CTX-10: remember what we estimated for the history this request sent, so
    # the context indicator can calibrate against the provider's figure.
    skills = Keyword.get(state.loop_opts, :skills) || Elia.Skills.current()
    estimate = Elia.LLM.Context.build(state.messages, skills).total
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

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        :done ->
          state

        :refused ->
          # Roll back to the prefix before this turn; nothing in it was edited.
          # The rolled-back request's usage no longer describes the context (CTX-6).
          state =
            save(%{
              state
              | messages: Enum.take(state.messages, state.turn_start),
                last_usage: nil
            })

          broadcast(state, {:reset, state.messages})
          broadcast(state, {:error, "The model declined this request."})
          state

        {:error, reason} ->
          broadcast(state, {:error, to_string(reason)})
          state
      end

    {:noreply, finish_turn(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    broadcast(state, {:error, "Agent crashed: #{Exception.format_exit(reason)}"})

    state =
      state
      |> close_dangling_tool_calls("The harness crashed while running this tool.")
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
  defp approvable?(state, name) do
    skills = Keyword.get(state.loop_opts, :skills) || Elia.Skills.current()
    Enum.any?(Elia.Skills.tools(skills), &(&1.name == name and &1.approval != :never))
  end

  # `auto_approve` is missing from state that predates it (see SESS-15).
  defp auto_approved?(state, name),
    do: MapSet.member?(Map.get(state, :auto_approve, MapSet.new()), name)

  defp names(set), do: set |> MapSet.to_list() |> Enum.sort()

  defp initial_auto_approve(id, true), do: MapSet.new(Elia.Store.load_auto_approve(id))
  defp initial_auto_approve(_id, false), do: MapSet.new()

  defp append(state, %Message{content: []}), do: state

  defp append(state, message) do
    broadcast(state, {:message, message})
    save(%{state | messages: state.messages ++ [message]})
  end

  defp save(%{persist: false} = state), do: state

  defp save(state) do
    auto = names(Map.get(state, :auto_approve, MapSet.new()))

    with {:error, reason} <-
           Elia.Store.save(state.id, state.messages, model: state.selection, auto_approve: auto) do
      Logger.error("Could not save session #{state.id}: #{inspect(reason)}")
    end

    state
  end

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

  defp finish_turn(state), do: set_status(%{state | task: nil, approval: nil}, :idle)

  defp set_status(state, status) do
    broadcast(state, {:status, status})
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
