defmodule Elia.DeploymentTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, Deploy, Explorer, FakeLLM, LiveTree, Projects, Store, Workspace}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  # Each test gets its own live tree: a tiny git repo on branch `live`, with a
  # `master` trunk and a one-module Mix project, so a deploy's `mix test` runs
  # for real in it (DEPLOY-5, DEPLOY-14).
  setup do
    tree = LiveTree.create()
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, tree)
    start_supervised!(FakeLLM)

    on_exit(fn ->
      LiveTree.remove(tree)

      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)
    end)

    %{tree: tree}
  end

  ## Helpers

  defp head(dir), do: LiveTree.head(dir)
  defp branch(dir), do: LiveTree.branch(dir)
  defp commit(dir, message), do: LiveTree.commit(dir, message)
  defp chat_work!(path), do: LiveTree.work!(path)
  defp git(dir, args), do: LiveTree.git(dir, args)
  defp trunk(dir), do: LiveTree.sha(dir, LiveTree.trunk())

  # A change made on a chat's worktree and merged into the trunk the way its
  # agent does when the work is done (DEPLOY-13).
  defp work_on_trunk(path) do
    file = chat_work!(path)
    LiveTree.push_to_trunk(path)
    file
  end

  # A chat's worktree, from the trunk, removed again at the end of the test.
  defp new_worktree do
    id = Agent.new_id()
    assert {:ok, path} = Deploy.ensure_worktree(id)
    on_exit(fn -> Deploy.remove_worktree(id) end)
    {id, path}
  end

  # DEPLOY-1: the file tools and `mix test` for a chat in Elia's own project run
  # in its own worktree, not in the tree the server runs from.
  defp chat do
    id = Agent.new_id()

    {:ok, pid} =
      Agent.ensure_started(id,
        project: Projects.harness(),
        loop_opts: [llm: %{provider: FakeLLM}],
        # APPR-14: a new chat auto-approves every tool; these chats ask, since
        # the tests approve each spawn.
        auto_approve: []
      )

    Agent.subscribe(id)
    on_exit(fn -> stop_session(id) end)
    _ = pid
    id
  end

  defp stop_session(id) do
    for {pid, _} <- Registry.lookup(Elia.Agent.Registry, id),
        do: DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid)

    Store.delete(id)
  end

  defp await_status(id, status), do: assert_receive({:agent, ^id, {:status, ^status}}, 30_000)

  # Scripted turns for a parent and its children: they run at the same time and
  # share FakeLLM's single queue, so each turn decides from the request which
  # chat it answers (SUBTASK-28).
  defp router(parent_turn, child_turn) do
    fn request, _on_event ->
      if "spawn_task" in Enum.map(request.tools, & &1.name),
        do: parent_turn.(request),
        else: child_turn.(request)
    end
  end

  defp queue(turn, times \\ 12), do: for(_ <- 1..times, do: FakeLLM.push(turn))

  defp reply(blocks) do
    message = FakeLLM.assistant(blocks)
    stop = if Elia.LLM.Message.tool_calls(message) == [], do: :end_turn, else: :tool_use

    {:ok, %{message: message, stop_reason: stop, model: "fake", usage: %{}}}
  end

  defp after_tools?(request), do: match?(%Message{role: :tool}, List.last(request.messages))

  defp results(%{messages: messages}) do
    names =
      for %Message{role: :assistant} = message <- messages,
          call <- Elia.LLM.Message.tool_calls(message),
          into: %{},
          do: {call.id, call.name}

    for %Message{role: :tool} = message <- messages,
        result <- message.content,
        do: {names[result.tool_call_id], result.content, result.is_error}
  end

  defp counts(request, name),
    do: Enum.count(results(request), fn {tool, _content, _error} -> tool == name end)

  # The `task_id` of the first `spawn_task` call in the turn's history.
  defp spawned(request) do
    request
    |> results()
    |> Enum.find_value(fn
      {"spawn_task", content, false} -> Jason.decode!(content)["task_id"]
      _result -> nil
    end)
  end

  # The running server, as far as a deploy can tell: the endpoint's code
  # reloader is on (HOT-2, HOT-7; the suite turns it off, config/test.exs), and
  # loading a deploy is a message to the test instead of a real recompile, which
  # would rebuild Elia's own endpoint inside the test run (HOT-5).
  defp running_server(test_pid \\ self()) do
    endpoint = Application.get_env(:elia, EliaWeb.Endpoint)
    deploy = Application.get_env(:elia, Elia.Deploy, [])

    Application.put_env(:elia, EliaWeb.Endpoint, Keyword.put(endpoint, :code_reloader, true))

    Application.put_env(
      :elia,
      Elia.Deploy,
      Keyword.put(deploy, :load, fn _endpoint ->
        send(test_pid, :loaded)
        :ok
      end)
    )

    on_exit(fn ->
      Application.put_env(:elia, EliaWeb.Endpoint, endpoint)
      Application.put_env(:elia, Elia.Deploy, deploy)
    end)
  end

  # How the server stops for a restart (RESTART-1): a message to the test, not
  # the end of the test run.
  defp stop_server_with(test_pid) do
    deploy = Application.get_env(:elia, Elia.Deploy, [])

    Application.put_env(
      :elia,
      Elia.Deploy,
      Keyword.put(deploy, :stop, &send(test_pid, {:stop, &1}))
    )

    on_exit(fn -> Application.put_env(:elia, Elia.Deploy, deploy) end)
  end

  # The host allows the jail for the duration of the test (ISOL-20). The suite
  # runs unjailed by default (config/test.exs), so a test that needs the jail
  # turns it on for itself, as a chat's tool call does (ISOL-1).
  defp with_jail(opts \\ [], fun) do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, Keyword.merge([jail: true], opts))
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
    fun.()
  end

  # A test that needs the jail's effect skips where bubblewrap is missing
  # (ISOL-12); the ones that only build the argv don't.
  @jail_skip if(Elia.Shell.available?(),
               do: false,
               else: "bubblewrap is not available (ISOL-12)"
             )

  ## Requirements

  # DEPLOY-2
  test "the live tree is the runtime root and holds Elia's data", %{tree: tree} do
    assert Workspace.runtime_root() == tree
    assert Workspace.data_dir() == Path.join(tree, ".elia")

    # The default is Elia's root: `config :elia, :workspace`, else where the
    # server was started from.
    Application.delete_env(:elia, :runtime_root)
    assert Workspace.runtime_root() == Workspace.root()
  end

  # DEPLOY-12: the live reload watches the live tree's own static assets only,
  # never a chat's worktree: the checked-out copies there would reload the
  # browser while it navigates to a new chat, undoing the navigation.
  test "static reload patterns ignore chat worktrees", %{tree: tree} do
    [pattern] = Deploy.static_reload_patterns()

    assert Regex.match?(pattern, Path.join(tree, "priv/static/images/logo.svg"))
    assert Regex.match?(pattern, Path.join(tree, "priv/static/assets/app.js"))

    # A worktree's copies of those assets (DEPLOY-1) are not a live-tree change.
    refute Regex.match?(
             pattern,
             Path.join(tree, ".elia/worktrees/abc/priv/static/images/logo.svg")
           )

    refute Regex.match?(pattern, Path.join(tree, ".elia/worktrees/abc/priv/static/sw.js"))

    # User uploads never reload the browser, as before.
    refute Regex.match?(pattern, Path.join(tree, "priv/static/uploads/pic.png"))
  end

  # DEPLOY-3, PROJ-3
  test "Elia's own project's folder is the live tree, and its chats work in worktrees", %{
    tree: tree
  } do
    assert Projects.harness().folder == tree

    {id, path} = new_worktree()
    assert Deploy.workspace(Projects.harness(), id) == path
  end

  # DEPLOY-3, PROJ-12
  test "a chat in another project works in its folder, with no worktree" do
    folder = Path.join(System.tmp_dir!(), "elia-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(folder)
    on_exit(fn -> File.rm_rf!(folder) end)

    id = Agent.new_id()
    project = %{id: "other", name: "Other", folder: folder, harness?: false}

    assert Deploy.workspace(project, id) == folder
    refute File.exists?(Deploy.worktree_path(id))

    # A chat in Elia's own project in a tree that isn't set up for deployment
    # (nothing to fork from, DEPLOY-1) works in the live tree itself.
    other_live = Path.join(System.tmp_dir!(), "elia-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(other_live)
    on_exit(fn -> File.rm_rf!(other_live) end)
    Application.put_env(:elia, :runtime_root, other_live)

    assert {:error, message} = Deploy.ensure_worktree(id)
    assert message =~ "not on the branch live"
    assert Deploy.workspace(Projects.harness(), id) == other_live
    refute File.exists?(Deploy.worktree_path(id))
  end

  # DEPLOY-1, DEPLOY-13
  test "a chat's worktree is on its own branch, forked from the trunk", %{tree: tree} do
    {id, path} = new_worktree()

    assert path == Path.join([tree, ".elia", "worktrees", id])
    assert branch(path) == "chat/#{id}"
    # Forked from the trunk, so it has the live tree's committed files.
    assert head(path) == trunk(tree)
    assert File.exists?(Path.join(path, "mix.exs"))

    # Asking again keeps the worktree, and the work in it (DEPLOY-10).
    File.write!(Path.join(path, "notes.txt"), "wip")
    assert {:ok, ^path} = Deploy.ensure_worktree(id)
    assert File.read!(Path.join(path, "notes.txt")) == "wip"
  end

  # ISOL-7: nothing runs ahead of a command. A chat's worktree is created with
  # the shared `deps` linked in and no compile of its own, so a chat that runs no
  # command compiles nothing at all.
  test "a new worktree links the shared deps and starts no compile (ISOL-7)", %{tree: tree} do
    File.mkdir_p!(Path.join(tree, "deps/req"))
    {_id, path} = new_worktree()

    assert File.read_link!(Path.join(path, "deps")) == Path.join(tree, "deps")
    refute File.exists?(Elia.Deps.layer(path, tree))
  end

  # DEPLOY-10: a worktree's dependency layer goes with it.
  test "removing a worktree removes its dependency layer (DEPLOY-10)", %{tree: tree} do
    {id, path} = new_worktree()
    assert {:ok, _} = Elia.Deps.open(path, tree)
    assert File.dir?(Elia.Deps.layer(path, tree))

    Deploy.remove_worktree(id)
    refute File.exists?(Elia.Deps.layer(path, tree))
  end

  # DEPLOY-13: a chat merges its own branch into the trunk, so the next chat to
  # start works on top of it.
  test "the trunk carries the work a chat has merged into it", %{tree: tree} do
    {_first, first} = new_worktree()
    file = work_on_trunk(first)

    {_second, second} = new_worktree()

    assert head(second) == trunk(tree)
    assert File.exists?(Path.join(second, file))
    refute File.exists?(Path.join(tree, file))
  end

  # DEPLOY-5, DEPLOY-13
  test "a deploy fast-forwards live to the trunk once the tests pass", %{tree: tree} do
    {_id, path} = new_worktree()
    file = work_on_trunk(path)

    before = head(tree)
    assert {:ok, %{pending: 1}} = Deploy.status()
    assert {:ok, message} = Deploy.deploy()

    assert message =~ "merged into live"
    assert head(tree) != before
    assert head(tree) == trunk(tree)
    # The code is in the live tree now, and the running app is unchanged until a
    # deploy loads it (DEPLOY-8).
    assert File.exists?(Path.join(tree, file))
  end

  # DEPLOY-18: a dependency a chat added lives in that chat's own layer (ISOL-7),
  # so the deploy fetches the merged trunk's dependencies in the live tree before
  # its suite runs — and a fetch that fails is a deploy failure that rolls `live`
  # back, like a failing suite.
  test "a deploy fetches the trunk's dependencies before its suite (DEPLOY-18)", %{
    tree: tree
  } do
    {_id, path} = new_worktree()

    # A `mix.exs` the fetch can't load, merged into the trunk the way a chat's
    # work is: `mix deps.get` fails, so the deploy stops before the suite.
    File.write!(Path.join(path, "mix.exs"), "defmodule Broken do\n")
    commit(path, "a mix.exs that can't be loaded")
    LiveTree.push_to_trunk(path)

    before = head(tree)
    assert {:error, message} = Deploy.deploy()

    assert message =~ "Could not fetch the trunk's dependencies"
    # Nothing is deployed: `live` is where it was (DEPLOY-5).
    assert head(tree) == before
    assert branch(tree) == "live"
  end

  # DEPLOY-5: nothing to do when the trunk is already deployed.
  test "there is nothing to deploy when live is already the trunk", %{tree: tree} do
    assert {:ok, %{pending: 0}} = Deploy.status()

    live = head(tree)
    assert {:ok, message} = Deploy.deploy()
    assert message =~ "Nothing to deploy"
    assert head(tree) == live
  end

  # DEPLOY-17: what the app has loaded is recorded, so a deploy that merged and
  # never reached the load is reported rather than looking up to date.
  test "a merge that never loaded is reported", %{tree: tree} do
    running_server()
    {_id, path} = new_worktree()
    work_on_trunk(path)

    # Nothing recorded yet: what the app runs is unknown, not "behind".
    assert {:ok, %{behind?: false, loaded: nil}} = Deploy.status()

    # A deploy that loads records the revision it loaded.
    assert {:ok, _message} = Deploy.hot_reload()
    assert {:ok, %{behind?: false, loaded: loaded}} = Deploy.status()
    assert loaded == head(tree)

    # Another change merges into the live tree and the load never happens — a
    # deploy interrupted between the merge and the load (DEPLOY-15).
    work_on_trunk(path)
    assert {:ok, _message} = Deploy.deploy()

    assert {:ok, %{behind?: true, pending: 0, loaded: ^loaded, live: live}} = Deploy.status()
    assert live != loaded
    assert live == head(tree)

    # DEPLOY-6: hot reload with nothing to deploy still loads, which is the
    # recovery, and it records what it loaded.
    assert {:ok, message} = Deploy.hot_reload()
    assert message =~ "Nothing to deploy"
    assert message =~ "Recompiled and reloaded"
    assert {:ok, %{behind?: false, loaded: ^live}} = Deploy.status()
  end

  # DEPLOY-5, DEPLOY-8, HOT-4
  test "failing tests merge nothing, so the live tree is unaffected", %{tree: tree} do
    {_id, path} = new_worktree()

    File.write!(Path.join(path, "test/broken_test.exs"), """
    defmodule BrokenTest do
      use ExUnit.Case

      test "fails" do
        assert false
      end
    end
    """)

    commit(path, "broken")
    LiveTree.push_to_trunk(path)

    live = head(tree)
    assert {:tests_failed, output} = Deploy.deploy()
    assert output =~ "1 failure"
    assert head(tree) == live
    refute File.exists?(Path.join(tree, "test/broken_test.exs"))
  end

  # DEPLOY-5, DEPLOY-14
  test "a deploy refuses a live tree with uncommitted changes", %{tree: tree} do
    {_id, path} = new_worktree()
    work_on_trunk(path)

    File.write!(Path.join(tree, "lib/hand_edited.ex"), "defmodule HandEdited do\nend\n")

    live = head(tree)
    assert {:error, message} = Deploy.deploy()
    assert message =~ "uncommitted changes"
    assert head(tree) == live
  end

  # DEPLOY-14: the one-time setup a live tree needs before anything can be
  # deployed from it.
  test "a live tree is set up for deployment with a trunk at or ahead of live" do
    assert Deploy.deployable() == :ok

    # Not a repository at all.
    plain = Path.join(System.tmp_dir!(), "elia-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    Application.put_env(:elia, :runtime_root, plain)

    assert {:error, message} = Deploy.deployable()
    assert message =~ "not on the branch live"
    assert {:error, _} = Deploy.status()
    refute Deploy.deployable?()

    # On `live`, but with no trunk.
    no_trunk = LiveTree.create()
    on_exit(fn -> LiveTree.remove(no_trunk) end)
    LiveTree.git!(no_trunk, ["branch", "-D", LiveTree.trunk()])
    Application.put_env(:elia, :runtime_root, no_trunk)

    assert {:error, message} = Deploy.deployable()
    assert message =~ "no master branch"

    # The trunk is behind `live`.
    behind = LiveTree.create()
    on_exit(fn -> LiveTree.remove(behind) end)
    File.write!(Path.join(behind, "lib/extra.ex"), "defmodule Extra do\nend\n")
    LiveTree.commit(behind, "live moved on")
    Application.put_env(:elia, :runtime_root, behind)

    assert {:error, message} = Deploy.deployable()
    assert message =~ "git branch -f master live"
    assert {:error, ^message} = Deploy.deploy()
  end

  # DEPLOY-5, DEPLOY-14
  test "merging the trunk into live is fast-forward only" do
    tree = LiveTree.create()
    on_exit(fn -> LiveTree.remove(tree) end)
    Application.put_env(:elia, :runtime_root, tree)

    {_id, path} = new_worktree()
    work_on_trunk(path)

    # The live tree moves on by hand, so `live` and the trunk have diverged.
    File.write!(Path.join(tree, "lib/other.ex"), "defmodule Other do\nend\n")
    commit(tree, "committed straight on live")

    assert {:error, message} = Deploy.merge()
    assert message =~ "fast-forward only"
    assert {:error, _} = Deploy.deployable()
    assert {:error, _} = Deploy.deploy()
  end

  # DEPLOY-6, HOT-5
  test "hot reload deploys, then reloads the running app", %{tree: tree} do
    running_server()
    {_id, path} = new_worktree()
    file = work_on_trunk(path)

    before = head(tree)
    assert {:ok, message} = Deploy.hot_reload()

    assert_received :loaded
    assert message =~ "merged into live"
    assert message =~ "Recompiled and reloaded"
    assert head(tree) != before
    assert File.exists?(Path.join(tree, file))
  end

  # DEPLOY-6, HOT-6
  test "a compile error is reported, truncated" do
    running_server()
    output = String.duplicate("x", 30_000)

    Application.put_env(
      :elia,
      Elia.Deploy,
      Keyword.put(Application.get_env(:elia, Elia.Deploy, []), :load, fn _endpoint ->
        {:error, output}
      end)
    )

    {_id, path} = new_worktree()
    work_on_trunk(path)

    assert {:error, message} = Deploy.hot_reload()
    assert message =~ "Compilation failed:"
    assert String.length(message) < 21_000
  end

  # DEPLOY-6, HOT-2, HOT-7
  test "hot reload is only available with the endpoint's code reloader on", %{tree: tree} do
    # The suite runs with the code reloader off (config/test.exs, HOT-7); the
    # value is read at runtime, so a test can turn it off as well (HOT-2).
    endpoint = Application.get_env(:elia, EliaWeb.Endpoint)
    Application.put_env(:elia, EliaWeb.Endpoint, Keyword.put(endpoint, :code_reloader, false))
    on_exit(fn -> Application.put_env(:elia, EliaWeb.Endpoint, endpoint) end)

    {_id, path} = new_worktree()
    work_on_trunk(path)

    before = head(tree)
    refute Deploy.hot_reload_available?()
    assert {:error, message} = Deploy.hot_reload()
    assert message =~ "code_reloader"
    assert head(tree) == before
  end

  # DEPLOY-7, RESTART-11, RESTART-1, RESTART-2
  test "restart deploys and restarts the server on a non-zero status", %{tree: tree} do
    running_server()
    stop_server_with(self())

    {_id, path} = new_worktree()
    work_on_trunk(path)

    before = head(tree)
    assert {:ok, message} = Deploy.restart()

    # A non-zero status is what makes `bin/serve` start the server again.
    assert_receive {:stop, status}
    assert status != 0
    assert message =~ "merged into live"
    assert message =~ "Restarting the server"
    assert head(tree) != before
  end

  # DEPLOY-7, RESTART-2
  test "restart refuses when nothing would bring the server back", %{tree: tree} do
    {_id, path} = new_worktree()
    work_on_trunk(path)

    before = head(tree)
    assert {:error, message} = Deploy.restart()
    assert message =~ "bin/serve"
    refute_received {:stop, _}
    assert head(tree) == before
  end

  # DEPLOY-10
  test "deleting a chat removes its worktree and prunes its branch", %{tree: tree} do
    id = Agent.new_id()
    {:ok, path} = Deploy.ensure_worktree(id)
    assert File.dir?(path)

    # A saved chat, so deleting it has something to delete.
    File.mkdir_p!(Store.dir())
    File.write!(Path.join(Store.dir(), id <> ".term"), :erlang.term_to_binary(%{messages: []}))

    assert :ok = Store.delete(id)

    refute File.exists?(path)
    assert elem(git(tree, ["rev-parse", "--verify", "--quiet", "refs/heads/chat/#{id}"]), 1) != 0
    # A branch is kept while its chat exists (DEPLOY-10).
    assert {:ok, _} = Deploy.ensure_worktree(id)
  end

  # DEPLOY-9, SUBTASK-23, SUBTASK-25
  test "a sub-task works in its own worktree, and the parent merges its work", %{
    tree: tree
  } do
    parent = chat()
    path = Deploy.worktree_path(parent)
    test_pid = self()

    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([
            FakeLLM.tool_call("s1", "spawn_task", %{"title" => "T", "brief" => "Write a note."})
          ])

        counts(request, "await_task") == 0 ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => spawned(request)})])

        true ->
          reply([Message.text("Done.")])
      end
    end

    # The child writes its note and commits it in its own worktree.
    child_turn = fn request ->
      if after_tools?(request) do
        reply([Message.text("Done.")])
      else
        [%{child_id: child}] = Elia.Tasks.active()
        send(test_pid, {:child, child})
        child_path = Deploy.worktree_path(child)
        File.write!(Path.join(child_path, "child-note.txt"), "child")
        LiveTree.commit(child_path, "child note")

        reply([
          FakeLLM.tool_call("f1", "finish_task", %{"status" => "done", "summary" => "wrote it"})
        ])
      end
    end

    queue(router(parent_turn, child_turn))

    before = head(path)
    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    assert_receive {:child, child}

    # SUBTASK-23: the child has its own worktree and branch, cut from the
    # parent's, so its work never touches the parent's tree while it runs.
    child_path = Deploy.worktree_path(child)
    assert child_path != path
    assert branch(child_path) == "chat/#{child}"
    assert head(child_path) != before
    assert File.read!(Path.join(child_path, "child-note.txt")) == "child"

    # SUBTASK-25: the harness does not merge it. The work stays on the child's
    # branch, and the parent's worktree and the live tree are untouched.
    refute File.exists?(Path.join(path, "child-note.txt"))
    refute File.exists?(Path.join(tree, "child-note.txt"))
    assert head(path) == before

    # The parent brings it in itself, fast-forward, as the instruction says.
    assert {_, 0} = LiveTree.git(path, ["merge", "--ff-only", "chat/#{child}"])
    assert File.read!(Path.join(path, "child-note.txt")) == "child"
    assert branch(path) == "chat/#{parent}"
    assert head(path) == head(child_path)

    # And its result is reported relative to its own workspace.
    result =
      Agent.snapshot(parent).messages
      |> Enum.find_value(fn
        %Message{role: :tool, content: [%{tool_call_id: "a1"} = result]} -> result
        _message -> nil
      end)

    assert %{content: content, is_error: false} = result
    assert %{"status" => "done", "files" => files} = Jason.decode!(content)
    assert "child-note.txt" in files
    stop_session(child)
  end

  # DEPLOY-9, SUBTASK-25
  test "a sub-task that doesn't finish as done keeps its work on its own branch" do
    parent = chat()
    path = Deploy.worktree_path(parent)
    test_pid = self()

    parent_turn = fn request ->
      cond do
        counts(request, "spawn_task") == 0 ->
          reply([
            FakeLLM.tool_call("s1", "spawn_task", %{"title" => "T", "brief" => "Write a note."})
          ])

        counts(request, "await_task") == 0 ->
          reply([FakeLLM.tool_call("a1", "await_task", %{"task_id" => spawned(request)})])

        true ->
          reply([Message.text("Checked.")])
      end
    end

    child_turn = fn request ->
      if after_tools?(request) do
        reply([Message.text("Done.")])
      else
        [%{child_id: child}] = Elia.Tasks.active()
        send(test_pid, {:child, child})
        child_path = Deploy.worktree_path(child)
        File.write!(Path.join(child_path, "child-note.txt"), "child")
        File.write!(Path.join(child_path, "wip.txt"), "wip")
        LiveTree.commit(child_path, "child note")

        reply([
          FakeLLM.tool_call("f1", "finish_task", %{"status" => "blocked", "summary" => "stuck"})
        ])
      end
    end

    queue(router(parent_turn, child_turn))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    assert_receive {:child, child}
    child_path = Deploy.worktree_path(child)

    # SUBTASK-25: a blocked sub-task is not merged, so the parent's worktree is
    # untouched and the work stays on the child's branch.
    assert File.read!(Path.join(child_path, "child-note.txt")) == "child"
    refute File.exists?(Path.join(path, "child-note.txt"))
    assert head(path) != head(child_path)
    assert branch(child_path) == "chat/#{child}"

    stop_session(child)
  end

  # DEPLOY-4, PROJ-22
  test "the file explorer browses the live tree for Elia's own project", %{tree: tree} do
    assert {:ok, entries} = Explorer.list("", Projects.harness().folder)
    assert Enum.any?(entries, &(&1.name == "mix.exs"))
    assert Explorer.read("mix.exs", Projects.harness().folder) |> elem(0) == :ok
    assert Projects.harness().folder == tree
  end

  # DEPLOY-8, DEPLOY-11
  test "a request never reloads code, and there is no guarded-file list" do
    assert Deploy.reload(EliaWeb.Endpoint, []) == :ok
    assert Deploy.reload(EliaWeb.Endpoint) == :ok
    refute Code.ensure_loaded?(Elia.Guarded)
  end

  # ISOL-1, ISOL-6, ISOL-13: the harness's own git calls go through
  # `Elia.Shell.run/2` too, so with the host allowing the jail they run jailed.
  # A chat's worktree is created *inside* the live tree's data dir, which the
  # `:live_tree` profile masks (ISOL-6), so those calls run under the profile
  # whose bind list leaves the live tree reachable (ISOL-13) — under the masked
  # one, git reports success and the worktree is written into the mask and lost.
  @tag skip: @jail_skip
  test "a chat's worktree is created and removed with the jail on", %{tree: tree} do
    with_jail(fn ->
      {id, path} = new_worktree()

      assert path == Path.join([tree, ".elia", "worktrees", id])
      assert File.dir?(path)
      assert File.exists?(Path.join(path, "mix.exs"))
      assert branch(path) == "chat/#{id}"
      assert head(path) == trunk(tree)

      assert :ok = Deploy.remove_worktree(id)
      refute File.exists?(path)
    end)
  end

  # ISOL-1, ISOL-12: on a host where the jail is wanted and bubblewrap is
  # missing, every command says the jail was skipped (ISOL-12) — and the deploy's
  # git calls read git's own output from below that notice, so the live tree
  # isn't mistaken for a dirty one and a deploy still works.
  test "the deploy's git calls go through Elia.Shell, so a missing jail doesn't corrupt them", %{
    tree: tree
  } do
    {_id, path} = new_worktree()
    work_on_trunk(path)

    with_jail([bwrap: "/nonexistent/bwrap"], fn ->
      refute Elia.Shell.available?()

      assert Deploy.deployable() == :ok
      assert {:ok, %{pending: 1}} = Deploy.status()

      before = head(tree)
      assert {:ok, message} = Deploy.deploy()
      assert message =~ "merged into live"
      assert head(tree) != before
    end)
  end

  # ISOL-14, ISOL-15, DEPLOY-5: the deploy's suite run is jailed, and no chat's
  # setting is involved — a caller with no chat gets the default, which is on.
  # Here the host wants the jail but has no bubblewrap, so the run says it was
  # skipped (ISOL-12): the notice can only come from a run that asked for the
  # jail. A failing suite still aborts the deploy and the user sees its output.
  test "the deploy's suite run is jailed, and a failure still aborts the deploy", %{tree: tree} do
    {_id, path} = new_worktree()

    File.write!(Path.join(path, "test/broken_test.exs"), """
    defmodule BrokenTest do
      use ExUnit.Case

      test "fails" do
        assert false
      end
    end
    """)

    commit(path, "broken")
    LiveTree.push_to_trunk(path)

    live = head(tree)

    with_jail([bwrap: "/nonexistent/bwrap"], fn ->
      refute Elia.Shell.available?()
      assert {:tests_failed, output} = Deploy.deploy()

      assert output =~ "[jail: skipped, bubblewrap is unavailable]"
      assert output =~ "1 failure"
      assert head(tree) == live
      refute File.exists?(Path.join(tree, "test/broken_test.exs"))
    end)
  end

  # ISOL-14: with the host allowing the jail, the merged trunk's suite really
  # runs in the live tree, jailed — the live tree is writable inside it.
  @tag skip: @jail_skip
  test "the merged trunk's suite runs jailed in the live tree", %{tree: tree} do
    {_id, path} = new_worktree()
    work_on_trunk(path)

    with_jail(fn ->
      assert Elia.Shell.available?()

      assert {:ok, message} = Deploy.deploy()
      assert message =~ "merged into live"
    end)

    assert head(tree) == trunk(tree)
  end
end
