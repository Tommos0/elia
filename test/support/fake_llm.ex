defmodule Elia.FakeLLM do
  @moduledoc """
  Scripted provider for tests. Queue turns with `push/1`; each turn is a
  `%Elia.LLM.Message{}` (streamed as text deltas) or a
  `fn request, on_event -> result end`. Requests are recorded for `requests/0`.

  A provider serves only the chats of the test that started it (SUITE-9): a call
  from a chat whose session was already running when the provider started is
  refused, which ends that turn and takes no scripted turn. A session that
  outlived the test which scripted it — one the boot scan of another test
  started, say — therefore cannot take a turn another test scripted. Start the
  provider before the sessions a test drives, or its own chats are refused.
  """

  @behaviour Elia.LLM.Provider

  use Agent

  require Logger

  alias Elia.LLM.Message

  def start_link(_),
    do: Agent.start_link(fn -> %{turns: [], reqs: [], earlier: running()} end, name: __MODULE__)

  def push(turn), do: Agent.update(__MODULE__, &%{&1 | turns: &1.turns ++ [turn]})

  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.reqs))

  def assistant(blocks), do: %Message{role: :assistant, content: blocks}

  def tool_call(id, name, input), do: %{type: :tool_call, id: id, name: name, input: input}

  @impl true
  def stream(request, on_event) do
    # SUITE-9: who is calling is read here, in the caller. Inside the Agent's own
    # process — where the state is updated — there are no callers to read.
    caller = caller()

    case Agent.get_and_update(__MODULE__, &take(&1, request, caller)) do
      {:refused, what} ->
        Logger.warning("FakeLLM: refused a model call from #{what} (SUITE-9)")
        {:error, "FakeLLM: #{what} is not this test's to serve"}

      nil ->
        {:error, "FakeLLM: no scripted turn"}

      fun when is_function(fun, 2) ->
        fun.(request, on_event)

      %Message{} = message ->
        for %{type: :text, text: text} <- message.content, do: on_event.({:text_delta, text})
        stop = if Message.tool_calls(message) == [], do: :end_turn, else: :tool_use
        {:ok, %{message: message, stop_reason: stop, model: "fake", usage: %{}}}
    end
  end

  # SUITE-9: the next scripted turn and the request recorded with it, or the
  # refusal of a call from a session that predates this provider. A refused call
  # takes no turn and is not recorded: it is not a request this test made.
  defp take(state, request, caller) do
    case refused(state, caller) do
      nil ->
        case state.turns do
          [turn | rest] -> {turn, %{state | turns: rest, reqs: [request | state.reqs]}}
          [] -> {nil, %{state | reqs: [request | state.reqs]}}
        end

      what ->
        {{:refused, what}, state}
    end
  end

  # SUITE-9: what to name in the refusal, or nil when the call is this test's.
  defp refused(state, caller) do
    cond do
      is_binary(caller.chat) and MapSet.member?(state.earlier.chats, caller.chat) ->
        "chat #{caller.chat}"

      Enum.any?(caller.pids, &MapSet.member?(state.earlier.pids, &1)) ->
        "a session of an earlier test"

      true ->
        nil
    end
  end

  # The chat a call belongs to, read from the loop that made it: the loop runs in
  # a task of the session's, so the session is one of the task's callers and the
  # registry names the chat it serves. The pids are kept too, since a loop is
  # started unlinked and can outlive the session it belongs to, and the registry
  # then names no chat for it.
  defp caller do
    pids =
      [self() | List.wrap(Process.get(:"$callers")) ++ List.wrap(Process.get(:"$ancestors"))]

    # $ancestors names a supervisor by module as well as by pid.
    pids = Enum.filter(pids, &is_pid/1)

    %{pids: pids, chat: Enum.find_value(pids, &served/1)}
  end

  # The chat a session's pid serves, or nil for a process that isn't one.
  defp served(pid) do
    with true <- Process.whereis(Elia.Agent.Registry) != nil,
         [id | _] <- Registry.keys(Elia.Agent.Registry, pid) do
      id
    else
      _ -> nil
    end
  end

  # SUITE-9: the chats and the sessions that were already running when this
  # provider started — everything that is not this test's to serve.
  defp running do
    pids = session_pids()

    chats =
      if Process.whereis(Elia.Agent.Registry) do
        Enum.flat_map(pids, &Registry.keys(Elia.Agent.Registry, &1))
      else
        []
      end

    %{chats: MapSet.new(chats), pids: MapSet.new(pids)}
  end

  defp session_pids do
    if Process.whereis(Elia.Agent.Supervisor) do
      # A module-based child spec reports the module (or an id it sets) as the
      # child's id, so the id is not matched on here.
      for {_id, pid, :worker, _} <- DynamicSupervisor.which_children(Elia.Agent.Supervisor),
          is_pid(pid),
          do: pid
    else
      []
    end
  end
end
