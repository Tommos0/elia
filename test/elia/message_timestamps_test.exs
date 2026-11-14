defmodule Elia.MessageTimestampsTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.{Message, OpenAI}

  # MSGAT-1 to MSGAT-4, MSGAT-8: every message a chat appends is stamped with
  # the moment it arrived, the stamp is saved and loaded with the chat, and
  # nothing else about the message, the provider request or the saved chat
  # changes.
  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  defp start_chat do
    id = Agent.new_id()
    {:ok, pid} = Agent.ensure_started(id)
    Agent.subscribe(id)

    on_exit(fn ->
      DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
      Store.delete(id)
    end)

    id
  end

  defp await_status(id, status) do
    assert_receive {:agent, ^id, {:status, ^status}}, 5000
  end

  # MSGAT-1: the moment is recorded on the message itself, in the `meta` a
  # provider is never sent (LLM-5).
  test "a message appended to a chat carries the moment it arrived" do
    id = start_chat()
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))

    before = DateTime.utc_now()
    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)
    done = DateTime.utc_now()

    assert [user, assistant] = Store.load(id)

    for message <- [user, assistant] do
      assert %DateTime{} = at = Message.at(message)
      assert message.meta[:at] == at
      assert DateTime.compare(at, before) in [:eq, :gt]
      assert DateTime.compare(at, done) in [:eq, :lt]
    end
  end

  # MSGAT-2: the session is the one place a message is stamped, so the item the
  # page is told about and the message on disk carry the same moment.
  test "the page is told the same moment the chat saves" do
    id = start_chat()
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))

    :ok = Agent.send_message(id, "hi")

    assert_receive {:agent, ^id, {:message, %Message{role: :user} = told}}, 5000
    assert_receive {:agent, ^id, {:message, %Message{role: :assistant} = reply}}, 5000
    await_status(id, :idle)

    assert [user, assistant] = Store.load(id)
    assert Message.at(told) == Message.at(user)
    assert Message.at(reply) == Message.at(assistant)
    assert %DateTime{} = Message.at(user)
  end

  # MSGAT-2: a message that already carries a stamp keeps it.
  test "a message that already carries a stamp keeps it" do
    at = DateTime.add(DateTime.utc_now(), -3600, :second)
    message = %{Message.user("hi") | meta: %{at: at}}

    assert Message.stamp(message) == message
    assert Message.at(Message.stamp(message)) == at
  end

  # MSGAT-3: a message saved before this change carries no stamp, and reading it
  # answers none rather than failing.
  test "a message without a stamp reads as none" do
    assert Message.at(Message.user("hi")) == nil
    assert Message.at(%Message{role: :tool, content: [Message.tool_result("c1", "out")]}) == nil

    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user("hi")])

    assert [message] = Store.load(id)
    assert Message.at(message) == nil
  end

  # MSGAT-4: the stamp is saved with the chat and loaded with it, so a chat
  # opened after a restart shows the same times it showed when they arrived.
  test "the stamp is saved with the chat and loaded with it" do
    id = start_chat()
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))

    :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    stamps = Enum.map(Store.load(id), &Message.at/1)
    assert [%DateTime{}, %DateTime{}] = stamps

    # The session starts again and reads the same stamps from the file.
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    {:ok, restarted} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, restarted) end)

    assert Enum.map(Agent.snapshot(id).messages, &Message.at/1) == stamps
  end

  # MSGAT-8: a stamp changes nothing else — a provider is sent none (LLM-5), and
  # the saved chat keeps the keys STORE-1 lists, since a stamp lives inside a
  # message rather than being a key of the chat.
  test "a stamp reaches neither the provider nor the chat's keys" do
    stamped = %{Message.user("hi") | meta: %{at: DateTime.add(DateTime.utc_now(), -60, :second)}}

    assert [%{"role" => "user", "content" => "hi"}] = OpenAI.encode_messages([stamped])

    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [stamped])

    chat = Store.dir() |> Path.join(id <> ".term") |> File.read!() |> :erlang.binary_to_term()
    assert Enum.sort(Map.keys(chat)) == [:created_at, :messages, :updated_at, :version]
    assert [%Message{meta: %{at: %DateTime{}}}] = chat.messages
  end
end
