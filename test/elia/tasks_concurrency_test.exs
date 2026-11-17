defmodule Elia.TasksConcurrencyTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, Deploy, FakeLLM, LiveTree, Projects, Store, Tasks}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  # A throwaway live tree: a chat in Elia's own project works in its own
  # worktree, so a sub-task's worktree is a workspace of its own and several
  # children run at once (DEPLOY-1, SUBTASK-11, SUBTASK-23).
  setup_all do
    tree = LiveTree.create()
    on_exit(fn -> LiveTree.remove(tree) end)
    %{tree: tree}
  end

  setup %{tree: tree} do
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, tree)
    start_supervised!(FakeLLM)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)
    end)

    %{parent: chat()}
  end

  ## Helpers

  # A chat in Elia's own project: it works in its own worktree, forked from the
  # trunk `master`.
  defp chat do
    id = Agent.new_id()

    {:ok, _pid} =
      Agent.ensure_started(id,
        project: Projects.harness(),
        loop_opts: [llm: %{provider: FakeLLM}],
        # APPR-14: a new chat auto-approves every tool; these chats ask, since
        # the tests approve each spawn.
        auto_approve: []
      )

    Agent.subscribe(id)
    on_exit(fn -> stop_session(id) end)
    id
  end

  defp stop_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id),
        do: DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    Store.delete(id)
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 30_000)

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
  defp await_released(child, tries \\ 1500)

  defp await_released(child, 0), do: flunk("the task of #{child} was never released")

  defp await_released(child, tries) do
    if Tasks.running?(child) do
      Process.sleep(20)
      await_released(child, tries - 1)
    else
      :ok
    end
  end

  defp tool_names(request), do: Enum.map(request.tools, & &1.name)

  defp parent?(request), do: "spawn_task" in tool_names(request)

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

  defp counts(request, name),
    do: Enum.count(results(request), fn {tool, _content, _error} -> tool == name end)

  # Queues the same turn `times` times: a parent and its children run at the
  # same time and share FakeLLM's single queue, so each turn decides from the
  # request which chat it is answering.
  defp pushes(turn, times \\ 16), do: for(_ <- 1..times, do: FakeLLM.push(turn))

  defp reply(blocks) do
    message = FakeLLM.assistant(blocks)

    stop = if Message.tool_calls(message) == [], do: :end_turn, else: :tool_use

    {:ok, %{message: message, stop_reason: stop, model: "fake", usage: %{}}}
  end

  defp spawn_call(call_id, title, brief),
    do: FakeLLM.tool_call(call_id, "spawn_task", %{"title" => title, "brief" => brief})

  # SUBTASK-33, DONE-6: a child's last act, and the end of its task.
  defp done_call(summary, id),
    do: [Message.text(summary), FakeLLM.tool_call(id, "mark_done", %{})]

  # SUBTASK-26: `list_tasks` called now, rather than read out of a recorded tool
  # result.
  defp fresh_list(parent) do
    {:ok, json} = Tasks.list_tasks(%{}, %{session_id: parent})
    Jason.decode!(json)
  end

  defp session_results(id), do: results(%{messages: Agent.snapshot(id).messages})

  # The `index`-th result of `name` in the chat's own history, decoded.
  defp session_json(id, name, index) do
    session_results(id)
    |> Enum.filter(fn {tool, _content, _error} -> tool == name end)
    |> Enum.at(index)
    |> case do
      nil -> nil
      {_tool, content, _error} -> Jason.decode!(content)
    end
  end

  # SUBTASK-5: the brief's `# Task: <title>` line identifies which sub-task a
  # child session is running.
  defp child_of(request) do
    brief = request.messages |> Enum.find(&(&1.role == :user)) |> Message.text_content()

    Enum.find_value(Tasks.active(), fn %{child_id: id} ->
      case Store.load_task(id) do
        %{title: title} = task -> if brief =~ "# Task: #{title}", do: {id, task}
        _ -> nil
      end
    end)
  end

  # The sub-task of `parent` whose title is `title`.
  defp child_named(parent, title) do
    parent
    |> Store.children()
    |> Enum.find_value(fn entry ->
      case Store.load_task(entry.id) do
        %{title: ^title} -> entry.id
        _ -> nil
      end
    end)
  end

  ## SUBTASK-2, 9, 11, 13, 26, 27, 33

  test "two children run at once and their results are collected in either order", %{
    parent: parent
  } do
    test_pid = self()

    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([spawn_call("s1", "Alpha", "Write alpha.")])

        counts(request, "spawn_task") == 1 ->
          reply([spawn_call("s2", "Beta", "Write beta.")])

        counts(request, "await_task") == 0 ->
          # SUBTASK-27: wait for the second child first, then the first.
          reply([
            FakeLLM.tool_call("a1", "await_task", %{"task_id" => child_named(parent, "Beta")})
          ])

        counts(request, "await_task") == 1 ->
          reply([
            FakeLLM.tool_call("a2", "await_task", %{"task_id" => child_named(parent, "Alpha")})
          ])

        counts(request, "list_tasks") == 0 ->
          reply([FakeLLM.tool_call("l1", "list_tasks", %{})])

        true ->
          reply([Message.text("Both done.")])
      end
    end

    child_turn = fn request ->
      if Enum.any?(request.messages, &match?(%Message{role: :tool}, &1)) do
        reply([Message.text("Done.")])
      else
        {child, task} = child_of(request)
        send(test_pid, {:child, child, task.title})

        # SUBTASK-23: the child commits its work in its own worktree.
        path = Deploy.worktree_path(child)
        File.write!(Path.join(path, "#{task.title}.txt"), "child")
        LiveTree.commit(path, "child work")

        # SUBTASK-33: and its own `mark_done` is what ends its task.
        reply(done_call("Wrote #{task.title}.txt", "d-#{task.title}"))
      end
    end

    pushes(fn request, _on_event ->
      if parent?(request), do: parent_turn.(request), else: child_turn.(request)
    end)

    # SUBTASK-2: each spawn returns as soon as its child has started.
    :ok = Agent.send_message(parent, "start both")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s2")
    await_status(parent, :idle)

    assert_receive {:child, alpha, "Alpha"}, 30_000
    assert_receive {:child, beta, "Beta"}, 30_000
    assert alpha != beta

    # SUBTASK-11: each child had a worktree of its own, and both are released.
    assert Deploy.worktree_path(alpha) != Deploy.worktree_path(beta)
    assert Tasks.active() == []

    # SUBTASK-2: both spawn calls returned the start, not a result — the child
    # chat's own status, `working` (SUBTASK-26).
    for index <- [0, 1] do
      assert %{"status" => "working", "task_id" => id} =
               session_json(parent, "spawn_task", index)

      assert id in [alpha, beta]
    end

    # SUBTASK-9, SUBTASK-27: both results came back, in the order asked for (Beta
    # first), each with the summary the child ended with, its commit and its
    # files — and no status.
    for {index, id, name} <- [{0, beta, "Beta"}, {1, alpha, "Alpha"}] do
      assert %{
               "task_id" => ^id,
               "summary" => summary,
               "commit" => commit,
               "files" => [file]
             } = result = session_json(parent, "await_task", index)

      assert summary == "Wrote #{name}.txt"
      assert file == "#{name}.txt"
      assert is_binary(commit)
      assert Map.keys(result) |> Enum.sort() == ["commit", "files", "summary", "task_id"]
    end

    # SUBTASK-26, UI-59: the status each child's row shows is its own chat's. The
    # list the parent's turn recorded was taken while the children's turns ran on
    # after they marked their chats done (SUBTASK-33), so each is `working` or
    # `done` there...
    assert Enum.all?(
             session_json(parent, "list_tasks", 0),
             &(&1["status"] in ["working", "done"])
           )

    # ...and once both turns have ended, both are `done`: their chats are marked
    # done and idle, and done stands in place of idle (DONE-2).
    await_idle(alpha)
    await_idle(beta)

    listing = fresh_list(parent)
    assert Enum.map(listing, & &1["status"]) == ["done", "done"]

    assert listing |> Enum.map(& &1["task_id"]) |> Enum.sort() ==
             Enum.sort([alpha, beta])

    # SUBTASK-13, STORE-16: each result names its own commit, and the task's
    # metadata carries no status of its own.
    for id <- [alpha, beta] do
      assert %{result: %{"task_id" => ^id, "commit" => commit}} = Store.load_task(id)
      assert is_binary(commit)
      refute Map.has_key?(Store.load_task(id), :status)
    end
  end

  ## SUBTASK-16, 17, 33

  test "stopping the parent stops every child it has running, and none of their tasks",
       %{parent: parent} do
    test_pid = self()

    parent_turn = fn request ->
      case counts(request, "spawn_task") do
        0 ->
          reply([spawn_call("s1", "Alpha", "Write alpha.")])

        1 ->
          reply([spawn_call("s2", "Beta", "Write beta.")])

        _ ->
          reply([
            FakeLLM.tool_call("a1", "await_task", %{"task_id" => child_named(parent, "Alpha")})
          ])
      end
    end

    child_turn = fn request ->
      {child, _task} = child_of(request)
      send(test_pid, {:child_running, child, self()})
      receive do: (:never -> reply([Message.text("Never.")]))
    end

    pushes(fn request, _on_event ->
      if parent?(request), do: parent_turn.(request), else: child_turn.(request)
    end)

    :ok = Agent.send_message(parent, "start both")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s2")

    assert_receive {:child_running, alpha, _alpha_loop}, 30_000
    assert_receive {:child_running, beta, _beta_loop}, 30_000
    assert alpha != beta
    assert length(Tasks.active()) == 2

    # The parent's turn is running: it is waiting for the first child.
    assert_receive {:agent, ^parent, {:tool_status, "a1", :running}}, 30_000
    assert Agent.snapshot(parent).status == :running

    # SUBTASK-7 retired, SUBTASK-26: each child's status is its own chat's, so
    # the parent's topic carries no per-task event at all; both children are
    # held and their chats are working.
    assert Tasks.running?(alpha)
    assert Tasks.running?(beta)
    assert Agent.snapshot(alpha).status == :running
    assert Agent.snapshot(beta).status == :running

    :ok = Agent.stop(parent)

    # SUBTASK-17, SUBTASK-16: each child's turn is stopped — the user's stop
    # stops the work — but each task goes on running, so nothing is released or
    # reported.
    for child <- [alpha, beta] do
      assert Agent.snapshot(child).status == :idle
      refute Map.has_key?(Store.load_task(child), :result)
    end

    assert length(Tasks.active()) == 2

    # SESS-22, STOP-1: the cancelled call, and then the stop the user asked for.
    messages = Agent.snapshot(parent).messages

    assert %Message{role: :tool, content: [%{content: "Cancelled by the user.", is_error: true}]} =
             Enum.at(messages, -2)

    assert %Message{role: :user, meta: %{stopped: :stopped}} = List.last(messages)

    # SUBTASK-33: the user marks each child's chat done (DONE-4), and that is
    # what ends its task — with the placeholder summary, since a child that never
    # said anything has none to report (SUBTASK-9).
    for child <- [alpha, beta] do
      assert {:ok, true} = Agent.set_done(child, true)
      assert :ok = await_released(child)

      assert %{
               result: %{
                 "task_id" => ^child,
                 "summary" => "The task ended without a summary.",
                 "commit" => nil,
                 "files" => []
               }
             } = Store.load_task(child)
    end

    assert Tasks.active() == []
  end
end
