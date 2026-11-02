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

      for file <- ~w(.gitignore child.txt dirty.txt note.txt skills/note.txt lib/broken.ex) do
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

  defp parent?(request), do: "spawn_task" in tool_names(request)

  defp after_tools?(request), do: match?(%Message{role: :tool}, List.last(request.messages))

  # The tool results a history holds, oldest first, as {tool name, content, is_error}.
  defp results(%{messages: messages}) do
    names =
      for %Message{role: :assistant} = message <- messages,
          call <- Message.tool_calls(message),
          into: %{},
          do: {call.id, call.name}

    for %Message{role: :tool} = message <- messages,
        result <- message.content,
        do: {names[result.tool_call_id], result.content, result.is_error}
  end

  defp results(request, name), do: for({^name, content, false} <- results(request), do: content)

  defp counts(request, name),
    do: Enum.count(results(request), fn {tool, _content, _error} -> tool == name end)

  defp spawned(request),
    do: for(json <- results(request, "spawn_task"), do: Jason.decode!(json)["task_id"])

  # The tool results in a chat's own history, oldest first.
  defp session_results(id), do: results(%{messages: Agent.snapshot(id).messages})

  # The `index`-th result of `name` in the chat's history, decoded.
  defp session_json(id, name, index) do
    session_results(id)
    |> Enum.filter(fn {tool, _content, _error} -> tool == name end)
    |> Enum.at(index)
    |> case do
      nil -> nil
      {_tool, content, _error} -> Jason.decode!(content)
    end
  end

  # The chat's most recent tool result: {content, is_error}.
  defp session_result(id) do
    %Message{role: :tool, content: [%{content: content, is_error: error?}]} =
      Agent.snapshot(id).messages |> Enum.reverse() |> Enum.find(&(&1.role == :tool))

    {content, error?}
  end

  defp active_child do
    [%{child_id: child}] = Tasks.active()
    child
  end

  defp children_of(parent),
    do: Enum.filter(Store.list(1000), &(Map.get(&1, :parent_id) == parent))

  # Queues the same turn `times` times. A parent and its children run at the
  # same time and share FakeLLM's single queue, so every turn decides from the
  # request which chat it is answering.
  defp push_turns(turn, times \\ 12), do: for(_ <- 1..times, do: FakeLLM.push(turn))

  defp router(parent_turn, child_turn) do
    fn request, _on_event ->
      if parent?(request), do: parent_turn.(request), else: child_turn.(request)
    end
  end

  # The parent's turns for a test that starts one sub-task and waits for it.
  defp spawn_and_await(request, input) do
    cond do
      counts(request, "spawn_task") == 0 ->
        reply([spawn_call(input)])

      spawned(request) != [] and results(request, "await_task") == [] ->
        reply([
          FakeLLM.tool_call("a1", "await_task", %{"task_id" => List.first(spawned(request))})
        ])

      true ->
        reply([Message.text("Done.")])
    end
  end

  # A child that reports `done` at once.
  defp reporting_child(request) do
    if after_tools?(request),
      do: reply([Message.text("Done.")]),
      else: reply([finish_call("done", "Did it")])
  end

  # A child that blocks in its first model call until the test kills or stops it.
  defp blocked_child(test_pid) do
    fn _request ->
      send(test_pid, {:child_blocked, active_child(), self()})
      receive do: (:never -> reply([Message.text("Never.")]))
    end
  end

  # Runs the parent into a spawn whose child blocks in its first model call, so
  # the parent is waiting for it. Returns the child's id.
  defp spawn_blocked_child(parent, test_pid, input \\ %{}) do
    input = Map.merge(%{"title" => "T", "brief" => "B"}, input)
    push_turns(router(&spawn_and_await(&1, input), blocked_child(test_pid)))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    assert_receive {:child_blocked, child, _loop}, 20_000

    # The parent is now inside its `await_task` call (SUBTASK-27), which can only
    # end when the child does.
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "running"}}, 20_000
    assert_receive {:agent, ^parent, {:tool_status, "a1", :running}}, 20_000
    child
  end

  # Runs the parent through one turn, approving each call id in turn.
  defp run_parent(parent, call_ids, text \\ "go") do
    :ok = Agent.send_message(parent, text)

    for call_id <- call_ids do
      await_status(parent, :awaiting_approval)
      :ok = Agent.approve(parent, call_id)
    end

    await_status(parent, :idle)
  end

  defp refused_spawn(parent, input) do
    FakeLLM.push(FakeLLM.assistant([spawn_call(input)]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Noted.")]))
    run_parent(parent, ["s1"])
    session_result(parent)
  end

  # The `task_id` of the first `spawn_task` call in a request's history.
  defp task_id(request) do
    request |> results("spawn_task") |> List.first() |> Jason.decode!() |> Map.fetch!("task_id")
  end

  # The checkpoints this chat's turns took.
  defp checkpoints_of(parent) do
    for checkpoint <- Checkpoint.list(100),
        String.contains?(checkpoint.label, parent),
        do: checkpoint
  end

  ## Tools

  # SUBTASK-1
  test "a parent has the sub-task tools and a child has finish_task, never both" do
    parent = Enum.flat_map(Elia.Skills.current(), & &1.tools) |> Enum.map(& &1.name)
    child = Elia.Skills.Tasks.child_skills() |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name)

    assert "spawn_task" in parent
    assert "list_tasks" in parent
    assert "await_task" in parent
    assert "reset_task" in parent
    refute "finish_task" in parent

    assert "finish_task" in child
    refute "spawn_task" in child
    refute "list_tasks" in child
    refute "await_task" in child
    assert "shell" in child
  end

  # SUBTASK-2, 22, 26, 27
  test "spawn and reset need approval; listing and awaiting never do" do
    assert [
             %Elia.Tool{name: "spawn_task", approval: :required},
             %Elia.Tool{name: "list_tasks", approval: :never},
             %Elia.Tool{name: "await_task", approval: :never},
             %Elia.Tool{name: "reset_task", approval: :required}
           ] = Elia.Skills.Tasks.tools()
  end

  # SUBTASK-2, 4, 5, 6, 7, 8, 9, 11, 13, 15, 26, 27
  test "a parent starts a sub-task, goes on, and collects its result", %{parent: parent} do
    test_pid = self()
    default_model = Elia.Settings.get(:model)

    # SUBTASK-6: the parent's auto-approved tools are auto-approved in the child too.
    Agent.set_auto_approve(parent, "shell", true)

    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([
            spawn_call(%{
              "title" => "Add file",
              "brief" => "Create child.txt and commit it.",
              "model" => "other-model"
            })
          ])

        results(request, "list_tasks") == [] ->
          reply([FakeLLM.tool_call("l1", "list_tasks", %{})])

        results(request, "await_task") == [] ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => task_id(request)})])

        length(results(request, "await_task")) == 1 ->
          # SUBTASK-27: the task has finished, so this returns at once.
          reply([FakeLLM.tool_call("a2", "await_task", %{"task_id" => task_id(request)})])

        length(results(request, "list_tasks")) == 1 ->
          reply([FakeLLM.tool_call("l2", "list_tasks", %{"task_id" => task_id(request)})])

        true ->
          reply([Message.text("Done.")])
      end
    end

    child_turn = fn request ->
      if after_tools?(request) do
        reply([Message.text("Done.")])
      else
        child = active_child()
        send(test_pid, {:child_started, child, request, self()})
        commit_file("child.txt")

        # SUBTASK-4: a child can't start a child.
        send(
          test_pid,
          {:nested, Tasks.spawn_task(%{"title" => "t", "brief" => "b"}, %{session_id: child})}
        )

        receive do
          :finish -> reply([finish_call("done", "Made child.txt", ["Rename it?"])])
        end
      end
    end

    push_turns(router(parent_turn, child_turn))

    :ok = Agent.send_message(parent, "do it")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    # SUBTASK-2: the spawn returns while the child is still working, so the
    # parent goes on and asks how the child is doing.
    assert_receive {:child_started, child, request, loop}, 20_000

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

    send(loop, :finish)
    await_status(parent, :idle)

    # SUBTASK-26: while the child ran, the parent's list showed it running.
    assert [
             %{
               "task_id" => ^child,
               "title" => "Add file",
               "status" => "running",
               "reason" => nil,
               "started_at" => started_at
             }
           ] = session_json(parent, "list_tasks", 0)

    assert is_binary(started_at)

    {head, 0} = git(["rev-parse", "HEAD"])

    # SUBTASK-9: the harness fills in the commit and the changed files.
    assert %{
             "status" => "done",
             "summary" => "Made child.txt",
             "questions" => ["Rename it?"],
             "files" => ["child.txt"],
             "commit" => commit,
             "task_id" => ^child,
             "reason" => nil
           } = result = session_json(parent, "await_task", 0)

    # SUBTASK-21: a done task has no start commit or tree state.
    refute Map.has_key?(result, "tree_clean")
    refute Map.has_key?(result, "start_commit")

    assert commit == String.trim(head)

    # SUBTASK-27: a task that already finished returns at once, from its metadata.
    assert session_json(parent, "await_task", 1) == result

    # SUBTASK-26: the single-task form adds the result once it has finished.
    assert %{
             "task_id" => ^child,
             "title" => "Add file",
             "status" => "done",
             "reason" => nil,
             "result" => %{"status" => "done"}
           } = session_json(parent, "list_tasks", 1)

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

    # SUBTASK-11: nothing is left running.
    assert Tasks.active() == []
  end

  # SUBTASK-2, 7, 28
  test "spawn_task returns while the child is still running", %{parent: parent} do
    push_turns(
      router(
        fn request ->
          if counts(request, "spawn_task") == 0,
            do: reply([spawn_call(%{"title" => "T", "brief" => "B"})]),
            else: reply([Message.text("I'll check on it later.")])
        end,
        blocked_child(self())
      )
    )

    run_parent(parent, ["s1"])
    assert_receive {:child_blocked, child, _loop}, 20_000

    # SUBTASK-2: the parent's turn ended with the child still running, and its
    # spawn call returned the start, not a result.
    {content, false} = session_result(parent)

    assert %{"task_id" => ^child, "title" => "T", "status" => "running"} =
             Jason.decode!(content)

    assert Tasks.running?(child)
    assert [%{child_id: ^child, parent_id: ^parent}] = Tasks.active()

    # SUBTASK-7: the start was announced, the end has not happened.
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "running"}}
    refute_received {:agent, ^parent, {:subtask, "s1", ^child, _status}}

    :ok = Agent.stop(child)
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "cancelled"}}, 20_000
    assert Tasks.active() == []
  end

  # PROJ-10
  test "a sub-task chat carries its parent's project" do
    dir = Path.join(System.tmp_dir!(), "elia-task-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    project = %{id: Agent.new_id(), name: "Other", folder: dir, harness?: false}

    parent = Agent.new_id()

    {:ok, _pid} =
      Agent.ensure_started(parent, loop_opts: [llm: %{provider: FakeLLM}], project: project)

    Agent.subscribe(parent)
    on_exit(fn -> stop_session(parent) end)

    push_turns(
      router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &reporting_child/1)
    )

    run_parent(parent, ["s1"])

    child = session_json(parent, "spawn_task", 0)["task_id"]

    assert Agent.snapshot(child).project == project
    assert Store.load_project(child) == project.id
    stop_session(child)
  end

  # SUBTASK-10
  test "a child that ends without finish_task is unfinished", %{parent: parent} do
    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B"}),
        fn _request -> reply([Message.text("I looked around but never reported.")]) end
      )
    )

    run_parent(parent, ["s1"])

    assert %{
             "status" => "unfinished",
             "summary" => "I looked around but never reported.",
             "commit" => nil,
             "files" => [],
             "questions" => [],
             "reason" => nil,
             "tree_clean" => true,
             "start_commit" => start
           } = session_json(parent, "await_task", 0)

    # SUBTASK-21
    assert byte_size(start) == 40

    assert [%{task_status: "unfinished"}] = children_of(parent)
  end

  # SUBTASK-12, SUBTASK-24, SESS-27
  test "a child that hits its step limit pauses, and a resume starts the count over", %{
    parent: parent
  } do
    Agent.subscribe_activity()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_steps" => 1}),
        fn request ->
          # Step 1 records a result; step 2 is over the limit, so it pauses.
          if after_tools?(request),
            do: reply([Message.text("Carrying on.")]),
            else: reply([finish_call("done", "All good")])
        end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :paused}, 20_000

    assert Agent.snapshot(child).pause == "Step limit reached (1 steps)."

    # SUBTASK-24: the entry is still held and the parent is still waiting, with
    # no deadline of its own.
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    assert Agent.snapshot(parent).status == :running

    :ok = Agent.resume(child)
    await_status(parent, :idle)

    assert %{
             "status" => "done",
             "summary" => "All good",
             "reason" => nil,
             "task_id" => ^child
           } = session_json(parent, "await_task", 0)

    assert Tasks.active() == []
    assert [%{task_status: "done"}] = children_of(parent)
  end

  # SUBTASK-24, SUBTASK-16
  test "stopping a paused child cancels it", %{parent: parent} do
    Agent.subscribe_activity()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_steps" => 1}),
        fn _request -> reply([finish_call("done", "Fine")]) end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :paused}, 20_000

    :ok = Agent.stop(child)
    await_status(parent, :idle)

    assert %{"status" => "cancelled", "reason" => "cancelled"} =
             session_json(parent, "await_task", 0)

    assert Tasks.active() == []
  end

  # SUBTASK-8, 13
  test "a child whose session dies has failed", %{parent: parent} do
    test_pid = self()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B"}),
        fn request ->
          if after_tools?(request) do
            reply([Message.text("Hm.")])
          else
            send(test_pid, {:child_blocked, self(), active_child()})
            receive do: (:never -> :ok)
          end
        end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:child_blocked, loop, child}, 20_000
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, child)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    Process.exit(loop, :kill)
    await_status(parent, :idle)

    assert %{
             "status" => "failed",
             "reason" => "crashed",
             "summary" => "The sub-task session stopped" <> _
           } = session_json(parent, "await_task", 0)

    assert Tasks.active() == []
    assert %{status: "failed"} = Store.load_task(child)
  end

  # SUBTASK-4, 11
  test "a second child in the same workspace is refused", %{parent: parent} do
    other = new_session()
    child = spawn_blocked_child(parent, self())

    # The child shares the parent's workspace (Elia's own project without a
    # worktree), so another chat spawning into it would put two writers in one
    # tree.
    :ok = Agent.send_message(other, "me too")
    await_status(other, :awaiting_approval)
    :ok = Agent.approve(other, "s1")
    await_status(other, :idle)

    {content, true} = session_result(other)
    assert content =~ "is already writing in that workspace"
    assert content =~ child

    # Nothing was created for it (SUBTASK-4) and the running child is untouched.
    assert children_of(other) == []
    assert [%{child_id: ^child, parent_id: ^parent}] = Tasks.active()

    :ok = Agent.stop(child)
    await_status(parent, :idle)
    assert Tasks.active() == []
  end

  # SUBTASK-4
  test "spawn_task is not refused when the tree is dirty or unverified", %{parent: parent} do
    root = Elia.Workspace.root()
    File.write!(Path.join(root, "dirty.txt"), "x")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/broken.ex"), "oops")

    push_turns(
      router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &reporting_child/1)
    )

    run_parent(parent, ["s1"])

    assert %{"status" => "done"} = session_json(parent, "await_task", 0)
    assert [%{task_status: "done"}] = children_of(parent)
  end

  # SUBTASK-2, 4
  test "spawn_task needs a title and a brief", %{parent: parent} do
    assert {"title must not be blank", true} =
             refused_spawn(parent, %{"title" => " ", "brief" => "B"})

    assert {"brief must not be blank", true} =
             refused_spawn(parent, %{"title" => "T", "brief" => ""})

    assert children_of(parent) == []
    assert Tasks.active() == []
  end

  # SUBTASK-2, SUBTASK-14 (retired)
  test "a spawn leaves the parent's turn checkpoint alone", %{parent: parent} do
    parent_turn = fn request ->
      if results(request, "write_file") == [] do
        reply([
          FakeLLM.tool_call("w1", "write_file", %{"path" => "skills/note.txt", "content" => "hi"})
        ])
      else
        spawn_and_await(request, %{"title" => "T", "brief" => "B"})
      end
    end

    push_turns(router(parent_turn, &reporting_child/1))

    :ok = Agent.send_message(parent, "write a note and delegate")
    await_status(parent, :awaiting_approval)
    before = checkpoints_of(parent)
    assert before != []

    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    # SUBTASK-14 is retired: the child leaves the parent's workspace alone
    # (SUBTASK-23), so the parent's checkpoint is simply left where it is.
    assert checkpoints_of(parent) == before
    refute Enum.any?(before, &String.contains?(&1.label, "(after sub-task)"))
  end

  # CKPT-10
  test "rebase replaces a turn's checkpoint and leaves other turns alone" do
    :ok = Checkpoint.ensure("rebase-turn")
    before = Checkpoint.for_turn("rebase-turn")
    File.write!(Path.join(Elia.Workspace.root(), "note.txt"), "x")
    assert {:ok, files} = Checkpoint.changed_files(before)
    assert Enum.any?(files, &String.ends_with?(&1, "note.txt"))

    assert :ok = Checkpoint.rebase("rebase-turn")
    rebased = Checkpoint.for_turn("rebase-turn")
    assert rebased != before
    assert {:ok, files} = Checkpoint.changed_files(rebased)
    refute Enum.any?(files, &String.ends_with?(&1, "note.txt"))

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

  # SUBTASK-16
  test "stopping the child cancels it and the parent gets that as a result", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    :ok = Agent.stop(child)
    await_status(parent, :idle)

    {content, false} = session_result(parent)

    assert %{"status" => "cancelled", "reason" => "cancelled", "task_id" => ^child} =
             Jason.decode!(content)

    assert Tasks.active() == []
    assert %{status: "cancelled"} = Store.load_task(child)
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "cancelled"}}
  end

  # SUBTASK-17, SESS-22
  test "stopping the parent stops and cancels its child", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    :ok = Agent.stop(parent)
    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "cancelled"}}, 20_000

    assert Tasks.active() == []
    assert %{status: "cancelled", result: %{"reason" => "cancelled"}} = Store.load_task(child)
    assert Agent.snapshot(child).status == :idle

    assert %Message{role: :tool, content: [%{content: "Cancelled by the user.", is_error: true}]} =
             List.last(Agent.snapshot(parent).messages)
  end

  # SUBTASK-19, SUBTASK-28
  test "when a child's watcher dies, the registry finishes the job", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    watcher = :sys.get_state(Tasks).active[child].owner
    Process.exit(watcher, :kill)

    assert_receive {:agent, ^parent, {:subtask, "s1", ^child, "failed"}}, 20_000
    await_status(parent, :idle)

    assert Tasks.active() == []
    assert Agent.snapshot(child).status == :idle
    assert %{status: "failed", result: %{"reason" => "crashed"}} = Store.load_task(child)
  end

  # SUBTASK-18, SUBTASK-24, SESS-27
  test "a child that runs out of time pauses, and failing it reports the limit", %{
    parent: parent
  } do
    Agent.subscribe_activity()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_minutes" => 0.01}),
        fn _request ->
          # Longer than the whole budget (600 ms), so the next step pauses.
          Process.sleep(700)
          reply([finish_call("done", "fine")])
        end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :paused}, 20_000
    assert Tasks.running?(child)

    # Fail: the turn ends with the limit's error, so the result is failed/budget.
    :ok = Agent.fail_task(child)
    await_status(parent, :idle)

    assert %{
             "status" => "failed",
             "reason" => "budget",
             "summary" => "Stopped after " <> _,
             "task_id" => ^child
           } = session_json(parent, "await_task", 0)

    assert Tasks.active() == []
    assert Agent.snapshot(child).status == :idle
    assert %{status: "failed"} = Store.load_task(child)
  end

  # SUBTASK-18
  test "time spent waiting for approval doesn't count against the budget", %{parent: parent} do
    Agent.subscribe_activity()

    child_turn = fn request ->
      case results(request) do
        [] -> reply([FakeLLM.tool_call("c1", "shell", %{"command" => "true"})])
        [{"shell", _, _}] -> reply([finish_call("done", "Fine")])
        _ -> reply([Message.text("Done.")])
      end
    end

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_minutes" => 0.02}),
        child_turn
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    assert_receive {:agent, ^parent, {:subtask, "s1", child, "running"}}, 20_000
    assert_receive {:chat_status, ^child, :awaiting_approval}, 20_000

    # Longer than the whole budget (1.2 s): the child is waiting for the user, so
    # its clock is stopped and nothing happens.
    refute_receive {:agent, ^parent, {:subtask, "s1", ^child, _status}}, 1_800

    :ok = Agent.approve(child, "c1")
    await_status(parent, :idle)

    assert %{"status" => "done", "reason" => nil} = session_json(parent, "await_task", 0)
  end

  # SUBTASK-21, SUBTASK-22
  test "a blocked child reports the tree state and the parent can reset the workspace", %{
    parent: parent
  } do
    {start, 0} = git(["rev-parse", "HEAD"])
    start = String.trim(start)

    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([spawn_call(%{"title" => "T", "brief" => "B"})])

        results(request, "await_task") == [] ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => task_id(request)})])

        results(request, "reset_task") == [] ->
          reply([FakeLLM.tool_call("r1", "reset_task", %{"task_id" => task_id(request)})])

        true ->
          reply([Message.text("Reset.")])
      end
    end

    child_turn = fn request ->
      if after_tools?(request) do
        reply([Message.text("Done.")])
      else
        commit_file("child.txt")
        File.write!(Path.join(Elia.Workspace.root(), "dirty.txt"), "wip")
        reply([finish_call("blocked", "Stuck", ["Which one?"])])
      end
    end

    push_turns(router(parent_turn, child_turn))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :awaiting_approval)

    # Not automatic: the reset waits for approval, and nothing changed yet.
    assert File.exists?(Path.join(Elia.Workspace.root(), "dirty.txt"))

    assert %{
             "status" => "blocked",
             "reason" => nil,
             "tree_clean" => false,
             "start_commit" => ^start,
             "files" => files
           } = session_json(parent, "await_task", 0)

    assert files == ["child.txt", "dirty.txt"]

    :ok = Agent.approve(parent, "r1")
    await_status(parent, :idle)

    root = Elia.Workspace.root()
    refute File.exists?(Path.join(root, "child.txt"))
    refute File.exists?(Path.join(root, "dirty.txt"))
    assert {head, 0} = git(["rev-parse", "HEAD"])
    assert String.trim(head) == start
    assert {"", 0} = git(["status", "--porcelain"])

    {content, false} = session_result(parent)
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

    failed = save.(%{})

    # SUBTASK-22: another child running in another workspace doesn't stop a reset
    # of this task.
    assert :ok = Tasks.acquire(parent, "another-child", "/other-workspace")
    dirty.()
    assert {:ok, "Workspace reset" <> _} = Tasks.reset_task(%{"task_id" => failed}, ctx)
    refute File.exists?(Path.join(root, "dirty.txt"))
    assert :ok = Tasks.release("another-child")

    # SUBTASK-22: the task being reset running does stop it.
    assert :ok = Tasks.acquire(parent, failed, "/other-workspace")
    dirty.()

    assert {:error, "Not reset: sub-task " <> _} =
             Tasks.reset_task(%{"task_id" => failed}, ctx)

    assert File.exists?(Path.join(root, "dirty.txt"))
    assert :ok = Tasks.release(failed)

    # Saved as running with no entry: interrupted, so it can be reset (SUBTASK-20).
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

  # SUBTASK-11
  test "the registry holds every running child, one writer per workspace" do
    assert Tasks.active() == []

    assert :ok = Tasks.acquire("p1", "c1", "/one")
    assert :ok = Tasks.acquire("p2", "c2", "/two")

    assert Enum.sort_by(Tasks.active(), & &1.child_id) == [
             %{child_id: "c1", parent_id: "p1"},
             %{child_id: "c2", parent_id: "p2"}
           ]

    assert Tasks.running?("c1")
    refute Tasks.running?("c3")
    assert Tasks.writing_in("/one") == "c1"
    assert Tasks.writing_in("/free") == nil

    # SUBTASK-4, SUBTASK-11: one writer per workspace.
    assert {:error, "Not started: sub-task c1 is already writing in that workspace."} =
             Tasks.acquire("p3", "c3", "/one")

    # Releasing one leaves the others alone.
    assert :ok = Tasks.release("c1")
    refute Tasks.running?("c1")
    assert Tasks.active() == [%{child_id: "c2", parent_id: "p2"}]

    # SUBTASK-16: stopping a child marks only that child.
    assert :ok = Tasks.note_stop("c1")
    assert :ok = Tasks.note_stop("c2")
    assert Tasks.take_state("c2") == %{finish: nil, cancelled: true}
    assert Tasks.take_state("c1") == nil

    # SUBTASK-17: stopping a parent marks each child it has running, which the
    # caller then stops.
    assert :ok = Tasks.acquire("p2", "c3", "/three")
    assert :ok = Tasks.note_stop("p2")
    assert Tasks.take_state("c2").cancelled
    assert Tasks.take_state("c3").cancelled

    assert :ok = Tasks.release("c2")
    assert :ok = Tasks.release("c3")
    assert Tasks.active() == []
  end

  # SUBTASK-3
  test "finish_task records a result only for a running child" do
    assert {:error, "This chat is not a running sub-task" <> _} =
             Tasks.finish("c1", %{"status" => "done", "summary" => "x"})

    assert :ok = Tasks.acquire("p1", "c1", "/one")

    assert {:error, "status must be" <> _} =
             Tasks.finish("c1", %{"status" => "great", "summary" => "x"})

    assert {:error, "summary must not be blank"} =
             Tasks.finish("c1", %{"status" => "done", "summary" => " "})

    assert {:error, "questions must be" <> _} =
             Tasks.finish("c1", %{"status" => "done", "summary" => "x", "questions" => [1]})

    # Calling it again replaces the earlier record.
    assert :ok = Tasks.finish("c1", %{"status" => "failed", "summary" => "x"})
    assert :ok = Tasks.finish("c1", %{"status" => "done", "summary" => "y"})
    assert %{finish: %{status: "done", summary: "y"}} = Tasks.take_state("c1")

    assert :ok = Tasks.release("c1")
    assert Tasks.active() == []
  end

  # SUBTASK-26, SUBTASK-27
  test "list_tasks and await_task only see this chat's own sub-tasks", %{parent: parent} do
    other = new_session()
    task = Agent.new_id()

    :ok =
      Store.save(task, [Message.user("x")],
        task: %{
          parent_id: parent,
          title: "T",
          brief: "B",
          started_at: DateTime.utc_now(),
          status: "done",
          start_commit: "abc",
          result: %{"status" => "done", "summary" => "S"}
        }
      )

    on_exit(fn -> stop_session(task) end)

    ctx = %{session_id: other, turn_id: nil}

    assert {:error, message} = Tasks.list_tasks(%{"task_id" => task}, ctx)
    assert message =~ "is not a sub-task"

    assert {:error, message} = Tasks.await_task(%{"task_id" => task}, ctx)
    assert message =~ "is not a sub-task"

    # SUBTASK-27: a finished task's result comes from its saved metadata.
    assert {:ok, json} =
             Tasks.await_task(%{"task_id" => task}, %{session_id: parent, turn_id: nil})

    assert %{"status" => "done", "summary" => "S"} = Jason.decode!(json)

    # SUBTASK-26: and the single-task form reports it with the result.
    assert {:ok, json} = Tasks.list_tasks(%{"task_id" => task}, %{session_id: parent})

    assert %{"task_id" => ^task, "status" => "done", "result" => %{"summary" => "S"}} =
             Jason.decode!(json)
  end
end
