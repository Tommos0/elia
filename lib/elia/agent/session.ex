defmodule Elia.Agent.Session do
  @moduledoc """
  One conversation: owns the message history, runs `Elia.Agent.Loop` in a
  task, gates tool approvals and broadcasts progress on
  `Elia.Agent.topic(id)` as `{:agent, id, event}`. History is saved with
  `Elia.Store` after every change and reloaded when the session restarts.

  Events: `{:message, message}`, `{:delta, :text | :reasoning, text}`,
  `{:notice, text}`, `{:status, status}`, `{:tool_status, call_id, status}`,
  `{:error, text}`, `{:reset, messages}`.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Elia.LLM.Message

  defstruct [
    :id,
    :task,
    :turn_start,
    messages: [],
    status: :idle,
    # call_id => :awaiting_approval | :running | :done
    tool_status: %{},
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
       messages: if(persist, do: Elia.Store.load(opts[:id]), else: [])
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.take(state, [:id, :messages, :status, :tool_status]), state}
  end

  def handle_call({:send_message, _text}, _from, %{status: status} = state)
      when status != :idle do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_message, text}, _from, state) do
    message = Message.user(text)
    state = %{state | turn_start: length(state.messages)} |> append(message)
    session = self()
    history = state.messages
    turn_id = "#{state.id}-#{System.unique_integer([:positive])}"
    opts = Keyword.merge(state.loop_opts, session_id: state.id, turn_id: turn_id)

    task =
      Task.Supervisor.async_nolink(Elia.Agent.TaskSupervisor, fn ->
        Elia.Agent.Loop.run(session, history, opts)
      end)

    {:reply, :ok, set_status(%{state | task: task}, :running)}
  end

  def handle_call({:decide, call_id, decision}, _from, %{approval: {pid, decisions}} = state)
      when is_map_key(decisions, call_id) and decision in [:approve, :deny] do
    decisions = Map.put(decisions, call_id, decision)
    status = if decision == :approve, do: :approved, else: :done
    state = put_tool_status(state, call_id, status)

    state =
      if Enum.any?(decisions, fn {_, d} -> d == :pending end) do
        %{state | approval: {pid, decisions}}
      else
        send(pid, {:approval_decisions, decisions})
        set_status(%{state | approval: nil}, :running)
      end

    {:reply, :ok, state}
  end

  def handle_call({:decide, _call_id, _decision}, _from, state) do
    {:reply, {:error, :not_pending}, state}
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

  def handle_info({:loop_tool_status, call_id, status}, state) do
    {:noreply, put_tool_status(state, call_id, status)}
  end

  def handle_info({:loop_await_approval, pid, calls}, state) do
    state =
      Enum.reduce(calls, state, &put_tool_status(&2, &1.id, :awaiting_approval))

    decisions = Map.new(calls, &{&1.id, :pending})
    {:noreply, set_status(%{state | approval: {pid, decisions}}, :awaiting_approval)}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        :done ->
          state

        :refused ->
          # Roll back to the prefix before this turn; nothing in it was edited.
          state = save(%{state | messages: Enum.take(state.messages, state.turn_start)})
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

  defp append(state, %Message{content: []}), do: state

  defp append(state, message) do
    broadcast(state, {:message, message})
    save(%{state | messages: state.messages ++ [message]})
  end

  defp save(%{persist: false} = state), do: state

  defp save(state) do
    with {:error, reason} <- Elia.Store.save(state.id, state.messages) do
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
