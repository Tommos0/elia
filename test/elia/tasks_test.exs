defmodule Elia.TasksTest do
  use ExUnit.Case, async: false

  alias Elia.Skills.Tasks
  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  setup do
    start_supervised!(FakeLLM)
    parent = new_session()

    on_exit(fn ->
      for entry <- Store.list(1000), Map.get(entry, :parent_id) == parent do
        stop_session(entry.id)
        Store.delete(entry.id)
      end
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

  # A chat in a project outside Elia's own, which works in that project's folder
  # (PROJ-12). Its children are stopped with it.
  defp external_parent(dir, opts) do
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

  # SUBTASK-34, STORE-18: the chats this parent has started (STORE-17), and the
  # ones among them nobody has marked done — a running child is a child chat
  # whose chat isn't marked done, so this is what "still running" means now that
  # there is no registry (the retired SUBTASK-11).
  defp children_of(parent), do: Store.children(parent)

  defp running_children(parent),
    do: for(%{done: false} = child <- children_of(parent), do: child.id)

  # SUBTASK-5: the child's chat exists before its session does, so this is the
  # first thing a spawn leaves behind.
  defp await_child(parent, tries \\ 500)

  defp await_child(_parent, 0), do: flunk("no child chat was started")

  defp await_child(parent, tries) do
    case children_of(parent) do
      [%{id: child} | _] ->
        child

      [] ->
        Process.sleep(20)
        await_child(parent, tries - 1)
    end
  end

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
      results(request, "shell") == [] ->
        reply([
          FakeLLM.tool_call("w1", "shell", %{"command" => "printf 'x\\n' > child_note.txt"})
        ])

      results(request, "mark_done") == [] ->
        reply([Message.text("Wrote it"), done_call()])

      true ->
        reply([Message.text("Done.")])
    end
  end

  # A child that blocks in its first model call until the test lets it answer.
  defp blocked_child(test_pid) do
    fn _request ->
      send(test_pid, {:child_blocked, self()})
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

    child = await_child(parent)
    assert_receive {:child_blocked, _loop}, 20_000

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
    assert_receive {:child_blocked, loop}, 20_000
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

  # SUBTASK-1, SUBTASK-26
  test "a parent has the sub-task tools and a child has exactly an ordinary chat's tools" do
    parent_skills = Elia.Skills.current()
    parent = parent_skills |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name)
    child_skills = Elia.Skills.for_child()
    child = child_skills |> Enum.flat_map(& &1.tools) |> Enum.map(& &1.name)

    assert "tasks" in Enum.map(parent_skills, & &1.name)
    assert "spawn_task" in parent
    assert "await_task" in parent

    # SUBTASK-26: `list_tasks` is gone — the tool, its schema and its mention in
    # the skill's instructions. A parent lists its children with `list_chats`
    # (HIST-2) and reads them like any chat.
    refute "list_tasks" in parent
    refute Elia.Skills.Tasks.instructions() =~ "list_tasks"

    # SUBTASK-1: a child's session is the ordinary registry minus the `tasks`
    # skill, so it has the tools any chat has — `mark_done` among them — and
    # none of the sub-task ones.
    refute "tasks" in Enum.map(child_skills, & &1.name)
    refute "spawn_task" in child
    refute "await_task" in child
    refute "list_tasks" in child
    assert "mark_done" in child
    assert "shell" in child

    # SUBTASK-1: and there is no child-only tool and no child-only skill.
    refute "finish_task" in (parent ++ child)
    refute Enum.any?(child_skills, &(&1.name in ["task", "tasks"]))
  end

  # SUBTASK-1, SUBTASK-2, SUBTASK-27
  test "spawn needs approval; awaiting never does" do
    assert [
             %Elia.Tool{name: "spawn_task", approval: :required},
             %Elia.Tool{name: "await_task", approval: :never}
           ] = Elia.Skills.Tasks.tools()
  end

  # SUBTASK-37, SUBTASK-38: the skill teaches the file convention — a parent
  # numbers its sub-tasks and hands each brief over as `.tasks/<n>/brief.md`,
  # passed by path, and the child answers in `report.md` beside it.
  test "the skill hands a brief over as a numbered file, answered in report.md" do
    instructions = Elia.Skills.Tasks.instructions()

    assert instructions =~ "`001`, `002`"
    assert instructions =~ ".tasks/001/brief.md"
    assert instructions =~ ".tasks/001/report.md"
    assert instructions =~ "absolute"
    refute instructions =~ "the `brief` is its whole input"

    # SUBTASK-2: the tool says the same, since that is what the model reads at
    # the call itself.
    assert [%Elia.Tool{name: "spawn_task"} = spawn | _] = Elia.Skills.Tasks.tools()
    assert spawn.description =~ ".tasks/"
    assert spawn.input_schema["properties"]["brief"]["description"] =~ ".tasks/"
  end

  # SUBTASK-2, SUBTASK-5, SUBTASK-6, SUBTASK-9, SUBTASK-13, SUBTASK-15,
  # SUBTASK-27, SUBTASK-33, LIMIT-5
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

        counts(request, "await_task") == 0 ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => task_id(request)})])

        counts(request, "await_task") == 1 ->
          # SUBTASK-27: the child's chat is marked done, so this returns at once.
          reply([FakeLLM.tool_call("a2", "await_task", %{"task_id" => task_id(request)})])

        true ->
          reply([Message.text("Done.")])
      end
    end

    child_turn = fn request ->
      if results(request, "mark_done") != [] do
        reply([Message.text("Marked done.")])
      else
        send(test_pid, {:child_started, request, self()})

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
    # parent goes on and asks for the result when it wants it.
    assert_receive {:child_started, request, loop}, 20_000
    child = await_child(parent)

    assert %{"task_id" => ^child, "title" => "Add file", "status" => "working"} =
             session_json(parent, "spawn_task", 0)

    # SUBTASK-5: the child's first message is the preamble and the brief, and the
    # preamble says how the task ends.
    assert [%Message{role: :user} = brief | _] = request.messages
    assert Message.text_content(brief) =~ "sub-task agent"
    assert Message.text_content(brief) =~ "# Task: Add file"
    assert Message.text_content(brief) =~ "Create child.txt and commit it."
    assert Message.text_content(brief) =~ "mark_done"
    assert Message.text_content(brief) =~ "commit"
    # SUBTASK-38: and where the brief names a file to read, it names the report
    # beside it too — the file the child writes before it marks the chat done.
    assert Message.text_content(brief) =~ "report.md"
    assert Message.text_content(brief) =~ "beside the brief file"

    # SUBTASK-1, SUBTASK-6: the child's own tools, and the model that was asked
    # for. It has `mark_done` and no sub-task tool, and no `tasks` skill.
    assert "mark_done" in tool_names(request)
    refute "spawn_task" in tool_names(request)
    refute "await_task" in tool_names(request)
    refute "finish_task" in tool_names(request)
    assert request.system =~ "## Skill: done\n"
    refute request.system =~ "## Skill: tasks\n"
    assert request.model == "other-model"
    assert %{model: "other-model"} = Agent.snapshot(child).settings.model
    assert Elia.Settings.get(:model) == default_model

    # LIMIT-5, LOOP-16: the spawn sets the child no limits of its own — it starts
    # with the loop's own default, the one an ordinary chat has.
    assert %{max_steps: nil, max_minutes: nil, pause_on_limit: true} =
             Agent.snapshot(child).settings.limits

    # SUBTASK-1: a child can't start a child.
    assert {:error, "Not started: a sub-task can't start" <> _} =
             Tasks.spawn_task(%{"title" => "t", "brief" => "b"}, %{session_id: child})

    # SUBTASK-33: the child's own `mark_done` is the end.
    send(loop, :finish)
    await_status(parent, :idle)

    # SUBTASK-9: the result is the id and the summary — the child's last message
    # before it marked the chat done — and nothing else.
    assert %{"task_id" => ^child, "summary" => "Made child.txt"} =
             result = session_json(parent, "await_task", 0)

    assert Map.keys(result) |> Enum.sort() == ["summary", "task_id"]

    # SUBTASK-27: a task whose chat is already marked done returns at once, from
    # its metadata. LOOP-24: the second `await_task` is the identical call for
    # the identical result, so the loop appended its own notice to it.
    assert session_json(parent, "await_task", 1) == result

    # STORE-16, SUBTASK-9, SUBTASK-13: the child's saved metadata is the chat
    # that started it, when, and the result it ended with — and no status, title
    # or brief of its own.
    assert %{
             parent_id: ^parent,
             started_at: started_at,
             result: %{"task_id" => ^child, "summary" => "Made child.txt"}
           } = task = Store.load_task(child)

    assert %DateTime{} = started_at
    assert Map.keys(task) |> Enum.sort() == [:parent_id, :result, :started_at]

    # STORE-17, UI-46, DONE-2: listed like a chat, under the title the spawn gave
    # its chat, with the status any chat has — its own.
    listed = Enum.find(Store.list(1000), &(&1.id == child))
    assert %{title: "Add file", parent_id: ^parent, done: true} = listed
    refute Map.has_key?(listed, :task_status)

    # SUBTASK-33, SUBTASK-34, STORE-18: marked done, the child is no longer one
    # of this chat's running children.
    assert running_children(parent) == []

    # SUBTASK-6: the child inherited the parent's auto-approved tools.
    assert Agent.snapshot(child).settings.auto_approve == ["shell"]

    # APPR-12: the copy is the child's own; changing the parent doesn't touch it.
    :ok = Agent.set_auto_approve(parent, "shell", false)
    assert Agent.snapshot(parent).settings.auto_approve == []
    assert Agent.snapshot(child).settings.auto_approve == ["shell"]
  end

  # SUBTASK-2, SUBTASK-16, SUBTASK-33, SUBTASK-34
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
    child = await_child(parent)
    assert_receive {:child_blocked, _loop}, 20_000

    # SUBTASK-2: the parent's turn ended with the child still running, and its
    # spawn call returned the start, not a result.
    {content, false} = session_result(parent)

    assert %{"task_id" => ^child, "title" => "T", "status" => "working"} =
             Jason.decode!(content)

    # SUBTASK-34, STORE-18: the child is running because its chat isn't marked
    # done — read from the saved chats, with nothing held in memory.
    assert running_children(parent) == [child]
    refute Map.has_key?(Store.load_task(child), :result)

    # SUBTASK-16: stopping the child's own turn doesn't end its task.
    :ok = Agent.stop(child)
    assert Agent.snapshot(child).status == :idle
    assert running_children(parent) == [child]

    # SUBTASK-34: nor does a later turn that ends without marking the chat done.
    carry_on(child)
    assert running_children(parent) == [child]
    refute Map.has_key?(Store.load_task(child), :result)

    # SUBTASK-33: the user marking the child's chat done is what ends it, with
    # the last thing the child said as its summary.
    assert {:ok, true} = Agent.set_done(child, true)

    assert %{result: %{"task_id" => ^child, "summary" => "Never."}} = Store.load_task(child)
    assert running_children(parent) == []
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
    # Elia's tree.
    assert session_workspace(child) == dir
    assert %{parent_id: ^parent} = Store.load_task(child)

    stop_session(child)
  end

  # SUBTASK-23, PROJ-12
  test "a sub-task of another project writes there, not in Elia's tree" do
    dir = external_repo()

    # SUBTASK-6: the child copies its parent's set, so this one writes without
    # asking (SHELL-1); the spawn itself still asks (APPR-14).
    {parent, _project} = external_parent(dir, auto_approve: ["shell"])

    push_turns(router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), &writing_child/1))

    run_parent(parent, ["s1"])

    child = session_json(parent, "spawn_task", 0)["task_id"]

    # The child's tool wrote into the project's folder, and Elia's own tree is
    # untouched: the child's workspace is the project's folder (SUBTASK-23).
    assert File.read!(Path.join(dir, "child_note.txt")) == "x\n"
    refute File.exists?(Path.join(Elia.Workspace.root(), "child_note.txt"))
    assert session_workspace(child) == dir

    # SUBTASK-9: what it did is its own last message; what it changed is not in
    # the result — its branch and its chat are where a parent looks for that.
    assert %{"task_id" => ^child, "summary" => "Wrote it"} =
             session_json(parent, "await_task", 0)

    stop_session(child)
  end

  # SUBTASK-2
  test "spawn_task needs a title and a brief", %{parent: parent} do
    assert {"title must not be blank", true} =
             refused_spawn(parent, %{"title" => " ", "brief" => "B"})

    assert {"brief must not be blank", true} =
             refused_spawn(parent, %{"title" => "T", "brief" => ""})

    assert children_of(parent) == []
  end

  ## The child's life

  # SUBTASK-27, SUBTASK-34
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

    child = await_child(parent)
    await_idle(child)

    # SUBTASK-34: the child's turn is over and its task is not, so nothing is
    # saved as a result and its parent's wait goes on.
    assert running_children(parent) == [child]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-33: the user settles it by marking the child's chat done (DONE-4),
    # and the task ends with the child's last words.
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)

    assert %{
             "summary" => "I looked around but never reported.",
             "task_id" => ^child
           } = session_json(parent, "await_task", 0)

    assert running_children(parent) == []
  end

  # SUBTASK-16, SUBTASK-31, SUBTASK-33
  test "stopping the child's turn leaves its task running", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    # SUBTASK-16: the stop ends that turn, not the task, so nothing is recorded
    # and the child's chat is left as it was.
    :ok = Agent.stop(child)
    assert Agent.snapshot(child).status == :idle
    assert running_children(parent) == [child]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # STOP-2: the stop is what the child's own transcript says happened.
    assert %Message{role: :user, meta: %{stopped: :stopped}} =
             List.last(Agent.snapshot(child).messages)

    # SUBTASK-31: the wait goes on, and the child's chat being marked done is
    # what ends it and gives the parent its result.
    carry_on(child)
    assert running_children(parent) == [child]

    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)

    {content, false} = session_result(parent)

    assert %{"summary" => "Never.", "task_id" => ^child} = Jason.decode!(content)
    assert running_children(parent) == []
    assert %{result: %{"summary" => "Never."}} = Store.load_task(child)
  end

  # SUBTASK-17, SESS-22, SUBTASK-16
  test "stopping the parent stops its child's turn, not its task", %{parent: parent} do
    child = spawn_blocked_child(parent, self())

    :ok = Agent.stop(parent)

    # SUBTASK-17, SESS-22: the child's turn is stopped — the user's stop stops
    # the work, read from the saved chats rather than from a registry.
    assert Agent.snapshot(child).status == :idle

    # SUBTASK-16: but its task goes on, so nothing is reported.
    assert running_children(parent) == [child]
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
    assert running_children(parent) == [child]

    assert {:ok, true} = Agent.set_done(child, true)
    await_idle(parent)

    assert running_children(parent) == []
    assert %{result: %{"summary" => "Never."}} = Store.load_task(child)
  end

  # SUBTASK-17, SESS-22
  test "stopping a parent's turn leaves a child whose chat is done alone", %{parent: parent} do
    test_pid = self()

    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([spawn_call(%{"title" => "T", "brief" => "B"})])

        counts(request, "await_task") == 0 ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => task_id(request)})])

        true ->
          send(test_pid, {:parent_blocked, self()})
          receive do: (:never -> reply([Message.text("Done.")]))
      end
    end

    push_turns(router(parent_turn, blocked_child(test_pid)))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    child = await_child(parent)
    assert_receive {:child_blocked, _loop}, 20_000

    # SUBTASK-33: the user marks the child's chat done while its turn runs, which
    # ends the task — the turn goes on.
    assert {:ok, true} = Agent.set_done(child, true)
    assert Agent.snapshot(child).status == :running

    # The result is saved then, so the parent's wait is over and its own next
    # step is running.
    assert %{result: %{"task_id" => ^child}} = Store.load_task(child)
    assert_receive {:parent_blocked, _loop}, 20_000

    # SESS-22, SUBTASK-17: stopping the parent stops the turns of its *running*
    # children — the ones whose chat isn't marked done — so this child's turn is
    # left alone.
    :ok = Agent.stop(parent)
    assert Agent.snapshot(child).status == :running

    # Cleanup: its own turn is still the user's to stop.
    :ok = Agent.stop(child)
    assert Agent.snapshot(child).status == :idle
  end

  # SUBTASK-34, SUBTASK-27, SUBTASK-33
  test "a child whose session dies keeps running, and its wait goes on", %{parent: parent} do
    push_turns(
      router(&spawn_and_await(&1, %{"title" => "T", "brief" => "B"}), blocked_child(self()))
    )

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")

    child = await_child(parent)
    assert_receive {:child_blocked, loop}, 20_000

    # SUBTASK-34: a session that dies is not a task's end.
    [{pid, _}] = Registry.lookup(Elia.Agent.Registry, child)
    :ok = DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)
    Process.exit(loop, :kill)

    # The child's chat isn't marked done, so it is still running and the parent's
    # wait goes on.
    Process.sleep(200)
    assert running_children(parent) == [child]
    refute Map.has_key?(Store.load_task(child), :result)
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-33: the user settles it in the child's chat, and that ends it.
    {:ok, _pid} = Agent.ensure_started(child)
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(parent, :idle)

    assert %{
             "summary" => "The task ended without a summary.",
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

    # SUBTASK-35: the parent's wait answers with an error rather than waiting
    # for a chat that no longer exists.
    await_status(parent, :idle)
    {content, true} = session_result(parent)
    assert content =~ "was deleted"

    # SUBTASK-35: and nothing writes the chat back.
    refute Store.exists?(child)
    assert children_of(parent) == []
  end

  # SUBTASK-27, STORE-16
  test "await_task only sees this chat's own sub-tasks, and reads an old task file", %{
    parent: parent
  } do
    other = new_session()
    task = Agent.new_id()

    # STORE-16: a task file an earlier version wrote, with the keys that version
    # had. It is read for the keys it has — the child's metadata and its result —
    # and no migration is needed: `status`, `title`, `brief`, `parent_call_id`
    # and `start_commit` are not read, and neither are the `commit` and `files`
    # in its result (SUBTASK-9).
    :ok =
      Store.save(task, [Message.user("x")],
        done: true,
        task: %{
          parent_id: parent,
          parent_call_id: "s1",
          title: "T",
          brief: "B",
          started_at: DateTime.utc_now(),
          status: "blocked",
          start_commit: "abc",
          result: %{"task_id" => task, "summary" => "S", "commit" => nil, "files" => []}
        }
      )

    on_exit(fn -> stop_session(task) end)

    assert %{parent_id: ^parent, result: %{"task_id" => ^task, "summary" => "S"}} =
             loaded = Store.load_task(task)

    assert Map.keys(loaded) |> Enum.sort() == [:parent_id, :result, :started_at]
    refute Map.has_key?(loaded, :status)

    # SUBTASK-27: a task of another chat is not this chat's to wait for.
    assert {:error, message} = Tasks.await_task(%{"task_id" => task}, %{session_id: other})
    assert message =~ "is not a sub-task"

    # SUBTASK-27: a task whose chat is marked done answers from its metadata, at
    # once, with the two keys of the result and nothing more.
    assert {:ok, json} = Tasks.await_task(%{"task_id" => task}, %{session_id: parent})
    assert Jason.decode!(json) == %{"task_id" => task, "summary" => "S"}
  end

  # SUBTASK-13, SUBTASK-33, DONE-9
  test "the end is saved once, however often the chat is marked done", %{parent: parent} do
    child = Agent.new_id()

    :ok =
      Store.save(child, [%Message{role: :assistant, content: [Message.text("It is done.")]}],
        task: %{parent_id: parent, started_at: DateTime.utc_now()}
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
    Agent.subscribe(child)
    FakeLLM.push(FakeLLM.assistant([Message.text("One more thing done.")]))
    :ok = Agent.send_message(child, "One more thing.")
    await_status(child, :idle)

    assert {:ok, true} = Agent.set_done(child, true)
    assert %{result: ^first} = Store.load_task(child)
  end
end
