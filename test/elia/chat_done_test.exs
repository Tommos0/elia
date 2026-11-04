defmodule Elia.ChatDoneTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    %{id: Agent.new_id()}
  end

  # A session started for `id`, with the store as it is when the test asks for
  # it (a session loads its saved flag at start, SESS-35).
  defp start_session(id) do
    {:ok, pid} = Agent.ensure_started(id)
    Agent.subscribe(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    pid
  end

  defp listed(id), do: Store.list() |> Enum.filter(&(&1.id == id))

  # A store of its own: a throwaway runtime root, since that is where Elia's
  # data and so the saved chats live (DEPLOY-2), like `store_test.exs` does.
  defp with_empty_store(fun) do
    root = Path.join(System.tmp_dir!(), "elia-done-store-#{Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm_rf!(root)
    end
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 5000)

  defp task_meta do
    %{
      parent_id: Agent.new_id(),
      title: "Add the file",
      brief: "b",
      started_at: DateTime.utc_now(),
      status: "done"
    }
  end

  ## The saved flag (DONE-1, STORE-34)

  # STORE-34, DONE-1: the flag is saved with the chat, and only a done one
  # carries it.
  test "a done chat is saved as done and reopened by saving without it" do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    :ok = Store.save(id, [Message.user("hi")])
    assert Store.load_done(id) == false

    :ok = Store.save(id, [Message.user("hi")], done: true)
    assert Store.load_done(id) == true
    # The chat's history is kept as it was.
    assert [%Message{}] = Store.load(id)

    # Reopening it drops the entry from the file.
    :ok = Store.save(id, [Message.user("hi")], done: false)
    assert Store.load_done(id) == false
  end

  # STORE-34: a chat is open unless it says otherwise, so a missing, corrupt or
  # invalid one answers `false` rather than raising.
  test "an unreadable or missing chat is not done" do
    assert Store.load_done("missing-chat") == false
    assert Store.load_done("../bad") == false

    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    File.write!(Path.join(Store.dir(), id <> ".term"), "not a term")
    assert Store.load_done(id) == false
  end

  # STORE-35, DONE-1: a listed chat carries the flag either way, like
  # STORE-31's `interrupted`.
  test "listed chats carry whether they are done" do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [Message.user("hi")])

    assert [%{done: false}] = listed(id)

    :ok = Store.save(id, [Message.user("hi")], done: true)
    assert [%{done: true}] = listed(id)
  end

  # DONE-3, STORE-35: a task chat's listed status is its task's; the flag plays
  # no part in it.
  test "a task chat is listed under its task status, done or not" do
    child = Agent.new_id()
    on_exit(fn -> Store.delete(child) end)

    :ok = Store.save(child, [Message.user("preamble")], task: task_meta(), done: true)

    assert [entry] = listed(child)
    assert entry.task_status == "done"
    assert entry.title == "Add the file"
    assert EliaWeb.ChatStatus.status(entry, %{}) == "done"
  end

  ## Where you left off (STORE-29, DONE-10)

  # STORE-29, DONE-10: the chat the chat list resumes is the most recent one
  # that is neither a task nor done, and there is none when every chat is done.
  # It has a store of its own (like `store_test.exs`), so only the chats written
  # here are in it.
  test "latest/0 skips a done chat as it skips a task chat" do
    with_empty_store(fn ->
      open = Agent.new_id()
      done = Agent.new_id()
      child = Agent.new_id()

      :ok = Store.save(open, [Message.user("where I left off")])
      :ok = Store.save(done, [Message.user("finished")], done: true)
      :ok = Store.save(child, [Message.user("preamble")], task: task_meta())

      assert Store.latest().id == open

      :ok = Store.save(open, [Message.user("where I left off")], done: true)
      assert Store.latest() == nil
    end)
  end

  ## Setting it (DONE-1, DONE-3, SESS-35)

  # SESS-35, SESS-6, DONE-1: marking the chat done saves it, broadcasts it and
  # shows in the snapshot; reopening it does the same the other way.
  test "set_done/2 marks the chat done and reopens it", %{id: id} do
    :ok = Store.save(id, [Message.user("hi")])
    on_exit(fn -> Store.delete(id) end)
    start_session(id)

    assert {:ok, true} = Agent.set_done(id, true)
    assert_receive {:agent, ^id, {:done, true}}
    assert Agent.snapshot(id).done == true
    assert Store.load_done(id) == true
    assert [%{done: true}] = listed(id)

    assert {:ok, false} = Agent.set_done(id, false)
    assert_receive {:agent, ^id, {:done, false}}
    assert Agent.snapshot(id).done == false
    assert Store.load_done(id) == false
    assert [%{done: false}] = listed(id)
  end

  # SESS-35, SESS-15: a session loads the saved flag, and one whose state
  # predates the field is upgraded on its next call.
  test "a session loads the chat's saved flag", %{id: id} do
    :ok = Store.save(id, [Message.user("hi")], done: true)
    on_exit(fn -> Store.delete(id) end)
    pid = start_session(id)

    assert Agent.snapshot(id).done == true

    # A session that outlived a hot reload (SESS-15).
    :sys.replace_state(pid, &Map.delete(&1, :done))
    assert Agent.snapshot(id).done == true
  end

  # DONE-3, SESS-35: a sub-task is finished by its task status, so it takes no
  # flag of its own.
  test "a sub-task chat is refused" do
    child = Agent.new_id()
    on_exit(fn -> Store.delete(child) end)
    :ok = Store.save(child, [Message.user("preamble")], task: task_meta())
    start_session(child)

    assert {:error, message} = Agent.set_done(child, true)
    assert message =~ "sub-task"

    refute_receive {:agent, ^child, {:done, _}}, 50
    assert Agent.snapshot(child).done == false
    assert Store.load_done(child) == false
  end

  ## Continuing a done chat (DONE-8, DONE-9, SESS-36)

  # DONE-8, DONE-9, SESS-36: a message continues a done chat as it would an
  # idle one, and starting the turn reopens the chat.
  test "a message continues a done chat and reopens it", %{id: id} do
    start_session(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("Carrying on.")]))

    assert {:ok, true} = Agent.set_done(id, true)
    assert_receive {:agent, ^id, {:done, true}}

    assert :ok = Agent.send_message(id, "one more thing")
    # DONE-9: the flag goes with the turn's start, before the model answers.
    assert_receive {:agent, ^id, {:done, false}}
    assert Agent.snapshot(id).done == false

    await_status(id, :idle)

    assert [%Message{role: :user}, %Message{role: :assistant}] = Agent.snapshot(id).messages
    assert Store.load_done(id) == false
    assert [%{done: false}] = listed(id)
  end

  # SESS-36: a message to a chat that isn't done announces nothing, so an
  # ordinary chat's event stream is unchanged.
  test "a message to an open chat broadcasts no flag" do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    start_session(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))

    assert :ok = Agent.send_message(id, "hi")
    await_status(id, :idle)

    refute_receive {:agent, ^id, {:done, _}}, 50
  end

  ## The skill and its tool (DONE-6, DONE-7)

  # DONE-6, SKILL-7: the skill is built in and offers one approval-free tool.
  test "the done skill is built in, and offers one approval-free tool" do
    assert Elia.Skills.Done in Elia.Skills.builtin()

    assert [tool] = Elia.Skills.Done.tools()
    assert tool.name == "mark_done"
    assert Elia.Tool.approval(tool, %{"done" => true}, %{}) == :never
    assert Elia.Skills.Done.instructions() =~ "mark_done"
    # DONE-6: the model is told to do it after the merge, and that it is not a
    # stop.
    assert Elia.Skills.Done.instructions() =~ "master"
  end

  # DONE-6, DONE-7: the tool marks the chat done, reads a missing `done` as
  # true, and reopens it with `done: false`.
  test "the mark_done tool marks the chat done and reopens it" do
    id = Agent.new_id()
    :ok = Store.save(id, [Message.user("hi")])
    on_exit(fn -> Store.delete(id) end)
    start_session(id)

    [tool] = Elia.Skills.Done.tools()

    assert {:ok, output} = Elia.Tool.call(tool, %{}, %{session_id: id})
    assert output =~ "marked done"
    assert Store.load_done(id) == true
    assert_receive {:agent, ^id, {:done, true}}

    assert {:ok, output} = Elia.Tool.call(tool, %{"done" => false}, %{session_id: id})
    assert output =~ "open again"
    assert Store.load_done(id) == false
    assert_receive {:agent, ^id, {:done, false}}
  end

  # DONE-7, DONE-3: a refusal comes back as an error result for the model.
  test "the mark_done tool reports a refusal" do
    child = Agent.new_id()
    on_exit(fn -> Store.delete(child) end)
    :ok = Store.save(child, [Message.user("preamble")], task: task_meta())
    start_session(child)

    [tool] = Elia.Skills.Done.tools()

    assert {:error, message} = Elia.Tool.call(tool, %{}, %{session_id: child})
    assert message =~ "sub-task"
    assert Store.load_done(child) == false
  end
end
