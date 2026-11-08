defmodule Elia.Push.NotifierTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase
  import Elia.PushCase

  alias Elia.Push
  alias Elia.Push.Notifier

  setup do
    reset_settings()
    configure(Push)
    stub_push_service()
    on_exit(&reset_push/0)
    :ok
  end

  # PUSH-11, PUSH-12
  test "the status changes that notify, and the ones that don't" do
    # Waiting for the user, whenever it starts.
    assert Notifier.reason(nil, :awaiting_approval) == :approval
    assert Notifier.reason(:running, :awaiting_approval) == :approval
    assert Notifier.reason(nil, :awaiting_input) == :input

    # A turn that ended.
    assert Notifier.reason(:running, :idle) == :finished
    assert Notifier.reason(:running, :paused) == :paused

    # A turn starting, a status repeated, and a chat that was never running.
    assert Notifier.reason(nil, :running) == nil
    assert Notifier.reason(:idle, :idle) == nil
    assert Notifier.reason(:awaiting_approval, :running) == nil
    assert Notifier.reason(nil, :idle) == nil
    assert Notifier.reason(:paused, :idle) == nil
  end

  # PUSH-11
  test "a chat waiting for approval notifies the subscriptions" do
    receiver = store()
    chat = Elia.Agent.new_id()

    broadcast(chat, :running)
    broadcast(chat, :awaiting_approval)

    assert_receive {:push_request, "/sub/1", _headers, body}, 2_000

    sent = decoded_payload(body, receiver)
    assert sent["body"] == "Needs your approval."
    assert sent["url"] == "/c/" <> chat
    assert sent["tag"] == "chat-" <> chat
  end

  # PUSH-11
  test "a chat waiting for an answer notifies" do
    receiver = store()
    chat = Elia.Agent.new_id()

    broadcast(chat, :awaiting_input)

    assert_receive {:push_request, "/sub/1", _headers, body}, 2_000
    assert decoded_payload(body, receiver)["body"] == "Needs your answer."
  end

  # PUSH-12
  test "a turn that ends notifies once, and only when it was running" do
    receiver = store()
    chat = Elia.Agent.new_id()

    # An idle chat that was never running says nothing: a chat loading its page
    # or a restart's status is not a turn ending.
    broadcast(chat, :idle)
    refute_receive {:push_request, _path, _headers, _body}, 200

    broadcast(chat, :running)
    broadcast(chat, :idle)

    assert_receive {:push_request, "/sub/1", _headers, body}, 2_000
    assert decoded_payload(body, receiver)["body"] == "Finished."

    # The same status again is not a second notification.
    broadcast(chat, :idle)
    refute_receive {:push_request, _path, _headers, _body}, 200
  end

  # PUSH-12
  test "a turn paused at a limit notifies" do
    receiver = store()
    chat = Elia.Agent.new_id()

    broadcast(chat, :running)
    broadcast(chat, :paused)

    assert_receive {:push_request, "/sub/1", _headers, body}, 2_000
    assert decoded_payload(body, receiver)["body"] == "Paused at a limit."
  end

  # PUSH-13
  test "a chat the user is looking at is not notified, and a hidden page does not count" do
    receiver = store()
    chat = Elia.Agent.new_id()

    # This test process stands in for the chat's page: it is visible.
    assert :ok = Push.Viewers.set(chat, self(), true)
    broadcast(chat, :awaiting_approval)
    refute_receive {:push_request, _path, _headers, _body}, 200

    # A hidden page is not a page in front of the user.
    assert :ok = Push.Viewers.set(chat, self(), false)
    broadcast(chat, :awaiting_input)

    assert_receive {:push_request, "/sub/1", _headers, body}, 2_000
    assert decoded_payload(body, receiver)["body"] == "Needs your answer."
  end

  # PUSH-17
  test "nothing is sent when nothing is subscribed" do
    chat = Elia.Agent.new_id()

    broadcast(chat, :awaiting_approval)
    refute_receive {:push_request, _path, _headers, _body}, 200
  end

  defp broadcast(chat_id, status) do
    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      Elia.Agent.activity_topic(),
      {:chat_status, chat_id, status}
    )
  end
end
