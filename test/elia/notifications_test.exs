defmodule Elia.NotificationsTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase

  alias Elia.{Agent, Notifications, Push, Store}
  alias Elia.Notifications.Recorder

  # The notifications Elia keeps for the user (`specs/notifications.md`): the
  # events that record an entry, what an entry holds, and what reading one does.
  # The list lives in the settings database, so these tests are not async.

  setup do
    reset_settings()
    :ok
  end

  # NOTIF-1
  test "the status changes that record an entry, and the ones that don't" do
    # Waiting for the user, whenever it starts.
    assert Recorder.reason(nil, :awaiting_approval) == :approval
    assert Recorder.reason(:running, :awaiting_approval) == :approval
    assert Recorder.reason(nil, :awaiting_input) == :input

    # A turn that ended.
    assert Recorder.reason(:running, :idle) == :finished
    assert Recorder.reason(:running, :paused) == :paused

    # A turn starting, a status repeated, and a chat that was never running.
    assert Recorder.reason(nil, :running) == nil
    assert Recorder.reason(:idle, :idle) == nil
    assert Recorder.reason(:awaiting_approval, :running) == nil
    assert Recorder.reason(nil, :idle) == nil
    assert Recorder.reason(:paused, :idle) == nil
  end

  # NOTIF-1, NOTIF-2
  test "a chat that needs the user is recorded, with what it is about" do
    id = start_chat("Deploy the fix")

    broadcast(id, :running)
    broadcast(id, :awaiting_approval)

    assert [entry] = await_entries(1)
    assert entry.chat_id == id
    assert entry.title == "Deploy the fix"
    assert entry.reason == :approval
    assert entry.read == false
    assert DateTime.diff(DateTime.utc_now(), entry.at) < 5
    assert Notifications.unread_count() == 1
  end

  # NOTIF-1
  test "a turn that ends is recorded once, and only when it was running" do
    id = start_chat()

    # A chat that was never running: loading its page or a restart's status is
    # not a turn ending.
    broadcast(id, :idle)
    Process.sleep(50)
    assert Notifications.list() == []

    broadcast(id, :running)
    broadcast(id, :idle)
    assert [entry] = await_entries(1)
    assert entry.reason == :finished

    # The same status again is not a second entry.
    broadcast(id, :idle)
    Process.sleep(50)
    assert length(Notifications.list()) == 1
  end

  # NOTIF-1
  test "a question awaiting an answer and a turn paused at a limit are recorded" do
    id = start_chat()

    broadcast(id, :awaiting_input)
    assert [entry] = await_entries(1)
    assert entry.reason == :input

    broadcast(id, :running)
    broadcast(id, :paused)
    assert [paused, input] = await_entries(2)
    assert paused.reason == :paused
    assert input.reason == :input
  end

  # NOTIF-1: nothing push needs is needed for the list to be kept.
  test "an entry is recorded with no subscription and no push service" do
    id = start_chat()

    broadcast(id, :awaiting_approval)

    assert [entry] = await_entries(1)
    assert entry.chat_id == id
  end

  # NOTIF-4
  test "an entry for the chat the user is looking at is recorded read" do
    id = start_chat()

    # This test process stands in for the chat's page: it is visible.
    assert :ok = Push.Viewers.set(id, self(), true)
    broadcast(id, :awaiting_approval)

    assert [entry] = await_entries(1)
    assert entry.read == true
    assert Notifications.unread_count() == 0

    # A hidden page is not a page in front of the user (PUSH-13).
    assert :ok = Push.Viewers.set(id, self(), false)
    broadcast(id, :running)
    broadcast(id, :idle)

    assert [finished, _approval] = await_entries(2)
    assert finished.read == false
    assert Notifications.unread_count() == 1
  end

  # NOTIF-3
  test "the list keeps the newest 50 entries" do
    for i <- 1..55, do: Notifications.record("chat-#{i}", :finished)

    entries = Notifications.list()
    assert length(entries) == 50
    assert hd(entries).chat_id == "chat-55"
    assert List.last(entries).chat_id == "chat-6"
  end

  # NOTIF-13
  test "two events for one chat are two entries, and an entry outlives its chat" do
    id = start_chat("Fix the bug")

    broadcast(id, :running)
    broadcast(id, :idle)
    broadcast(id, :awaiting_approval)

    assert [approval, finished] = await_entries(2)
    assert approval.reason == :approval
    assert finished.reason == :finished

    # The title is what the entry keeps, so it is still there once the chat is
    # gone.
    Store.delete(id)
    assert [%{title: "Fix the bug"}, %{title: "Fix the bug"}] = Notifications.list()
  end

  # NOTIF-7
  test "one entry is marked read on its own" do
    first = Notifications.record("chat-1", :finished)
    Notifications.record("chat-2", :finished)

    :ok = Notifications.mark_read(first.id)

    assert Notifications.unread_count() == 1
    assert Enum.find(Notifications.list(), &(&1.id == first.id)).read == true
  end

  # NOTIF-8
  test "every entry for one chat is marked read, and another chat's is not" do
    Notifications.record("chat-1", :approval)
    Notifications.record("chat-2", :finished)
    Notifications.record("chat-1", :finished)

    :ok = Notifications.mark_chat_read("chat-1")

    assert Notifications.unread_count() == 1
    assert Enum.filter(Notifications.list(), &(&1.chat_id == "chat-1")) |> Enum.all?(& &1.read)
    assert Enum.find(Notifications.list(), &(&1.chat_id == "chat-2")).read == false
  end

  # NOTIF-9
  test "every entry is marked read, and the list is cleared" do
    Notifications.record("chat-1", :approval)
    Notifications.record("chat-2", :finished)

    :ok = Notifications.mark_all_read()
    assert Notifications.unread_count() == 0
    assert length(Notifications.list()) == 2

    :ok = Notifications.clear()
    assert Notifications.list() == []
    assert Notifications.unread_count() == 0
  end

  # NOTIF-12
  test "a store without the key reads as an empty list" do
    assert Notifications.list() == []
    assert Notifications.unread_count() == 0
  end

  # NOTIF-12: every change is one update of the one key (CONF-29), so changes
  # that overlap take effect in one order and none of them is lost.
  test "recordings and markings that overlap all take effect" do
    recordings =
      for i <- 1..20, do: Task.async(fn -> Notifications.record("chat-#{i}", :finished) end)

    Enum.each(recordings, &Task.await/1)

    assert length(Notifications.list()) == 20
    assert Notifications.unread_count() == 20

    markings = for _ <- 1..20, do: Task.async(fn -> Notifications.mark_all_read() end)
    Enum.each(markings, &Task.await/1)

    assert length(Notifications.list()) == 20
    assert Notifications.unread_count() == 0
  end

  # NOTIF-10
  test "a change is announced for a page to follow" do
    :ok = Notifications.subscribe()

    entry = Notifications.record("chat-1", :finished)
    assert_receive {:notifications, [^entry]}

    Notifications.mark_all_read()
    assert_receive {:notifications, [%{id: id, read: true}]}
    assert id == entry.id

    Notifications.clear()
    assert_receive {:notifications, []}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp start_chat(title \\ nil) do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [], if(title, do: [title: title], else: []))
    id
  end

  defp broadcast(id, status),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})

  # The recorder follows the activity topic in its own process, so an entry it
  # has recorded lands a moment after the broadcast that caused it.
  defp await_entries(count, tries \\ 200)

  defp await_entries(count, 0),
    do: flunk("only #{length(Notifications.list())} of #{count} entries")

  defp await_entries(count, tries) do
    case Notifications.list() do
      entries when length(entries) >= count ->
        entries

      _entries ->
        Process.sleep(10)
        await_entries(count, tries - 1)
    end
  end
end
