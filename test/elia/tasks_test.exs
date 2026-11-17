defmodule Elia.TasksTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, FakeLLM, Store, Tasks}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  setup do
    root = Elia.Workspace.root()
    File.write!(Path.join(root, ".gitignore"), "/.elia/\n")
    commit_all("start")

    start_supervised!(FakeLLM)
    parent = new_session()

    on_exit(fn ->
      # The registry is this node's, not this test's (SUBTASK-11): whatever a
      # failing test left held is released, so one test's failure isn't the next
      # one's.
      for %{child_id: id} <- Tasks.active(), do: Tasks.release(id)

      for entry <- Store.list(1000), Map.get(entry, :parent_id) == parent do
        stop_session(entry.id)
        Store.delete(entry.id)
      end

      for file <-
            ~w(.gitignore child.txt child_note.txt dirty.txt note.txt skills/note.txt lib/broken.ex) do
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

    # APPR-14: a new chat auto-approves every tool, so this parent starts with
    # an empty set — what these tests exercise is the approval flow, and a child
    # copies its parent's set (SUBTASK-6).
    {:ok, _pid} =
      Agent.ensure_started(id, loop_opts: [llm: %{provider: FakeLLM}], auto_approve: [])

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

  # git in a folder that is not Elia's tree: the folder of another project.
  defp git_in(dir, args) do
    System.cmd("git", ["-c", "user.name=T", "-c", "user.email=t@example.com" | args],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  # A project folder outside Elia's tree: a git repository with one commit.
  defp external_repo do
    dir = Path.join(System.tmp_dir!(), "elia-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {_, 0} = git_in(dir, ["init", "--quiet"])
    File.write!(Path.join(dir, "marker.txt"), "the project\n")
    {_, 0} = git_in(dir, ["add", "-A"])
    {_, 0} = git_in(dir, ["commit", "-q", "-m", "the project"])
    dir
  end

  defp head_of(dir) do
    {head, 0} = git_in(dir, ["rev-parse", "HEAD"])
    String.trim(head)
  end

  # A chat in a project outside Elia's own, which works in that project's folder
  # (PROJ-12). Its children are stopped with it.
  defp external_parent(dir, opts \\ []) do
    id = Agent.new_id()
    project = %{id: Agent.new_id(), name: "Other", folder: dir, harness?: false}

    opts =
      Keyword.merge(
        [project: project, loop_opts: [llm: %{provider: FakeLLM}], auto_approve: []],
        opts
      )

    {:ok, _pid} = Agent.ensure_started(id, opts)
    Agent.subscribe(id)

    on_exit(fn ->
      for %{id: child} <- children_of(id), do: stop_session(child)
      stop_session(id)
    end)

    {id, project}
  end

  # The workspace a chat's session runs its turns in (PROJ-12): the snapshot
  # doesn't carry it, so read the state.
  defp session_workspace(id) do
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, id)
    :sys.get_state(pid).workspace
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 20_000)

  # Waits until the chat is idle, for a test that subscribes after the turn may
  # already have ended.
  defp await_idle(id, tries \\ 1000)

  defp await_idle(_id, 0), do: flunk("the chat never went idle")

  defp await_idle(id, tries) do
    if Agent.snapshot(id).status == :idle do
      :ok
    else
      Process.sleep(20)
      await_idle(id, tries - 1)
    end
  end

  # Waits until the task's entry is released, which is what its end means
  # (SUBTASK-11, SUBTASK-13).
  defp await_released(child, tries \\ 500)

  defp await_released(child, 0), do: flunk("the task of #{child} was never released")

  defp await_released(child, tries) do
    if Tasks.running?(child) do
      Process.sleep(20)
      await_released(child, tries - 1)
    else
      :ok
    end
  end

  # The child whose entry is held (SUBTASK-11).
  defp await_child_started(tries \\ 500)

  defp await_child_started(0), do: flunk("no child started")

  defp await_child_started(tries) do
    case Tasks.active() do
      [%{child_id: child}] ->
        child

      _none ->
        Process.sleep(20)
        await_child_started(tries - 1)
    end
  end

  defp await_chat_status(id, status),
    do: assert_receive({:chat_status, ^id, ^status}, 20_000)

  defp reply(blocks, stop \\ nil) do
    message = FakeLLM.assistant(blocks)
    stop = stop || if Message.tool_calls(message) == [], do: :end_turn, else: :tool_use
    {:ok, %{message: message, stop_reason: stop, model: "fake", usage: %{}}}
  end

  defp spawn_call(input, id \\ "s1"), do: FakeLLM.tool_call(id, "spawn_task", input)

  # SUBTASK-33, DONE-6: the child's last act. The turn runs on after it, so the
  # result's summary is the text the child said with it.
  defp done_call(id \\ "d1"), do: FakeLLM.tool_call(id, "mark_done", %{})

  defp tool_names(request), do: Enum.map(request.tools, & &1.name)

  defp parent?(request), do: "spawn_task" in tool_names(request)

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

  # The `index`-th result of `name` in the chat's history, decoded. LOOP-24: the
  # loop appends a notice of its own after the result of a call that has
  # returned the identical result before, so the JSON is what comes before it.
  defp session_json(id, name, index) do
    session_results(id)
    |> Enum.filter(fn {tool, _content, _error} -> tool == name end)
    |> Enum.at(index)
    |> case do
      nil -> nil
      {_tool, content, _error} -> content |> before_notice() |> Jason.decode!()
    end
  end

  # LOOP-24: the result as the tool returned it, without the notice the loop may
  # have appended to it.
  defp before_notice(content), do: content |> String.split("\n\n[Elia harness]") |> hd()

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

  # SUBTASK-26: `list_tasks` for one task, called now rather than read out of a
  # recorded tool result.
  defp fresh_list(parent, child) do
    {:ok, json} = Tasks.list_tasks(%{"task_id" => child}, %{session_id: parent})
    Jason.decode!(json)
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

      spawned(request) != [] and counts(request, "await_task") == 0 ->
        reply([
          FakeLLM.tool_call("a1", "await_task", %{"task_id" => List.first(spawned(request))})
        ])

      true ->
        reply([Message.text("Done.")])
    end
  end

  # A child that says what it did and marks its chat done (SUBTASK-33).
  defp reporting_child(request) do
    if results(request, "mark_done") == [],
      do: reply([Message.text("Did it"), done_call()]),
      else: reply([Message.text("Done.")])
  end

  # A child that writes a file in its own workspace, says so and marks its chat
  # done.
  defp writing_child(request) do
    cond do
      results(request, "write_file") == [] ->
        reply([
          FakeLLM.tool_call("w1", "write_file", %{"path" => "child_note.txt", "content" => "x\n"})
        ])

      results(request, "mark_done") == [] ->
        reply([Message.text("Wrote it"), done_call()])

      true ->
        reply([Message.text("Done.")])
    end
  end

  # A child that spends its one step on a tool that needs no approval, so its
  # next step meets its step limit and it pauses (SUBTASK-24).
  defp pausing_child(request) do
    if results(request, "list_chats") == [],
      do: reply([FakeLLM.tool_call("r1", "list_chats", %{})]),
      else: reply([Message.text("Reading the chats."), done_call()])
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

    # The parent is now inside its `await_task` call (SUBTASK-27), which waits
    # for the child's chat to be marked done, so nothing the child's turn does
    # moves it.
    assert_receive {:agent, ^parent, {:tool_status, "a1", :running}}, 20_000
    child
  end

  # SUBTASK-16: a turn the user stopped is not a child's end, so a child whose
  # turn was stopped ends when the user settles it. This runs another turn in it,
  # which says what it did without marking the chat done (SUBTASK-34).
  defp carry_on(child) do
    Agent.subscribe(child)
    :ok = Agent.send_message(child, "carry on")
    assert_receive {:child_blocked, ^child, loop}, 20_000
    send(loop, :never)
    await_status(child, :idle)
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

  ## Tools

  # SUBTASK-1
  test "a parent has the sub-task tools and a child has exactly an ordinary chat's tools" do
    parent_skills = Elia.Skills.current()
    parent = parent_skills |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name)
    child_skills = Elia.Skills.for_child()
    child = child_skills |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name)

    assert "tasks" in Enum.map(parent_skills, & &1.name)
    assert "spawn_task" in parent
    assert "list_tasks" in parent
    assert "await_task" in parent

    # SUBTASK-1: a child's session is the ordinary registry minus the `tasks`
    # skill, so it has the tools any chat has — `mark_done` among them — and
    # none of the sub-task ones.
    refute "tasks" in Enum.map(child_skills, & &1.name)
    refute "spawn_task" in child
    refute "list_tasks" in child
    refute "await_task" in child
    assert "mark_done" in child
    assert "shell" in child

    # SUBTASK-1: and there is no child-only tool and no child-only skill.
    refute "finish_task" in (parent ++ child)
    refute Enum.any?(child_skills, &(&1.name in ["task", "tasks"]))
  end

  # SUBTASK-2, 26, 27
  test "spawn needs approval; listing and awaiting never do" do
    assert [
             %Elia.Tool{name: "spawn_task", approval: :required},
             %Elia.Tool{name: "list_tasks", approval: :never},
             %Elia.Tool{name: "await_task", approval: :never}
           ] = Elia.Skills.Tasks.tools()
  end

  # SUBTASK-2, SUBTASK-4, SUBTASK-5, SUBTASK-6, SUBTASK-9, SUBTASK-11,
  # SUBTASK-13, SUBTASK-15, SUBTASK-26, SUBTASK-27, SUBTASK-33
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

        counts(request, "list_tasks") == 0 ->
          reply([FakeLLM.tool_call("l1", "list_tasks", %{})])

        counts(request, "await_task") == 0 ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => task_id(request)})])

        counts(request, "await_task") == 1 ->
          # SUBTASK-27: the child's chat is marked done, so this returns at once.
          reply([FakeLLM.tool_call("a2", "await_task", %{"task_id" => task_id(request)})])

        counts(request, "list_tasks") == 1 ->
          reply([FakeLLM.tool_call("l2", "list_tasks", %{"task_id" => task_id(request)})])

        true ->
          reply([Message.text("Done.")])
      end
    end

    child_turn = fn request ->
      if results(request, "mark_done") != [] do
        reply([Message.text("Marked done.")])
      else
        child = active_child()
        send(test_pid, {:child_started, child, request, self()})
        commit_file("child.txt")

        # SUBTASK-1: a child can't start a child.
        send(
          test_pid,
          {:nested, Tasks.spawn_task(%{"title" => "t", "brief" => "b"}, %{session_id: child})}
        )

        receive do
          :finish -> reply([Message.text("Made child.txt"), done_call()])
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

    # SUBTASK-5: the child's first message is the preamble and the brief, and the
    # preamble says how the task ends.
    assert [%Message{role: :user} = brief | _] = request.messages
    assert Message.text_content(brief) =~ "sub-task agent"
    assert Message.text_content(brief) =~ "Create child.txt and commit it."
    assert Message.text_content(brief) =~ "mark_done"
    assert Message.text_content(brief) =~ "commit"

    # SUBTASK-1, SUBTASK-6: the child's own tools, and the model that was asked
    # for. It has `mark_done` and no sub-task tool, and no `tasks` skill.
    assert "mark_done" in tool_names(request)
    refute "spawn_task" in tool_names(request)
    refute "finish_task" in tool_names(request)
    assert request.system =~ "## Skill: done\n"
    refute request.system =~ "## Skill: tasks\n"
    assert request.model == "other-model"
    assert %{model: "other-model"} = Agent.snapshot(child).settings.model
    assert Elia.Settings.get(:model) == default_model

    # SUBTASK-1: a child can't start a child.
    assert_receive {:nested, {:error, "Not started: a sub-task can't start" <> _}}

    # SUBTASK-33: the child's own `mark_done` is the end.
    send(loop, :finish)
    await_status(parent, :idle)

    # SUBTASK-26, UI-59: while the child ran, the parent's list showed the status
    # its own chat had — `working`, as its row in the sidebar says.
    assert [
             %{
               "task_id" => ^child,
               "title" => "Add file",
               "status" => "working",
               "started_at" => started_at
             } = listed
           ] = session_json(parent, "list_tasks", 0)

    assert is_binary(started_at)
    # SUBTASK-9, SUBTASK-21 retired: no status, no reason.
    refute Map.has_key?(listed, "reason")

    {head, 0} = git(["rev-parse", "HEAD"])

    # SUBTASK-9: the harness fills in the commit and the changed files, and the
    # summary is the child's last words before it marked its chat done.
    assert %{
             "task_id" => ^child,
             "summary" => "Made child.txt",
             "commit" => commit,
             "files" => ["child.txt"]
           } = result = session_json(parent, "await_task", 0)

    assert Map.keys(result) |> Enum.sort() == ["commit", "files", "summary", "task_id"]
    assert commit == String.trim(head)

    # SUBTASK-27: a task whose chat is already marked done returns at once, from
    # its metadata. LOOP-24: the second `await_task` is the identical call for
    # the identical result, so the loop appended its own notice to it.
    assert session_json(parent, "await_task", 1) == result

    # SUBTASK-26: the single-task form adds the result once the chat is marked
    # done, and the status it reports is the child chat's own (UI-59, DONE-2).
    # The child's turn ran on after it marked the chat done (SUBTASK-33), so at
    # that moment its chat was `working` — its own status, as its row would show
    # — and it is `done` once the turn has ended.
    assert %{
             "task_id" => ^child,
             "title" => "Add file",
             "status" => status,
             "result" => %{"summary" => "Made child.txt"}
           } = _recorded = session_json(parent, "list_tasks", 1)

    assert status in ["working", "done"]

    await_idle(child)

    # Now that the child's turn has ended, the same call reports `done`: its chat
    # was marked done and it is idle, so done stands in place of idle (DONE-2).
    assert %{
             "task_id" => ^child,
             "status" => "done",
             "result" => %{"summary" => "Made child.txt"}
           } =
             fresh_list(parent, child)

    # SUBTASK-15, STORE-18: the parent's call is recorded for the UI.
    assert %{parent_call_id: "s1"} = Store.load_task(child)
    assert [%{id: ^child, parent_call_id: "s1"}] = Store.children(parent)

    # SUBTASK-5, SUBTASK-13: saved metadata and the result it ended with
    # (STORE-16: no status of its own).
    assert %{
             parent_id: ^parent,
             title: "Add file",
             brief: "Create child.txt and commit it.",
             start_commit: start_commit,
             result: %{"summary" => "Made child.txt"}
           } = task = Store.load_task(child)

    refute Map.has_key?(task, :status)
    assert byte_size(start_commit) == 40

    # STORE-17, UI-46, DONE-2: listed like a chat, under the task title, with the
    # status any chat has — its own.
    assert %{title: "Add file", parent_id: ^parent, done: true} =
             Enum.find(Store.list(1000), &(&1.id == child))

    refute Map.has_key?(Enum.find(Store.list(1000), &(&1.id == child)), :task_status)

    # SUBTASK-6: the child inherited the parent's auto-approved tools.
    assert Agent.snapshot(child).settings.auto_approve == ["shell"]

    # APPR-12: the copy is the child's own; changing the parent doesn't touch it.
    :ok = Agent.set_auto_approve(parent, "shell", false)
    assert Agent.snapshot(parent).settings.auto_approve == []
    assert Agent.snapshot(child).settings.auto_approve == ["shell"]

    # SUBTASK-11: nothing is left running.
    assert Tasks.active() == []
  end

  # SUBTASK-2, SUBTASK-11, SUBTASK-16, SUBTASK-26, SUBTASK-33, SUBTASK-34
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

    assert %{"task_id" => ^child, "title" => "T", "status" => "working"} =
             Jason.decode!(content)

    assert Tasks.running?(child)
    assert [%{child_id: ^child, parent_id: ^parent}] = Tasks.active()

    # SUBTASK-16: stopping the child's own turn doesn't end its task, so its chat
    # is left idle and the entry is still held.
    :ok = Agent.stop(child)
    assert Agent.snapshot(child).status == :idle
    assert [%{child_id: ^child, parent_id: ^parent}] = Tasks.active()

    # SUBTASK-34: nor does a later turn that ends without marking the chat done.
    carry_on(child)
    assert Tasks.running?(child)
    refute Map.has_key?(Store.load_task(child), :result)

    # SUBTASK-26: from outside, that child is an idle chat (UI-59), with no
    # result to report yet.
    assert {:ok, json} = Tasks.list_tasks(%{"task_id" => child}, %{session_id: parent})
    assert %{"task_id" => ^child, "status" => "idle"} = listed = Jason.decode!(json)
    refute Map.has_key?(listed, "result")

    # SUBTASK-33: the user marking the child's chat done is what ends it, with
    # the last thing the child said as its summary.
    assert {:ok, true} = Agent.set_done(child, true)
    assert :ok = await_released(child)

    assert %{result: %{"summary" => "Never.", "commit" => nil, "files" => []}} =
             Store.load_task(child)

    assert Tasks.active() == []
  end

  # SUBTASK-30, ISOL-18
  test "a sub-task chat carries its parent's jail setting", %{parent: parent} do
    # The parent's jail is off, so the child must start with its own copy of that.
    :ok = Agent.set_jail(parent, false)

    push_turns(
      router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &reporting_child/1)
    )

    run_parent(parent, ["s1"])

    child = session_json(parent, "spawn_task", 0)["task_id"]

    assert Agent.snapshot(child).settings.jail == false

    # ISOL-18: the copy is the child's own from then on; changing either chat
    # afterwards never affects the other.
    :ok = Agent.set_jail(parent, true)
    assert Agent.snapshot(parent).settings.jail == true
    assert Agent.snapshot(child).settings.jail == false

    :ok = Agent.set_jail(child, true)
    assert Agent.snapshot(child).settings.jail == true
    assert Agent.snapshot(parent).settings.jail == true

    stop_session(child)
  end

  # SUBTASK-30, STORE-26
  test "a child of a chat that keeps the default is jailed", %{parent: parent} do
    # The parent's value is the default and so isn't in its file (STORE-25).
    assert Agent.snapshot(parent).settings.jail == true

    push_turns(
      router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &reporting_child/1)
    )

    run_parent(parent, ["s1"])

    child = session_json(parent, "spawn_task", 0)["task_id"]
    assert Agent.snapshot(child).settings.jail == true

    stop_session(child)
  end

  # PROJ-10, SUBTASK-23
  test "a sub-task chat carries its parent's project, and works in its folder" do
    dir = external_repo()
    external_head = head_of(dir)
    project = %{id: Agent.new_id(), name: "Other", folder: dir, harness?: false}

    parent = Agent.new_id()

    # APPR-14: an empty set, so the spawn below still asks.
    {:ok, _pid} =
      Agent.ensure_started(parent,
        loop_opts: [llm: %{provider: FakeLLM}],
        project: project,
        auto_approve: []
      )

    Agent.subscribe(parent)
    on_exit(fn -> stop_session(parent) end)

    push_turns(
      router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &reporting_child/1)
    )

    run_parent(parent, ["s1"])

    child = session_json(parent, "spawn_task", 0)["task_id"]

    assert Agent.snapshot(child).project == project
    assert Store.load_project(child) == project.id

    # SUBTASK-23: it shares its parent's workspace — this project's folder, not
    # Elia's tree — and its baseline is a commit of that repository.
    assert session_workspace(child) == dir
    assert %{start_commit: ^external_head} = Store.load_task(child)

    stop_session(child)
  end

  # SUBTASK-9, SUBTASK-23, PROJ-12
  test "a sub-task of another project writes there, not in Elia's tree" do
    dir = external_repo()
    external_head = head_of(dir)
    {elia_head, 0} = git(["rev-parse", "HEAD"])
    elia_head = String.trim(elia_head)
    assert external_head != elia_head

    # SUBTASK-6: the child copies its parent's set, so this one writes without
    # asking; the spawn itself still asks (APPR-14).
    {parent, _project} = external_parent(dir, auto_approve: ["write_file"])

    push_turns(router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &writing_child/1))

    run_parent(parent, ["s1"])

    child = session_json(parent, "spawn_task", 0)["task_id"]

    # The child's tool wrote into the project's folder, and Elia's tree is
    # untouched: no file, no commit.
    assert File.read!(Path.join(dir, "child_note.txt")) == "x\n"
    refute File.exists?(Path.join(Elia.Workspace.root(), "child_note.txt"))
    {head, 0} = git(["rev-parse", "HEAD"])
    assert String.trim(head) == elia_head

    # Its work is reported against that repository's own baseline (SUBTASK-9).
    assert %{start_commit: ^external_head} = Store.load_task(child)

    assert %{"summary" => "Wrote it", "commit" => nil, "files" => ["child_note.txt"]} =
             session_json(parent, "await_task", 0)

    stop_session(child)
  end

  # SUBTASK-23, SUBTASK-11, SUBTASK-35
  test "a child of another project is not a second writer in this one" do
    dir = external_repo()
    {parent, _project} = external_parent(dir)

    # A child of this project, blocked in its first model call, so its task holds
    # the project's tree.
    child = spawn_blocked_child(parent, self())

    # The workspace its entry names is its parent's project folder (SUBTASK-23)...
    assert :sys.get_state(Tasks).active[child].root == dir

    # ...so another project's folder is a different tree, and a chat whose child
    # writes in it is not a second writer here (SUBTASK-11).
    other_root = Path.join(System.tmp_dir!(), "elia-tree-#{System.unique_integer([:positive])}")
    assert :ok = Tasks.acquire("p9", "c9", other_root, %{})
    assert :ok = Tasks.release("c9")

    # The same tree would be refused (SUBTASK-4).
    assert {:error, message} = Tasks.acquire("p9", "c9", dir, %{})
    assert message =~ "is already writing in that workspace"

    # SUBTASK-35: deleting the child's chat releases its entry, and its parent's
    # wait answers with an error because the chat it waited for is gone.
    assert :ok = Agent.delete(child)
    await_status(parent, :idle)
    assert Tasks.active() == []

    {content, true} = session_result(parent)
    assert content =~ "was deleted"
  end

  # SUBTASK-4, SUBTASK-11, SUBTASK-33
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

    # SUBTASK-33: marking the child's chat done mid-turn ends the task while the
    # turn runs on, so the entry is released and the result saved.
    assert {:ok, true} = Agent.set_done(child, true)
    assert :ok = await_released(child)
    assert %{result: %{"task_id" => ^child}} = Store.load_task(child)
    assert Tasks.active() == []

    # The turn is still the one it was.
    assert Agent.snapshot(child).status == :running
    :ok = Agent.stop(child)
    await_status(parent, :idle)
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

    # SUBTASK-9: what the child changed includes what was already uncommitted in
    # its tree when it started, and a child that committed nothing reports no
    # commit.
    assert %{"summary" => "Did it", "commit" => nil, "files" => files} =
             session_json(parent, "await_task", 0)

    assert "dirty.txt" in files
    assert "lib/broken.ex" in files

    assert [%{parent_id: ^parent} = entry] = children_of(parent)
    assert %{result: %{"summary" => "Did it"}} = Store.load_task(entry.id)
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

  ## The entry's life

  # SUBTASK-34, SUBTASK-26, SUBTASK-27
  test "a child that ends a turn without marking its chat done keeps running", %{
    parent: parent
  } do
    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B"}),
        fn _request -> reply([Message.text("I looked around but never reported.")]) end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    child = await_child_started()
    await_idle(child)

    # SUBTASK-34: the child's turn is over and its task is not, so its entry is
    # held, nothing is saved as a result, and its parent's wait goes on.
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-26: its chat's own status is what the parent is told.
    assert {:ok, json} = Tasks.list_tasks(%{"task_id" => child}, %{session_id: parent})
    assert %{"task_id" => ^child, "status" => "idle"} = Jason.decode!(json)
    refute Map.has_key?(Jason.decode!(json), "result")

    # SUBTASK-33: the user settles it by marking the child's chat done (DONE-4),
    # and the task ends with the child's last words.
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)
    assert :ok = await_released(child)

    assert %{
             "summary" => "I looked around but never reported.",
             "commit" => nil,
             "files" => [],
             "task_id" => ^child
           } = session_json(parent, "await_task", 0)

    assert Tasks.active() == []
  end

  # SUBTASK-11, SUBTASK-16, SUBTASK-31, SUBTASK-33
  test "stopping the child's turn leaves its task running", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    # SUBTASK-16: the stop ends that turn, not the task, so nothing is recorded
    # and the child's chat is left as it was.
    :ok = Agent.stop(child)
    assert Agent.snapshot(child).status == :idle
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # STOP-2: the stop is what the child's own transcript says happened.
    assert %Message{role: :user, meta: %{stopped: :stopped}} =
             List.last(Agent.snapshot(child).messages)

    # SUBTASK-31: the wait goes on, and the child's chat being marked done is
    # what ends it and gives the parent its result.
    carry_on(child)
    assert Tasks.running?(child)

    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)

    {content, false} = session_result(parent)

    assert %{"summary" => "Never.", "task_id" => ^child, "commit" => nil, "files" => []} =
             Jason.decode!(content)

    assert Tasks.active() == []
    assert %{result: %{"summary" => "Never."}} = Store.load_task(child)
  end

  # SUBTASK-17, SESS-22, SUBTASK-16
  test "stopping the parent stops its child's turn, not its task", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    :ok = Agent.stop(parent)

    # SUBTASK-17: the child's turn is stopped — the user's stop stops the work.
    assert Agent.snapshot(child).status == :idle

    # SUBTASK-16: but its task goes on, so nothing is released or reported.
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    refute Map.has_key?(Store.load_task(child), :result)

    # SESS-22, STOP-1: the stop the user asked for is in the parent's transcript
    # too, under the cancelled call.
    messages = Agent.snapshot(parent).messages

    assert %Message{role: :tool, content: [%{content: "Cancelled by the user.", is_error: true}]} =
             Enum.at(messages, -2)

    assert %Message{role: :user, meta: %{stopped: :stopped}} = List.last(messages)

    # SUBTASK-33: the task ends when the child's chat is marked done, and not
    # before.
    carry_on(child)
    assert Tasks.running?(child)

    assert {:ok, true} = Agent.set_done(child, true)
    await_released(child)

    assert Tasks.active() == []
    assert %{result: %{"summary" => "Never."}} = Store.load_task(child)
  end

  # SUBTASK-12, SUBTASK-24, SUBTASK-33, SESS-27
  test "a child that hits its step limit pauses, and a resume starts the count over", %{
    parent: parent
  } do
    Agent.subscribe_activity()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_steps" => 1}),
        &pausing_child/1
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    # SUBTASK-26: the child's own status is `paused` — the status its row shows
    # (UI-46, UI-58) — not a task status of its own.
    assert_receive {:chat_status, child, :paused}, 20_000

    assert Agent.snapshot(child).pause == "Step limit reached (1 steps)."

    # LIMIT-5, LIMIT-12: a sub-task's limits come from its spawn, which sets no
    # token budget — so the child's token spend is unlimited until the user sets
    # one on its own settings page.
    assert %{max_steps: 1, max_tokens: nil, pause_on_limit: true} =
             Agent.snapshot(child).settings.limits

    # SUBTASK-24: the entry is still held and the parent is still waiting, with
    # no deadline of its own.
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    assert Agent.snapshot(parent).status == :running

    # Continue resumes the turn, the count starts over, and the child marks its
    # chat done in that step — which is the end (SUBTASK-33).
    :ok = Agent.resume(child)
    await_status(parent, :idle)
    assert :ok = await_released(child)

    assert %{"summary" => "Reading the chats.", "task_id" => ^child} =
             session_json(parent, "await_task", 0)

    assert Tasks.active() == []
    assert %{result: %{"summary" => "Reading the chats."}} = Store.load_task(child)

    :ok = Agent.stop(child)
  end

  # SUBTASK-24, SUBTASK-16, SUBTASK-33
  test "stopping a paused child's turn leaves its task running", %{parent: parent} do
    Agent.subscribe_activity()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_steps" => 1}),
        fn _request -> reply([FakeLLM.tool_call("r1", "list_chats", %{})]) end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    child = await_child_started()
    await_chat_status(child, :paused)

    # SUBTASK-16: stopping the paused turn ends that turn, not the task — no
    # result is recorded, the child keeps its entry and the parent waits on.
    :ok = Agent.stop(child)
    assert Agent.snapshot(child).status == :idle
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-33: only marking its chat done ends it, and a child that said
    # nothing in a message of its own gets the placeholder summary (SUBTASK-9).
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)

    assert %{
             "summary" => "The task ended without a summary.",
             "commit" => nil,
             "files" => [],
             "task_id" => ^child
           } = session_json(parent, "await_task", 0)

    assert Tasks.active() == []
  end

  # SUBTASK-18, SUBTASK-24, SUBTASK-33, SESS-27
  test "a child that runs out of time pauses, and failing it leaves the task running", %{
    parent: parent
  } do
    Agent.subscribe_activity()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B", "max_minutes" => 0.01}),
        fn _request ->
          # Longer than the whole budget (600 ms), so the next step pauses.
          Process.sleep(700)
          reply([Message.text("Spent it all."), FakeLLM.tool_call("r1", "list_chats", %{})])
        end
      )
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    child = await_child_started()
    await_chat_status(child, :paused)
    assert Tasks.running?(child)

    # SUBTASK-24: Fail ends the turn with the limit's error, and the task goes on
    # — its chat isn't marked done.
    Agent.subscribe(child)
    :ok = Agent.fail_task(child)
    await_status(child, :idle)

    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-33: the user marks the child's chat done, and that is the end.
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)

    assert %{"task_id" => ^child, "commit" => nil, "summary" => "Spent it all."} =
             session_json(parent, "await_task", 0)

    assert Tasks.active() == []
  end

  # SUBTASK-18, SUBTASK-33
  test "time spent waiting for approval doesn't count against the budget", %{parent: parent} do
    Agent.subscribe_activity()

    child_turn = fn request ->
      case results(request) do
        [] -> reply([FakeLLM.tool_call("c1", "shell", %{"command" => "true"})])
        [{"shell", _, _}] -> reply([Message.text("Fine"), done_call()])
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

    child = await_child_started()
    await_chat_status(child, :awaiting_approval)

    # Longer than the whole budget (1.2 s): the child is waiting for the user, so
    # its clock is stopped and nothing happens — the task is still held.
    Process.sleep(1_800)
    assert Tasks.running?(child)

    :ok = Agent.approve(child, "c1")
    await_status(parent, :idle)

    assert %{"summary" => "Fine", "task_id" => ^child} =
             session_json(parent, "await_task", 0)
  end

  # SUBTASK-34, SUBTASK-27, SUBTASK-33
  test "a child whose session dies keeps running, and its wait goes on", %{parent: parent} do
    test_pid = self()

    push_turns(
      router(
        &spawn_and_await(&1, %{"title" => "T", "brief" => "B"}),
        fn _request ->
          send(test_pid, {:child_blocked, self(), active_child()})
          receive do: (:never -> :ok)
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

    # SUBTASK-34: a session that dies is not a task's end — the entry is held and
    # the parent's wait goes on.
    Process.sleep(200)
    assert Tasks.active() == [%{child_id: child, parent_id: parent}]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-33: the user settles it in the child's chat, and that ends it.
    {:ok, _pid} = Agent.ensure_started(child)
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)
    assert :ok = await_released(child)

    assert %{
             "summary" => "The task ended without a summary.",
             "commit" => nil,
             "task_id" => ^child
           } = session_json(parent, "await_task", 0)
  end

  # SUBTASK-35, SESS-29
  test "a running sub-task chat the user deletes stays deleted", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    assert Store.exists?(child)
    assert [%{id: ^child}] = children_of(parent)

    # SUBTASK-35: the wait is running — the parent is inside `await_task` for
    # this child's chat, which has read the child's metadata and is waiting for
    # its chat to be marked done.
    Process.sleep(200)

    # SESS-29, UI-65: deleting the running child stops its turn, kills its
    # session and removes its file.
    :ok = Agent.delete(child)
    refute Store.exists?(child)
    assert children_of(parent) == []

    # SUBTASK-35: its entry is released, and the parent's wait answers with an
    # error rather than waiting for a chat that no longer exists.
    assert Tasks.active() == []

    await_status(parent, :idle)
    {content, true} = session_result(parent)
    assert content =~ "was deleted"

    # SUBTASK-35: and nothing writes the chat back.
    refute Store.exists?(child)
    assert children_of(parent) == []
  end

  # SUBTASK-36, SUBTASK-11
  test "a child whose brief never went out is not a running child" do
    test_pid = self()
    parent = Agent.new_id()
    child = Agent.new_id()
    root = Path.join(System.tmp_dir!(), "elia-brief-#{System.unique_integer([:positive])}")

    task = %{
      parent_id: parent,
      parent_call_id: "s1",
      title: "T",
      brief: "B",
      started_at: DateTime.utc_now(),
      start_commit: "abc"
    }

    # SUBTASK-36: the child's chat is saved with the metadata of a child before
    # its brief goes out.
    :ok = Store.save(child, [], task: task)
    on_exit(fn -> Store.delete(child) end)

    # The spawner — the process running `spawn_task` — takes the entry and dies
    # before it sends the brief (SUBTASK-17: a stopped parent's turn kills it).
    spawner =
      spawn(fn ->
        :ok = Tasks.acquire(parent, child, root, %{call_id: "s1"})
        send(test_pid, :acquired)
        receive do: (:never -> :ok)
      end)

    assert_receive :acquired, 20_000
    assert Tasks.running?(child)

    Process.exit(spawner, :kill)

    # SUBTASK-36: its entry is released, nothing is announced for it, and its
    # chat is left saved and unmarked for the user to open, use or delete.
    assert :ok = await_released(child)
    assert Tasks.active() == []
    assert Store.load(child) == []
    assert %{parent_id: ^parent} = Store.load_task(child)
    refute Map.get(Store.entry(child) || %{}, :done, false)

    # SUBTASK-11, SUBTASK-34: an entry whose brief did go out is a running child
    # however its spawner goes.
    other = Agent.new_id()
    sent = spawn(fn -> acquire_and_send(parent, other, root <> "-sent", test_pid) end)
    assert_receive {:sent, ^other}, 20_000

    Process.exit(sent, :kill)
    Process.sleep(100)

    assert Tasks.running?(other)
    assert :ok = Tasks.release(other)
    refute Tasks.running?(other)
  end

  defp acquire_and_send(parent, child, root, test_pid) do
    :ok = Tasks.acquire(parent, child, root, %{call_id: "s2"})
    :ok = Tasks.brief_sent(child)
    send(test_pid, {:sent, child})
    receive do: (:never -> :ok)
  end

  # SUBTASK-9
  test "the result's files are the child's changes, committed and uncommitted", %{
    parent: parent
  } do
    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([spawn_call(%{"title" => "T", "brief" => "B"})])

        counts(request, "await_task") == 0 ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => task_id(request)})])

        true ->
          reply([Message.text("Checked.")])
      end
    end

    child_turn = fn request ->
      if results(request, "mark_done") != [] do
        reply([Message.text("Done.")])
      else
        commit_file("child.txt")
        File.write!(Path.join(Elia.Workspace.root(), "dirty.txt"), "wip")
        reply([Message.text("Stuck on the name."), done_call()])
      end
    end

    push_turns(router(parent_turn, child_turn))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    {head, 0} = git(["rev-parse", "HEAD"])

    # SUBTASK-9: a child that says nothing about status still has one to report —
    # the end of its chat. Its last words are the summary, and the harness fills
    # in the commit and the files.
    assert %{
             "task_id" => _child,
             "summary" => "Stuck on the name.",
             "commit" => commit,
             "files" => files
           } = result = session_json(parent, "await_task", 0)

    assert commit == String.trim(head)
    assert files == ["child.txt", "dirty.txt"]
    assert Map.keys(result) |> Enum.sort() == ["commit", "files", "summary", "task_id"]
  end

  # SUBTASK-4, SUBTASK-11
  test "the registry holds every running child, one writer per workspace" do
    assert Tasks.active() == []

    root = Path.join(System.tmp_dir!(), "elia-registry-#{System.unique_integer([:positive])}")

    assert :ok = Tasks.acquire("p1", "c1", root <> "/one")
    assert :ok = Tasks.acquire("p2", "c2", root <> "/two")

    assert Enum.sort_by(Tasks.active(), & &1.child_id) == [
             %{child_id: "c1", parent_id: "p1"},
             %{child_id: "c2", parent_id: "p2"}
           ]

    assert Tasks.running?("c1")
    refute Tasks.running?("c3")
    assert Tasks.writing_in(root <> "/one") == "c1"
    assert Tasks.writing_in(root <> "/free") == nil

    # SUBTASK-4, SUBTASK-11: one writer per workspace.
    assert {:error, "Not started: sub-task c1 is already writing in that workspace."} =
             Tasks.acquire("p3", "c3", root <> "/one")

    # SUBTASK-11: an entry says nothing about a session, so it is held however
    # the child's turns go (SUBTASK-16, SUBTASK-34) and only released when its
    # chat is marked done (SUBTASK-13) or deleted (SUBTASK-35).
    assert Tasks.active() == [
             %{child_id: "c1", parent_id: "p1"},
             %{child_id: "c2", parent_id: "p2"}
           ]

    assert :ok = Tasks.release("c1")
    refute Tasks.running?("c1")
    assert Tasks.active() == [%{child_id: "c2", parent_id: "p2"}]

    # SUBTASK-17: stopping a parent stops the turns of the children it has
    # running, and nothing is recorded for a child's own stop (SUBTASK-16): it
    # keeps its entry.
    assert :ok = Tasks.stop_children("p2")
    assert Tasks.running?("c2")

    assert :ok = Tasks.release("c2")
    assert Tasks.active() == []
  end

  # SUBTASK-26, SUBTASK-27, SUBTASK-34
  test "list_tasks and await_task only see this chat's own sub-tasks", %{parent: parent} do
    other = new_session()
    task = Agent.new_id()

    # A child of an earlier version (Stored data): its metadata still carries a
    # `status`, and its chat is marked done — so its task ended.
    :ok =
      Store.save(task, [Message.user("x")],
        done: true,
        task: %{
          parent_id: parent,
          title: "T",
          brief: "B",
          started_at: DateTime.utc_now(),
          status: "blocked",
          start_commit: "abc",
          result: %{"task_id" => task, "summary" => "S", "commit" => nil, "files" => []}
        }
      )

    on_exit(fn -> stop_session(task) end)

    # SUBTASK-34: the `status` an older version saved is not read.
    refute Map.has_key?(Store.load_task(task), :status)

    ctx = %{session_id: other, turn_id: nil}

    assert {:error, message} = Tasks.list_tasks(%{"task_id" => task}, ctx)
    assert message =~ "is not a sub-task"

    assert {:error, message} = Tasks.await_task(%{"task_id" => task}, ctx)
    assert message =~ "is not a sub-task"

    # SUBTASK-27: a task whose chat is marked done answers from its metadata.
    assert {:ok, json} =
             Tasks.await_task(%{"task_id" => task}, %{session_id: parent, turn_id: nil})

    assert %{"task_id" => ^task, "summary" => "S"} = Jason.decode!(json)

    # SUBTASK-26, DONE-2: and the single-task form reports it with the result,
    # with the status its own chat has.
    assert {:ok, json} = Tasks.list_tasks(%{"task_id" => task}, %{session_id: parent})

    assert %{"task_id" => ^task, "status" => "done", "result" => %{"summary" => "S"}} =
             Jason.decode!(json)

    # SUBTASK-34: a child whose chat isn't marked done is a running child, and
    # its chat's status is what is reported.
    waiting = Agent.new_id()

    :ok =
      Store.save(waiting, [Message.user("y")],
        task: %{
          parent_id: parent,
          title: "W",
          brief: "B",
          started_at: DateTime.utc_now(),
          status: "failed",
          start_commit: "abc"
        }
      )

    on_exit(fn -> stop_session(waiting) end)

    assert {:ok, json} = Tasks.list_tasks(%{"task_id" => waiting}, %{session_id: parent})
    assert %{"task_id" => ^waiting, "status" => "idle"} = Jason.decode!(json)
  end

  # SUBTASK-13, SUBTASK-33, DONE-9
  test "the end is saved once, however often the chat is marked done", %{parent: parent} do
    child = Agent.new_id()
    {head, 0} = git(["rev-parse", "HEAD"])

    :ok =
      Store.save(child, [%Message{role: :assistant, content: [Message.text("It is done.")]}],
        task: %{
          parent_id: parent,
          title: "T",
          brief: "B",
          started_at: DateTime.utc_now(),
          start_commit: String.trim(head)
        }
      )

    on_exit(fn -> stop_session(child) end)

    {:ok, _pid} = Agent.ensure_started(child)

    assert {:ok, true} = Agent.set_done(child, true)
    assert %{result: first} = Store.load_task(child)
    assert %{"summary" => "It is done."} = first

    # DONE-9: reopening the chat doesn't un-end the task (SUBTASK-33).
    assert {:ok, false} = Agent.set_done(child, false)
    assert %{result: ^first} = Store.load_task(child)

    # SUBTASK-13: marked done again, it keeps the result it has — even though the
    # chat has changed since.
    File.write!(Path.join(Elia.Workspace.root(), "note.txt"), "x\n")

    :ok = Agent.send_message(child, "One more thing.")
    Agent.subscribe(child)
    await_status(child, :idle)

    assert {:ok, true} = Agent.set_done(child, true)
    assert %{result: ^first} = Store.load_task(child)

    File.rm!(Path.join(Elia.Workspace.root(), "note.txt"))
  end
end
