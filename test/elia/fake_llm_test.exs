defmodule Elia.FakeLLMTest do
  # SUITE-9: what a test's scripted provider serves. The file drives whole turns
  # through the sessions it starts, so it is not async.
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  @moduletag timeout: 60_000

  setup do
    # A chat of "another test", its session already running: started before this
    # test's provider, which is what makes it not this test's to serve.
    stale = Agent.new_id()
    {:ok, _pid} = Agent.ensure_started(stale)
    Agent.subscribe(stale)

    start_supervised!(FakeLLM)

    on_exit(fn ->
      stop_session(stale)
      Store.delete(stale)
    end)

    %{stale: stale}
  end

  # SUITE-9
  test "a call from a chat whose session predates the provider is refused, and takes no turn", %{
    stale: stale
  } do
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    # The call is refused, so the turn ends rather than taking the scripted turn.
    :ok = Agent.send_message(stale, "hello")
    assert_receive {:agent, ^stale, {:status, :idle}}, 10_000

    # The refused call is not a request this test made, so it is not recorded.
    assert FakeLLM.requests() == []

    # The turn this test scripted is still there for this test's own chat, whose
    # session started after the provider did.
    fresh = Agent.new_id()
    {:ok, _pid} = Agent.ensure_started(fresh)
    Agent.subscribe(fresh)
    on_exit(fn -> stop_session(fresh) end)

    :ok = Agent.send_message(fresh, "hello")

    assert_receive {:agent, ^fresh, {:delta, :text, "Done."}}, 10_000
    assert_receive {:agent, ^fresh, {:status, :idle}}, 10_000
    assert [_request] = FakeLLM.requests()
  end

  # SUITE-9
  test "the provider serves the chats its own test starts" do
    id = Agent.new_id()
    {:ok, _pid} = Agent.ensure_started(id)
    Agent.subscribe(id)
    on_exit(fn -> stop_session(id) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hi.")]))
    :ok = Agent.send_message(id, "hello")

    assert_receive {:agent, ^id, {:delta, :text, "Hi."}}, 10_000
    assert_receive {:agent, ^id, {:message, %Message{role: :assistant}}}, 10_000
    assert [_request] = FakeLLM.requests()
  end

  defp stop_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id),
        do: DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    :ok
  end
end
