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

  defp finish_call(summary) do
    FakeLLM.tool_call("f1", "finish_task", %{"status" => "done", "summary" => summary})
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

  ## SUBTASK-2, 11, 13, 26, 27

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

        reply([finish_call("Wrote #{task.title}.txt")])
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

    # SUBTASK-2: both spawn calls returned the start, not a result.
    for index <- [0, 1] do
      assert %{"status" => "running", "task_id" => id} = session_json(parent, "spawn_task", index)
      assert id in [alpha, beta]
    end

    # SUBTASK-27: both results came back, in the order asked for (Beta first).
    assert %{"task_id" => ^beta, "status" => "done", "files" => ["Beta.txt"]} =
             session_json(parent, "await_task", 0)

    assert %{"task_id" => ^alpha, "status" => "done", "files" => ["Alpha.txt"]} =
             session_json(parent, "await_task", 1)

    # SUBTASK-26: the list reports each child's final status.
    listing = session_json(parent, "list_tasks", 0)
    assert Enum.map(listing, & &1["status"]) == ["done", "done"]

    assert listing |> Enum.map(& &1["task_id"]) |> Enum.sort() ==
             Enum.sort([alpha, beta])

    # SUBTASK-13, SUBTASK-21: each result names its own commit.
    for id <- [alpha, beta] do
      assert %{status: "done", result: %{"task_id" => ^id, "commit" => commit}} =
               Store.load_task(id)

      assert is_binary(commit)
    end
  end

  ## SUBTASK-16, 17

  test "stopping the parent stops every child it has running", %{parent: parent} do
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

    # SUBTASK-7: both starts were announced.
    assert_receive {:agent, ^parent, {:subtask, "s1", ^alpha, "running"}}, 30_000
    assert_receive {:agent, ^parent, {:subtask, "s2", ^beta, "running"}}, 30_000

    :ok = Agent.stop(parent)

    # SUBTASK-17, SUBTASK-16: each child's turn is stopped — the user's stop
    # stops the work — but each task goes on running, so nothing is released or
    # reported.
    for child <- [alpha, beta] do
      assert Agent.snapshot(child).status == :idle
      assert %{status: "running"} = Store.load_task(child)
    end

    assert length(Tasks.active()) == 2
    refute_received {:agent, ^parent, {:subtask, _, _, _}}

    # SESS-22, STOP-1: the cancelled call, and then the stop the user asked for.
    messages = Agent.snapshot(parent).messages

    assert %Message{role: :tool, content: [%{content: "Cancelled by the user.", is_error: true}]} =
             Enum.at(messages, -2)

    assert %Message{role: :user, meta: %{stopped: :stopped}} = List.last(messages)

    # SUBTASK-16, SUBTASK-31: each child ends when a turn of it ends, and that is
    # what the parent's topic is told.
    for child <- [alpha, beta] do
      :ok = Agent.send_message(child, "carry on")
      assert_receive {:child_running, ^child, loop}, 30_000
      send(loop, :never)
      assert_receive {:agent, ^parent, {:subtask, _, ^child, "unfinished"}}, 30_000
      assert %{status: "unfinished"} = Store.load_task(child)
    end

    assert Tasks.active() == []
  end
end
