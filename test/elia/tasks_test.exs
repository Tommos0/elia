defmodule Elia.TasksTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, Checkpoint, FakeLLM, Store, Tasks}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  setup do
    root = Elia.Workspace.root()
    File.write!(Path.join(root, ".gitignore"), "/.elia/\n")
    commit_all("start")

    start_supervised!(FakeLLM)
    parent = new_session()

    on_exit(fn ->
      for entry <- Store.list(1000), Map.get(entry, :parent_id) == parent do
        stop_session(entry.id)
        Store.delete(entry.id)
      end

      for file <- ~w(.gitignore child.txt dirty.txt rebase.txt skills/note.txt lib/broken.ex) do
        File.rm(Path.join(root, file))
      end

      # Back to a repository without commits, as test_helper.exs leaves it.
      git(["update-ref", "-d", "HEAD"])
      git(["rm", "-r", "--cached", "-q", "-f", "."])
    end)

    %{parent: parent}
  end

  ## Helpers

  defp new_session do
    id = Agent.new_id()
    {:ok, _pid} = Agent.ensure_started(id, loop_opts: [llm: %{provider: FakeLLM}])
    Agent.subscribe(id)
    on_exit(fn -> stop_session(id) end)
    id
  end

  defp stop_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id),
        do: DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    Store.delete(id)
  end

  defp git(args) do
    System.cmd("git", ["-c", "user.name=T", "-c", "user.email=t@example.com" | args],
      cd: Elia.Workspace.root(),
      stderr_to_stdout: true
    )
  end

  defp commit_all(message) do
    {_, 0} = git(["add", "-A"])
    {_, 0} = git(["commit", "-q", "--allow-empty", "-m", message])
    {head, 0} = git(["rev-parse", "HEAD"])
    String.trim(head)
  end

  defp commit_file(name) do
    File.write!(Path.join(Elia.Workspace.root(), name), "x\n")
    commit_all("child work")
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 20_000)

  defp reply(blocks, stop \\ nil) do
    message = FakeLLM.assistant(blocks)
    stop = stop || if Message.tool_calls(message) == [], do: :end_turn, else: :tool_use
    {:ok, %{message: message, stop_reason: stop, model: "fake", usage: %{}}}
  end

  defp spawn_call(input, id \\ "s1"), do: FakeLLM.tool_call(id, "spawn_task", input)

  defp finish_call(status, summary, questions \\ []) do
    FakeLLM.tool_call("f1", "finish_task", %{
      "status" => status,
      "summary" => summary,
      "questions" => questions
    })
  end

  defp tool_names(request), do: Enum.map(request.tools, & &1.name)

  defp parent_requests, do: Enum.filter(FakeLLM.requests(), &("spawn_task" in tool_names(&1)))

  # The result of the parent's last tool call: {content, is_error}.
  defp last_tool_result do
    request = List.last(parent_requests())

    %Message{role: :tool, content: [%{content: content, is_error: error?}]} =
      List.last(request.messages)

    {content, error?}
  end

  # Runs the parent through one spawn_task call, approving it.
  defp run_spawn(parent, text \\ "go") do
    :ok = Agent.send_message(parent, text)
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)
  end

  # Pushes a spawn call and a closing text for the parent, then runs it.
  defp refused_spawn(parent, input \\ %{"title" => "T", "brief" => "B"}) do
    FakeLLM.push(FakeLLM.assistant([spawn_call(input)]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))
    run_spawn(parent)
    last_tool_result()
  end

  defp children_of(parent),
    do: Enum.filter(Store.list(1000), &(Map.get(&1, :parent_id) == parent))

  ## Tests

  # SUBTASK-1
  test "a parent has spawn_task and a child has finish_task, never both" do
    parent = Enum.flat_map(Elia.Skills.current(), & &1.tools) |> Enum.map(& &1.name)
    child = Elia.Skills.Tasks.child_skills() |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name)

    assert "spawn_task" in parent
    refute "finish_task" in parent
    assert "finish_task" in child
    refute "spawn_task" in child
    assert "shell" in child
  end

  # SUBTASK-2, SUBTASK-22
  test "spawn_task and reset_task need approval" do
    assert [
             %Elia.Tool{name: "spawn_task", approval: :required},
             %Elia.Tool{name: "reset_task", approval: :required}
           ] = Elia.Skills.Tasks.tools()
  end

  # SUBTASK-2, 5, 6, 7, 8, 9, 11, 13, SUBTASK-4 (depth)
  test "a parent hands work to a child and gets a structured result", %{parent: parent} do
    test_pid = self()
    default_model = Elia.Settings.get(:model)

    FakeLLM.push(
      FakeLLM.assistant([
        spawn_call(%{
          "title" => "Add file",
          "brief" => "Create child.txt and commit it.",
          "model" => "other-model"
        })
      ])
    )

    FakeLLM.push(fn request, _on_event ->
      active = Tasks.active()
      send(test_pid, {:child_started, active, request})
      commit_file("child.txt")

      send(
        test_pid,
        {:nested,
         Tasks.spawn_task(%{"title" => "t", "brief" => "b"}, %{session_id: active.child_id})}
      )

      reply([finish_call("done", "Made child.txt", ["Rename it?"])])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("The task is done.")]))

    # SUBTASK-6: the parent's auto-approved tools are auto-approved in the child too.
    Agent.set_auto_approve(parent, "shell", true)

    run_spawn(parent, "do it")

    # SUBTASK-11: the lock was held by the child while it ran, and is free now.
    assert_receive {:child_started, %{child_id: child, parent_id: ^parent}, request}
    assert Tasks.active() == nil

    # SUBTASK-5: the child's first message is the preamble and the brief.
    assert [%Message{role: :user} = brief | _] = request.messages
    assert Message.text_content(brief) =~ "sub-task agent"
    assert Message.text_content(brief) =~ "Create child.txt and commit it."

    # SUBTASK-1, 6: the child's own tools, and the model that was asked for.
    assert "finish_task" in tool_names(request)
    refute "spawn_task" in tool_names(request)
    assert request.system =~ "## Skill: task\n"
    assert request.model == "other-model"
    assert %{model: "other-model"} = Agent.snapshot(child).selection
    assert Elia.Settings.get(:model) == default_model

    # SUBTASK-4: a child can't start a child.
    assert_receive {:nested, {:error, "Not started: a sub-task can't start" <> _}}

    # SUBTASK-9: the harness fills in the commit and the changed files.
    {content, false} = last_tool_result()
    {head, 0} = git(["rev-parse", "HEAD"])

    assert %{
             "status" => "done",
             "summary" => "Made child.txt",
             "questions" => ["Rename it?"],
             "files" => ["child.txt"],
             "commit" => commit,
             "task_id" => ^child,
             "reason" => nil
           } = decoded = Jason.decode!(content)

    # SUBTASK-21: a done task has no start commit or tree state.
    refute Map.has_key?(decoded, "tree_clean")
    refute Map.has_key?(decoded, "start_commit")

    assert commit == String.trim(head)

    # SUBTASK-7
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "running"}}
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "done"}}

    # SUBTASK-15, STORE-18: the parent's call is recorded for the UI.
    assert %{parent_call_id: "s1"} = Store.load_task(child)
    assert [%{id: ^child, parent_call_id: "s1"}] = Store.children(parent)

    # SUBTASK-5, 13: saved metadata, with the final status and the result.
    assert %{
             parent_id: ^parent,
             title: "Add file",
             brief: "Create child.txt and commit it.",
             status: "done",
             start_commit: start_commit,
             result: %{"status" => "done"}
           } = Store.load_task(child)

    assert byte_size(start_commit) == 40

    # STORE-17: listed like a chat, under the task title.
    assert %{title: "Add file", parent_id: ^parent, task_status: "done"} =
             Enum.find(Store.list(1000), &(&1.id == child))

    # SUBTASK-6: the child inherited the parent's auto-approved tools.
    assert Agent.snapshot(child).auto_approve == ["shell"]

    # APPR-12: the copy is the child's own; changing the parent doesn't touch it.
    :ok = Agent.set_auto_approve(parent, "shell", false)
    assert Agent.snapshot(parent).auto_approve == []
    assert Agent.snapshot(child).auto_approve == ["shell"]
  end

  # PROJ-10
  test "a sub-task chat carries its parent's project", %{parent: _parent} do
    dir = Path.join(System.tmp_dir!(), "elia-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    project = %{id: Agent.new_id(), name: "Other", folder: dir, harness?: false}

    parent = Agent.new_id()

    {:ok, _pid} =
      Agent.ensure_started(parent, loop_opts: [llm: %{provider: FakeLLM}], project: project)

    Agent.subscribe(parent)
    on_exit(fn -> stop_session(parent) end)

    test_pid = self()

    FakeLLM.push(FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B"})]))

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:child, Tasks.active().child_id})
      reply([finish_call("done", "ok")])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    run_spawn(parent)

    assert_receive {:child, child}
    assert Agent.snapshot(child).project == project
    assert Store.load_project(child) == project.id
    stop_session(child)
  end

  # SUBTASK-10
  test "a child that ends without finish_task is unfinished", %{parent: parent} do
    FakeLLM.push(FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B"})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("I looked around but never reported.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Hm.")]))

    run_spawn(parent)

    {content, false} = last_tool_result()

    assert %{
             "status" => "unfinished",
             "summary" => "I looked around but never reported.",
             "commit" => nil,
             "files" => [],
             "questions" => [],
             "reason" => nil,
             "tree_clean" => true,
             "start_commit" => start
           } = Jason.decode!(content)

    # SUBTASK-21
    assert byte_size(start) == 40

    assert [%{task_status: "unfinished"}] = children_of(parent)
  end

  # SUBTASK-12, SUBTASK-24, SESS-27
  test "a child that hits its step limit pauses, and a resume starts the count over", %{
    parent: parent
  } do
    Agent.subscribe_activity()

    FakeLLM.push(
      FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B", "max_steps" => 1})])
    )

    # The child's step 1 records a result; step 2 is over the limit, so it
    # pauses instead of ending.
    FakeLLM.push(FakeLLM.assistant([finish_call("done", "All good")]))
    # After the resume the count starts over, so one more step ends the turn.
    FakeLLM.push(FakeLLM.assistant([Message.text("Carrying on.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Hm.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :paused}, 20_000

    assert Agent.snapshot(child).pause == "Step limit reached (1 steps)."

    # The lock is still held and spawn_task keeps waiting, with no deadline.
    assert Tasks.active().child_id == child
    assert Agent.snapshot(parent).status == :running

    :ok = Agent.resume(child)
    await_status(parent, :idle)

    {content, false} = last_tool_result()

    assert %{
             "status" => "done",
             "summary" => "All good",
             "reason" => nil,
             "task_id" => ^child
           } = Jason.decode!(content)

    assert Tasks.active() == nil
    assert [%{task_status: "done"}] = children_of(parent)
  end

  # SUBTASK-24, SUBTASK-16
  test "stopping a paused child cancels it", %{parent: parent} do
    Agent.subscribe_activity()

    FakeLLM.push(
      FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B", "max_steps" => 1})])
    )

    FakeLLM.push(FakeLLM.assistant([finish_call("done", "Fine")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :paused}, 20_000

    :ok = Agent.stop(child)
    await_status(parent, :idle)

    {content, false} = last_tool_result()
    assert %{"status" => "cancelled", "reason" => "cancelled"} = Jason.decode!(content)
    assert Tasks.active() == nil
  end

  # SUBTASK-8, 13
  test "a child whose session dies has failed", %{parent: parent} do
    test_pid = self()

    FakeLLM.push(FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B"})]))

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:child_blocked, self(), Tasks.active().child_id})
      receive do: (:never -> :ok)
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hm.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:child_blocked, loop, child}, 20_000
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, child)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    await_status(parent, :idle)
    Process.exit(loop, :kill)

    {content, false} = last_tool_result()

    assert %{
             "status" => "failed",
             "reason" => "crashed",
             "summary" => "The sub-task session stopped" <> _
           } = Jason.decode!(content)

    assert Tasks.active() == nil
    assert %{status: "failed"} = Store.load_task(child)
  end

  # SUBTASK-4
  test "a second child can't start while one is active", %{parent: parent} do
    test_pid = self()
    other = new_session()

    FakeLLM.push(FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B"})]))

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:child_blocked, self(), Tasks.active()})
      receive do: (:go -> reply([finish_call("done", "Fine")]))
    end)

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    assert_receive {:child_blocked, loop, %{child_id: child, parent_id: ^parent}}, 20_000

    FakeLLM.push(FakeLLM.assistant([spawn_call(%{"title" => "T2", "brief" => "B2"})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))
    :ok = Agent.send_message(other, "me too")
    await_status(other, :awaiting_approval)
    :ok = Agent.approve(other, "s1")
    await_status(other, :idle)

    request = List.last(parent_requests())

    assert %Message{content: [%{is_error: true, content: "Not started: sub-task " <> rest}]} =
             List.last(request.messages)

    assert rest =~ child
    assert Tasks.active().child_id == child
    assert children_of(other) == []

    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))
    send(loop, :go)
    await_status(parent, :idle)
    assert Tasks.active() == nil
  end

  # SUBTASK-4
  test "spawn_task is refused when the git tree is dirty", %{parent: parent} do
    File.write!(Path.join(Elia.Workspace.root(), "dirty.txt"), "x")

    assert {content, true} = refused_spawn(parent)
    assert content =~ "isn't clean"
    assert content =~ "dirty.txt"
    assert children_of(parent) == []
    assert Tasks.active() == nil
  end

  # SUBTASK-4
  test "spawn_task is refused when .elia/ is not git-ignored", %{parent: parent} do
    File.rm!(Path.join(Elia.Workspace.root(), ".gitignore"))

    assert {content, true} = refused_spawn(parent)
    assert content =~ "not git-ignored"
    assert children_of(parent) == []
  end

  # SUBTASK-2, 4
  test "spawn_task needs a title and a brief", %{parent: parent} do
    assert {"title must not be blank", true} =
             refused_spawn(parent, %{"title" => " ", "brief" => "B"})

    assert {"brief must not be blank", true} =
             refused_spawn(parent, %{"title" => "T", "brief" => ""})
  end

  # SUBTASK-4
  test "spawn_task is refused when the parent's own Elixir changes fail the tests", %{
    parent: parent
  } do
    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{"path" => "lib/broken.ex", "content" => "oops"})
      ])
    )

    FakeLLM.push(fn _request, _on_event ->
      commit_all("parent work")
      reply([spawn_call(%{"title" => "T", "brief" => "B"})])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Can't spawn.")]))
    # After the end-of-turn verification rolls the turn back (VERIFY-4).
    FakeLLM.push(FakeLLM.assistant([Message.text("Rolled back.")]))

    :ok = Agent.send_message(parent, "add a module and delegate")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "w1")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    [_, _, third, _] = parent_requests()
    assert %Message{content: [%{is_error: true, content: content}]} = List.last(third.messages)
    assert content =~ "fail the tests"
    assert children_of(parent) == []
    assert Tasks.active() == nil
  end

  # SUBTASK-14
  test "the parent's turn checkpoint moves past the child's work", %{parent: parent} do
    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{"path" => "skills/note.txt", "content" => "hi"})
      ])
    )

    FakeLLM.push(fn _request, _on_event ->
      commit_all("parent work")
      reply([spawn_call(%{"title" => "T", "brief" => "B"})])
    end)

    FakeLLM.push(fn _request, _on_event ->
      commit_file("child.txt")
      reply([finish_call("done", "Made it")])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(parent, "write a note and delegate")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    assert Enum.any?(
             Checkpoint.list(100),
             &(String.contains?(&1.label, parent) and
                 String.ends_with?(&1.label, "(after sub-task)"))
           )
  end

  # CKPT-10
  test "rebase replaces a turn's checkpoint and leaves other turns alone" do
    :ok = Checkpoint.ensure("rebase-turn")
    before = Checkpoint.for_turn("rebase-turn")
    File.write!(Path.join(Elia.Workspace.root(), "rebase.txt"), "x")
    assert {:ok, files} = Checkpoint.changed_files(before)
    assert Enum.any?(files, &String.ends_with?(&1, "rebase.txt"))

    assert :ok = Checkpoint.rebase("rebase-turn")
    rebased = Checkpoint.for_turn("rebase-turn")
    assert rebased != before
    assert {:ok, files} = Checkpoint.changed_files(rebased)
    refute Enum.any?(files, &String.ends_with?(&1, "rebase.txt"))

    assert :ok = Checkpoint.rebase("turn-without-checkpoint")
    assert Checkpoint.for_turn("turn-without-checkpoint") == nil
    assert :ok = Checkpoint.rebase(nil)
  end

  # VERIFY-7
  test "core_elixir_changed? looks at Elixir files since the turn's checkpoint" do
    root = Elia.Workspace.root()
    assert Elia.Harness.core_elixir_changed?("turn-without-checkpoint") == false

    :ok = Checkpoint.ensure("verify-turn")
    assert Elia.Harness.core_elixir_changed?("verify-turn") == false

    File.mkdir_p!(Path.join(root, "skills"))
    File.write!(Path.join(root, "skills/note.txt"), "x")
    assert Elia.Harness.core_elixir_changed?("verify-turn") == false

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/broken.ex"), "oops")
    assert Elia.Harness.core_elixir_changed?("verify-turn") == true
  end

  # Runs the parent into a spawn_task call whose child blocks in its first model
  # call. Returns the child's id once it is running.
  defp spawn_blocked_child(parent, input \\ %{}) do
    test_pid = self()
    input = Map.merge(%{"title" => "T", "brief" => "B"}, input)

    FakeLLM.push(FakeLLM.assistant([spawn_call(input)]))

    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:child_blocked, Tasks.active()})
      receive do: (:never -> :ok)
    end)

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    assert_receive {:child_blocked, %{child_id: child}}, 20_000
    child
  end

  # SUBTASK-16
  test "stopping the child cancels it and the parent gets that as a result", %{parent: parent} do
    child = spawn_blocked_child(parent)
    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))

    :ok = Agent.stop(child)
    await_status(parent, :idle)

    {content, false} = last_tool_result()

    assert %{"status" => "cancelled", "reason" => "cancelled", "task_id" => ^child} =
             Jason.decode!(content)

    assert Tasks.active() == nil
    assert %{status: "cancelled"} = Store.load_task(child)
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "cancelled"}}
  end

  # SUBTASK-17, SESS-22
  test "stopping the parent stops and cancels its child", %{parent: parent} do
    child = spawn_blocked_child(parent)

    :ok = Agent.stop(parent)
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "cancelled"}}, 20_000

    assert Tasks.active() == nil
    assert %{status: "cancelled", result: %{"reason" => "cancelled"}} = Store.load_task(child)
    assert Agent.snapshot(child).status == :idle

    assert %Message{role: :tool, content: [%{content: "Cancelled by the user.", is_error: true}]} =
             List.last(Agent.snapshot(parent).messages)
  end

  # SUBTASK-19
  test "when the process running spawn_task dies, the lock finishes the job", %{parent: parent} do
    child = spawn_blocked_child(parent)

    Process.exit(:sys.get_state(Tasks).active.owner, :kill)
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "failed"}}, 20_000
    await_status(parent, :idle)

    assert Tasks.active() == nil
    assert Agent.snapshot(child).status == :idle
    assert %{status: "failed", result: %{"reason" => "crashed"}} = Store.load_task(child)
  end

  # SUBTASK-18, SUBTASK-24, SESS-27
  test "a child that runs out of time pauses, and failing it reports the limit", %{
    parent: parent
  } do
    Agent.subscribe_activity()

    FakeLLM.push(
      FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B", "max_minutes" => 0.01})])
    )

    # The child's step 1 takes longer than the whole budget (600 ms), so step 2
    # pauses instead of ending.
    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(700)
      reply([finish_call("done", "fine")])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :paused}, 20_000
    assert Tasks.active().child_id == child

    # Fail: the turn ends with the limit's error, so the result is failed/budget.
    :ok = Agent.fail_task(child)
    await_status(parent, :idle)

    {content, false} = last_tool_result()

    assert %{
             "status" => "failed",
             "reason" => "budget",
             "summary" => "Stopped after " <> _,
             "task_id" => ^child
           } = Jason.decode!(content)

    assert Tasks.active() == nil
    assert Agent.snapshot(child).status == :idle
    assert %{status: "failed"} = Store.load_task(child)
  end

  # SUBTASK-18
  test "time spent waiting for approval doesn't count against the budget", %{parent: parent} do
    Agent.subscribe_activity()

    FakeLLM.push(
      FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B", "max_minutes" => 0.02})])
    )

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "true"})]))

    FakeLLM.push(FakeLLM.assistant([finish_call("done", "Fine")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :awaiting_approval}, 20_000

    # Longer than the whole budget (1.2 s).
    refute_receive {:agent, ^parent, {:subtask, "s1", ^child, _}}, 1_800

    :ok = Agent.approve(child, "c1")
    await_status(parent, :idle)

    {content, false} = last_tool_result()
    assert %{"status" => "done", "reason" => nil} = Jason.decode!(content)
  end

  # SUBTASK-21, SUBTASK-22
  test "a blocked child reports the tree state and the parent can reset the workspace", %{
    parent: parent
  } do
    test_pid = self()
    {start, 0} = git(["rev-parse", "HEAD"])
    start = String.trim(start)

    FakeLLM.push(FakeLLM.assistant([spawn_call(%{"title" => "T", "brief" => "B"})]))

    FakeLLM.push(fn _request, _on_event ->
      commit_file("child.txt")
      File.write!(Path.join(Elia.Workspace.root(), "dirty.txt"), "wip")
      reply([finish_call("blocked", "Stuck", ["Which one?"])])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))

    FakeLLM.push(fn request, _on_event ->
      %Message{role: :tool, content: [%{content: content}]} = List.last(request.messages)
      send(test_pid, {:result, Jason.decode!(content)})

      reply([
        FakeLLM.tool_call("r1", "reset_task", %{"task_id" => Jason.decode!(content)["task_id"]})
      ])
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Reset.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :awaiting_approval)

    # Not automatic: the reset waits for approval, and nothing changed yet.
    assert File.exists?(Path.join(Elia.Workspace.root(), "dirty.txt"))

    assert_receive {:result,
                    %{
                      "status" => "blocked",
                      "reason" => nil,
                      "tree_clean" => false,
                      "start_commit" => ^start,
                      "files" => files
                    }}

    assert files == ["child.txt", "dirty.txt"]

    :ok = Agent.approve(parent, "r1")
    await_status(parent, :idle)

    root = Elia.Workspace.root()
    refute File.exists?(Path.join(root, "child.txt"))
    refute File.exists?(Path.join(root, "dirty.txt"))
    assert {head, 0} = git(["rev-parse", "HEAD"])
    assert String.trim(head) == start
    assert {"", 0} = git(["status", "--porcelain"])

    {content, false} = last_tool_result()
    assert content =~ "Workspace reset to #{String.slice(start, 0, 8)}"
    assert content =~ "child work"
  end

  # SUBTASK-22
  test "reset_task refuses what it shouldn't touch and resets an interrupted task", %{
    parent: parent
  } do
    root = Elia.Workspace.root()
    {start, 0} = git(["rev-parse", "HEAD"])
    start = String.trim(start)
    ctx = %{session_id: parent, turn_id: nil}

    save = fn changes ->
      id = Agent.new_id()

      task =
        Map.merge(
          %{parent_id: parent, title: "T", brief: "B", status: "failed", start_commit: start},
          changes
        )

      :ok = Store.save(id, [Message.user("x")], task: task)
      id
    end

    dirty = fn -> File.write!(Path.join(root, "dirty.txt"), "wip") end

    assert {:error, "Not reset: " <> _} = Tasks.reset_task(%{"task_id" => "nope"}, ctx)
    assert {:error, "Not reset: " <> _} = Tasks.reset_task(%{}, ctx)

    other = save.(%{parent_id: "someone-else"})
    assert {:error, "Not reset: " <> _} = Tasks.reset_task(%{"task_id" => other}, ctx)

    done = save.(%{status: "done"})

    assert {:error, "Not reset: that sub-task finished as done" <> _} =
             Tasks.reset_task(%{"task_id" => done}, ctx)

    no_start = save.(%{start_commit: nil})

    assert {:error, "Not reset: that sub-task has no start commit." <> _} =
             Tasks.reset_task(%{"task_id" => no_start}, ctx)

    # A child is active.
    failed = save.(%{})
    assert :ok = Tasks.acquire("p1", nil, "c1", nil)
    dirty.()

    assert {:error, "Not reset: sub-task c1 is still active." <> _} =
             Tasks.reset_task(%{"task_id" => failed}, ctx)

    assert File.exists?(Path.join(root, "dirty.txt"))
    assert :ok = Tasks.release("c1")

    # Saved as running with no live session: interrupted, so it can be reset.
    interrupted = save.(%{status: "running"})
    assert {:ok, "Workspace reset" <> _} = Tasks.reset_task(%{"task_id" => interrupted}, ctx)
    refute File.exists?(Path.join(root, "dirty.txt"))

    # The history was rewritten since the task started.
    {_, 0} = git(["commit", "-q", "--amend", "--allow-empty", "-m", "rewritten"])
    dirty.()

    assert {:error, "Not reset: the task's start commit is not an ancestor" <> _} =
             Tasks.reset_task(%{"task_id" => failed}, ctx)

    assert File.exists?(Path.join(root, "dirty.txt"))
  end

  # SUBTASK-3, 11
  test "the lock holds one child and is released when either session dies" do
    parent = spawn(fn -> receive do: (:stop -> :ok) end)
    child = spawn(fn -> receive do: (:stop -> :ok) end)

    # SUBTASK-3: nobody is waiting for a result yet.
    assert {:error, "This chat is not an active sub-task" <> _} =
             Tasks.finish("c1", %{"status" => "done", "summary" => "x"})

    assert :ok = Tasks.acquire("p1", parent, "c1", child)
    assert %{child_id: "c1", parent_id: "p1"} = Tasks.active()
    assert Tasks.running?("c1")
    assert :busy = Tasks.acquire("p2", nil, "c2", nil)

    # SUBTASK-3: validation, then recording (and replacing) a result.
    assert {:error, "status must be" <> _} =
             Tasks.finish("c1", %{"status" => "great", "summary" => "x"})

    assert {:error, "summary must not be blank"} =
             Tasks.finish("c1", %{"status" => "done", "summary" => " "})

    assert {:error, "questions must be" <> _} =
             Tasks.finish("c1", %{"status" => "done", "summary" => "x", "questions" => [1]})

    assert :ok = Tasks.finish("c1", %{"status" => "failed", "summary" => "x"})
    assert :ok = Tasks.finish("c1", %{"status" => "done", "summary" => "y"})
    assert :ok = Tasks.release("c1")
    assert Tasks.active() == nil

    for dying <- [:parent, :child] do
      parent = spawn(fn -> receive do: (:stop -> :ok) end)
      child = spawn(fn -> receive do: (:stop -> :ok) end)
      assert :ok = Tasks.acquire("p1", parent, "c1", child)

      pid = if dying == :parent, do: parent, else: child
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      _ = :sys.get_state(Tasks)
      assert Tasks.active() == nil

      send(if(dying == :parent, do: child, else: parent), :stop)
    end
  end
end
