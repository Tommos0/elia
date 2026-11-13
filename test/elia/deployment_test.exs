defmodule Elia.DeploymentTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, Deploy, Explorer, FakeLLM, LiveTree, Projects, Store, Workspace}
  alias Elia.Deploy.Runner
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

    # DEPLOY-16: the runner belongs to Elia's application and every case here
    # shares it, so a case starts with no operation in flight and no result.
    settle_runner()

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

  # Build output in the live tree, the way a real one has it (BUILD-1).
  defp seed_build(tree, path) do
    file = Path.join([tree, "_build", path])
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "beam")
  end

  # `mix compile` in a tree, as a command runs it (BUILD-2, BUILD-4).
  defp compile(dir) do
    System.cmd("mix", ["compile"], cd: dir, env: [{"MIX_ENV", "dev"}], stderr_to_stdout: true)
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

  # The deploy's front-end step (DEPLOY-19), replaced for a test the way `load:`
  # and `stop:` are: the real one installs the trunk's Node packages and builds
  # the live tree's assets, which a test doesn't run in its throwaway tree.
  defp stub_front_end(fun) do
    deploy = Application.get_env(:elia, Elia.Deploy, [])
    Application.put_env(:elia, Elia.Deploy, Keyword.put(deploy, :front_end, fun))
    on_exit(fn -> Application.put_env(:elia, Elia.Deploy, deploy) end)
  end

  # A front-end step that rebuilt, saying so the way the real one does, and
  # telling the test it ran.
  defp rebuilt_front_end(test_pid) do
    stub_front_end(fn root ->
      send(test_pid, {:front_end, root})
      {:ok, " The live tree's front end was rebuilt."}
    end)
  end

  # What the deploy's own steps said, in the order they ran: the front-end step
  # (DEPLOY-19) and the load are stubs in these tests and send to the test
  # process, so the mailbox is that order.
  defp deploy_steps do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.filter(messages, fn
      {:front_end, _root} -> true
      :loaded -> true
      _other -> false
    end)
  end

  ## The steps, the record and going back (DEPLOY-21 to DEPLOY-26)

  # A case starts with no operation in flight: wait out one a failed case may
  # have left behind (DEPLOY-16), then forget the last result. It subscribes
  # only when there is one to wait for, since a second subscription would make
  # every event arrive twice.
  defp settle_runner(timeout \\ 120_000) do
    if Runner.running() do
      Runner.subscribe()
      assert_receive {:deploy_finished, _}, timeout
    end

    Runner.reset()
    :ok
  end

  # The operation started in the runner ending (DEPLOY-15): what it returned.
  defp await_deploy(timeout \\ 120_000) do
    assert_receive {:deploy_finished, %{result: result}}, timeout
    result
  end

  # The steps the runner reported, in the order it reported them (DEPLOY-21).
  defp deploy_progress do
    {:messages, messages} = Process.info(self(), :messages)
    for {:deploy_progress, %{step: step, phase: phase}} <- messages, do: {step, phase}
  end

  # A live tree with a front end (DEPLOY-19, DEPLOY-24): an `assets/package.json`
  # and the bundle a browser loads, committed with the tree, so a deploy's own
  # front-end steps run — stubbed here, since a test installs no Node packages.
  defp front_end_tree do
    tree = LiveTree.create(front_end: true)
    Application.put_env(:elia, :runtime_root, tree)
    on_exit(fn -> LiveTree.remove(tree) end)
    tree
  end

  # The front-end step of an operation: the two things it does are seams, like
  # the whole of it (`config :elia, Elia.Deploy, packages: fun, assets: fun`).
  defp stub_step(name, fun) do
    deploy = Application.get_env(:elia, Elia.Deploy, [])
    Application.put_env(:elia, Elia.Deploy, Keyword.put(deploy, name, fun))
    on_exit(fn -> Application.put_env(:elia, Elia.Deploy, deploy) end)
  end

  # A deploy run in the runner, waited out, for a test that only needs the
  # revision it loaded and not the steps of the deploy itself.
  defp reload_now do
    assert :ok = Runner.start(:reload)
    assert_receive {:packages, operation}, 120_000
    send(operation, :continue)
    assert {:ok, _message} = await_deploy()
    assert_receive :loaded
    :ok
  end

  # Forgets the messages a test is done with, so what it looks at next is only
  # what happened after.
  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end

  # A front end that installs and builds, telling the test it ran, and writing
  # nothing: the bundle the tree already has is what DEPLOY-24 checks.
  defp build_front_end_with(test_pid) do
    stub_step(:packages, fn root ->
      send(test_pid, {:packages, root})
      {:ok, ""}
    end)

    stub_step(:assets, fn root ->
      send(test_pid, {:assets, root})
      {:ok, ""}
    end)
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

  # A test that runs the deploy's own front-end step for real skips where npm is
  # missing (DEPLOY-19), as the jail's tests skip where bubblewrap is.
  @npm_skip if(System.find_executable("npm"), do: false, else: "npm is not installed")

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

  # EXPL-17, FLINK-5: resolving the workspace a chat works in creates nothing —
  # the Files page and a file link read it, so a read must not fork a branch —
  # and it is the same answer the chat's own tools get (PROJ-12).
  test "resolving a chat's workspace creates no worktree", %{tree: tree} do
    id = Agent.new_id()
    project = Projects.harness()

    assert Deploy.existing_workspace(project, id) == tree
    assert Deploy.existing_workspace(project, nil) == tree
    refute File.dir?(Deploy.worktree_path(id))

    {id, path} = new_worktree()
    assert Deploy.existing_workspace(project, id) == path
    assert Deploy.existing_workspace(project, id) == Deploy.workspace(project, id)

    # A project without worktrees browses its folder (PROJ-12).
    assert Deploy.existing_workspace(%{id: "o", name: "O", folder: tree, harness?: false}, id) ==
             tree
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

  # BUILD-1: creating a worktree seeds it with the live tree's build output, so
  # its first compile reuses the dependencies' artifacts instead of building
  # them from source.
  test "a new worktree is seeded with the live tree's build output (BUILD-1)", %{tree: tree} do
    seed_build(tree, "dev/lib/req/ebin/Elixir.Req.beam")

    {_id, path} = new_worktree()

    assert File.read!(Path.join([path, "_build", "dev/lib/req/ebin/Elixir.Req.beam"])) == "beam"
  end

  # BUILD-1: taken once, when the worktree is created — a worktree that already
  # exists keeps the build output it has.
  test "seeding happens once, with the worktree (BUILD-1)", %{tree: tree} do
    seed_build(tree, "dev/lib/req/ebin/Elixir.Req.beam")
    {id, path} = new_worktree()
    beam = Path.join([path, "_build", "dev/lib/req/ebin/Elixir.Req.beam"])

    File.write!(Path.join([tree, "_build", "dev/lib/req/ebin/Elixir.Req.beam"]), "rebuilt")
    assert {:ok, ^path} = Deploy.ensure_worktree(id)

    assert File.read!(beam) == "beam"
  end

  # BUILD-2: the copy is the worktree's own, so nothing a chat compiles reaches
  # the live tree's build output — the artifacts the running server runs from.
  test "a worktree's build output is its own copy (BUILD-2)", %{tree: tree} do
    seed_build(tree, "dev/lib/req/ebin/Elixir.Req.beam")
    {_id, path} = new_worktree()

    File.write!(Path.join([path, "_build", "dev/lib/req/ebin/Elixir.Req.beam"]), "worktree")

    assert File.read!(Path.join([tree, "_build", "dev/lib/req/ebin/Elixir.Req.beam"])) == "beam"
  end

  # BUILD-3, BUILD-5: seeding is a copy, not a compile, and a live tree with no
  # build output gives a worktree with none — the worktree is still created and
  # the command that needed it runs as it does today.
  test "a live tree with no build output still gives a worktree (BUILD-3, BUILD-5)", %{tree: tree} do
    refute File.exists?(Path.join(tree, "_build"))

    {_id, path} = new_worktree()

    refute File.exists?(Path.join(path, "_build"))
    assert branch(path) == "chat/" <> Path.basename(path)
  end

  # BUILD-6: the seeded copy lives inside the worktree, so it goes with it.
  test "removing a worktree takes its seeded build output with it (BUILD-6)", %{tree: tree} do
    seed_build(tree, "dev/lib/req/ebin/Elixir.Req.beam")
    {id, path} = new_worktree()
    assert File.dir?(Path.join(path, "_build"))

    Deploy.remove_worktree(id)

    refute File.exists?(path)
  end

  # BUILD-2, BUILD-4: a command that compiles in a worktree writes only the
  # worktree's own build output — the live tree's is left as it was — and a
  # module the worktree changed is compiled there, from the worktree's sources.
  test "a worktree compiles on its own build output (BUILD-2, BUILD-4)", %{tree: tree} do
    assert {_, 0} = compile(tree)
    live_beam = Path.join([tree, "_build", "dev/lib/deploy_tmp/ebin/Elixir.DeployTmp.beam"])
    live = File.read!(live_beam)

    {_id, path} = new_worktree()
    assert File.exists?(Path.join(path, "_build/dev/lib/deploy_tmp/ebin/Elixir.DeployTmp.beam"))

    File.write!(Path.join(path, "lib/deploy_tmp.ex"), """
    defmodule DeployTmp do
      def hello, do: :changed
    end
    """)

    assert {_, 0} = compile(path)

    worktree_beam = Path.join([path, "_build", "dev/lib/deploy_tmp/ebin/Elixir.DeployTmp.beam"])
    assert File.read!(live_beam) == live
    refute File.read!(worktree_beam) == live
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

  # DEPLOY-19: the tree's front end is made current once the suite has passed,
  # before anything loads the tree, and the deploy says so — what a browser loads
  # is what the tree it just deployed says, rather than a bundle from before the
  # change.
  test "a deploy rebuilds the live tree's front end before it loads it (DEPLOY-19)", %{
    tree: tree
  } do
    running_server()
    rebuilt_front_end(self())

    {_id, path} = new_worktree()
    work_on_trunk(path)

    assert {:ok, message} = Deploy.hot_reload()
    assert message =~ "front end was rebuilt"

    # The order the deploy's own steps ran in: the front end, then the load.
    assert [{:front_end, ^tree}, :loaded] = deploy_steps()
  end

  # DEPLOY-19: nothing is rebuilt when the deploy never reaches that step — a
  # failed suite already means nothing is deployed (DEPLOY-5, HOT-4).
  test "a deploy whose suite fails rebuilds no front end (DEPLOY-19)" do
    running_server()
    rebuilt_front_end(self())

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

    assert {:tests_failed, _output} = Deploy.hot_reload()
    assert deploy_steps() == []
  end

  # DEPLOY-19: a front end that can't be built is a deploy failure like a failing
  # suite: `live` is rolled back to where it was, and nothing is loaded.
  test "a front end that can't be built deploys nothing (DEPLOY-19)", %{tree: tree} do
    running_server()
    stub_front_end(fn _root -> {:error, "npm install exited with 1"} end)

    {_id, path} = new_worktree()
    work_on_trunk(path)

    live = head(tree)
    assert {:error, message} = Deploy.hot_reload()

    assert message =~ "Could not build the live tree's front end (DEPLOY-19)"
    assert message =~ "npm install exited with 1"
    assert head(tree) == live
    assert branch(tree) == "live"
    assert deploy_steps() == []
  end

  # DEPLOY-19: a tree with no front end has nothing to install and nothing to
  # build, and its deploy says nothing about one.
  test "a live tree with no front end is deployed without building one (DEPLOY-19)", %{
    tree: tree
  } do
    refute File.exists?(Path.join(tree, "assets/package.json"))

    {_id, path} = new_worktree()
    work_on_trunk(path)

    assert {:ok, message} = Deploy.deploy()
    refute message =~ "front end"
  end

  # DEPLOY-19: the real step runs in the live tree, and the command that fails is
  # the one the error names — here a `package.json` npm can't read, so nothing is
  # installed and nothing is deployed.
  test "a front end whose Node packages can't be installed fails the deploy (DEPLOY-19)", %{
    tree: tree
  } do
    {_id, path} = new_worktree()

    File.mkdir_p!(Path.join(path, "assets"))
    File.write!(Path.join(path, "assets/package.json"), "{ not json\n")
    commit(path, "a front end whose packages can't be installed")
    LiveTree.push_to_trunk(path)

    live = head(tree)
    assert {:error, message} = Deploy.deploy()

    assert message =~ "Could not build the live tree's front end (DEPLOY-19)"
    assert message =~ "npm install --prefix assets --no-audit --no-fund exited with 1"
    assert head(tree) == live
    assert branch(tree) == "live"
  end

  # DEPLOY-19: the install is the step before the build, and the one that fails
  # is the one reported. The tree has no `assets.build` to run, which is what a
  # tree whose assets can't be built looks like to the deploy.
  @tag skip: @npm_skip
  test "a front end whose assets can't be built fails the deploy (DEPLOY-19)", %{tree: tree} do
    {_id, path} = new_worktree()

    File.mkdir_p!(Path.join(path, "assets"))
    File.write!(Path.join(path, "assets/package.json"), ~s({"name": "tmp", "private": true}\n))
    commit(path, "a front end with nothing to build it")
    LiveTree.push_to_trunk(path)

    live = head(tree)
    assert {:error, message} = Deploy.deploy()

    assert message =~ "Could not build the live tree's front end (DEPLOY-19)"
    assert message =~ "mix assets.build exited with"
    assert head(tree) == live
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

  # DEPLOY-20, DEPLOY-19: with nothing to merge no suite runs (DEPLOY-5), but the
  # live tree's front end is still made current before the load — what a deploy
  # loads is what the tree it loads builds — and the deploy says it rebuilt it.
  test "a deploy with nothing to merge still rebuilds the live tree's front end (DEPLOY-20)",
       %{tree: tree} do
    running_server()
    rebuilt_front_end(self())

    assert {:ok, %{pending: 0}} = Deploy.status()
    assert {:ok, message} = Deploy.hot_reload()

    assert message =~ "Nothing to deploy"
    assert message =~ "front end was rebuilt"

    # The front end first, then the load: the order DEPLOY-19 and DEPLOY-20 ask
    # for.
    assert [{:front_end, ^tree}, :loaded] = deploy_steps()
  end

  # DEPLOY-20: a front end that can't be built fails a deploy with nothing to
  # merge the way it fails one that merged (DEPLOY-19): nothing is loaded.
  test "a front end that can't be built deploys nothing when there is nothing to merge (DEPLOY-20)",
       %{tree: tree} do
    running_server()
    stub_front_end(fn _root -> {:error, "npm install exited with 1"} end)

    live = head(tree)
    assert {:error, message} = Deploy.hot_reload()

    assert message =~ "Could not build the live tree's front end (DEPLOY-19)"
    assert message =~ "npm install exited with 1"
    assert head(tree) == live
    assert branch(tree) == "live"
    assert deploy_steps() == []
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
    # HOT-10: this reload changed no supervised process, so it says nothing
    # about a restart.
    assert message =~ "Recompiled and reloaded"
    refute message =~ "restart"
  end

  # HOT-10
  test "a reload names the supervised processes only a restart starts or stops" do
    running_server()

    # What the server is running is what the loaded code asks for, so a reload
    # has nothing to warn about — and this is also what holds the one child list
    # (`Elia.Application.children/0`) to the tree that was started.
    assert Deploy.changed_children() == %{missing: [], extra: []}
    assert Deploy.restart_notice() == ""

    # A process a deploy adds is not running: a reload cannot start it, so it is
    # named (DEPLOY-6, DEPLOY-7).
    added = {Registry, keys: :unique, name: Elia.Test.Registry.Never}
    changes = Deploy.changed_children([added | Elia.Application.children()])
    assert changes == %{missing: [Elia.Test.Registry.Never], extra: []}
    assert Deploy.restart_notice(changes) =~ "Not running: Elia.Test.Registry.Never"

    # And one the code no longer asks for keeps running until a restart stops it.
    removed = List.delete(Elia.Application.children(), Elia.Push.Viewers)
    changes = Deploy.changed_children(removed)
    assert changes == %{missing: [], extra: [Elia.Push.Viewers]}
    assert Deploy.restart_notice(changes) =~ "Still running"
    assert Deploy.restart_notice(changes) =~ "Elia.Push.Viewers"
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

  ## What a deploy is doing (DEPLOY-21 to DEPLOY-23)

  # DEPLOY-21: one place names a step, so the two pages that render them cannot
  # disagree about the wording.
  test "a step has one short label (DEPLOY-21)" do
    assert Deploy.step_label(:tests) == "Running the tests in the live tree"

    for step <- [:merge, :deps, :tests, :packages, :assets, :front_end, :reset, :load, :restart] do
      assert is_binary(Deploy.step_label(step))
      assert String.length(Deploy.step_label(step)) > 5
    end
  end

  # DEPLOY-21, DEPLOY-22: a deploy reports each step as it takes it, in the
  # order the code takes them, and the runner holds them.
  test "a deploy reports its steps in the order it takes them (DEPLOY-21)" do
    running_server()
    front_end_tree()
    build_front_end_with(self())

    {_id, path} = new_worktree()
    work_on_trunk(path)

    Runner.subscribe()
    assert :ok = Runner.start(:reload)
    assert_receive {:deploy_started, %{mode: :reload}}, 5_000
    assert {:ok, message} = await_deploy()
    assert message =~ "front end was rebuilt"

    assert deploy_progress() == [
             {:merge, :started},
             {:merge, :finished},
             {:deps, :started},
             {:deps, :finished},
             {:tests, :started},
             {:tests, :finished},
             {:packages, :started},
             {:packages, :finished},
             {:assets, :started},
             {:assets, :finished},
             {:load, :started},
             {:load, :finished}
           ]

    # Every step it reported has a label a page can render.
    for {step, _phase} <- deploy_progress(), do: assert(Deploy.step_label(step) != "")
  end

  # DEPLOY-21: a step that is never reached is never reported, so what a deploy
  # reports says where it stopped — and each step says how it went.
  test "a deploy that stops at the tests reports no step after them (DEPLOY-21)" do
    running_server()
    tree = front_end_tree()
    build_front_end_with(self())

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

    before = head(tree)
    Runner.subscribe()
    assert :ok = Runner.start(:reload)
    assert {:tests_failed, output} = await_deploy()
    assert output =~ "1 failure"

    assert deploy_progress() == [
             {:merge, :started},
             {:merge, :finished},
             {:deps, :started},
             {:deps, :finished},
             {:tests, :started},
             {:tests, :finished}
           ]

    # DEPLOY-22: the runner keeps the steps that finished, with how long each
    # took and whether it succeeded.
    assert %{running: nil, last: %{steps: steps}} = Runner.state()
    assert Enum.map(steps, & &1.step) == [:merge, :deps, :tests]
    assert [%{status: :ok}, %{status: :ok}, %{status: {:failed, _}}] = steps
    assert Enum.all?(steps, &is_integer(&1.ms))

    # Nothing is deployed (DEPLOY-5).
    assert head(tree) == before
  end

  # DEPLOY-21: with nothing to merge no suite runs, so those steps are not
  # reported either (DEPLOY-5, DEPLOY-20).
  test "a deploy with nothing to merge reports only the steps it takes (DEPLOY-21)" do
    running_server()
    front_end_tree()
    build_front_end_with(self())

    Runner.subscribe()
    assert :ok = Runner.start(:reload)
    assert {:ok, message} = await_deploy()
    assert message =~ "Nothing to deploy"

    assert deploy_progress() == [
             {:packages, :started},
             {:packages, :finished},
             {:assets, :started},
             {:assets, :finished},
             {:load, :started},
             {:load, :finished}
           ]
  end

  # DEPLOY-22, DEPLOY-23: the runner holds the step in flight, and the record on
  # disk says what the operation is doing while it does it — so an operation the
  # VM dies under leaves a record that has not finished.
  test "the runner holds the step in flight, and the record is written as it goes (DEPLOY-22, DEPLOY-23)" do
    running_server()
    tree = front_end_tree()
    test_pid = self()

    # The install waits here, so the test can look at the operation mid-flight.
    stub_step(:packages, fn _root ->
      send(test_pid, {:packages, self()})

      receive do
        :continue -> {:ok, ""}
      after
        30_000 -> {:ok, ""}
      end
    end)

    stub_step(:assets, fn _root -> {:ok, ""} end)

    {_id, path} = new_worktree()
    work_on_trunk(path)

    Runner.subscribe()
    assert :ok = Runner.start(:reload)
    assert_receive {:packages, operation}, 120_000

    # DEPLOY-22: the runner knows the step it is on and the ones that finished.
    assert %{running: running, last: nil} = Runner.state()
    assert running.kind == :deploy
    assert running.mode == :reload
    assert running.step == :packages
    assert Enum.map(running.steps, & &1.step) == [:merge, :deps, :tests]
    assert Enum.all?(running.steps, &(&1.status == :ok and is_integer(&1.ms)))
    assert %DateTime{} = running.started

    # DEPLOY-23: and so does the record, which outlives this process.
    assert %{
             kind: :deploy,
             mode: :reload,
             sha: nil,
             step: :packages,
             finished: nil,
             result: nil,
             started: %DateTime{},
             steps: steps
           } = Deploy.last_deploy()

    assert Enum.map(steps, & &1.step) == [:merge, :deps, :tests]

    send(operation, :continue)
    assert {:ok, _message} = await_deploy()

    # It finished, so the record says so, and the revision it loaded is the one
    # the app runs now (DEPLOY-17).
    live = head(tree)

    assert %{kind: :deploy, sha: ^live, step: nil, finished: %DateTime{}, result: {:ok, _}} =
             Deploy.last_deploy()

    assert %{running: nil, last: %{steps: steps}} = Runner.state()
    assert Enum.map(steps, & &1.step) == [:merge, :deps, :tests, :packages, :assets, :load]
  end

  # DEPLOY-23, DEPLOY-25: the record keeps what the deploy did and the revisions
  # the app has run, newest first, each with how it was loaded.
  test "the record says what the deploy did, and which revision it loaded (DEPLOY-23)" do
    running_server()
    tree = front_end_tree()
    build_front_end_with(self())

    {_id, path} = new_worktree()
    work_on_trunk(path)

    Runner.subscribe()
    assert :ok = Runner.start(:reload)
    assert {:ok, message} = await_deploy()
    assert_receive :loaded

    live = head(tree)

    assert %{
             kind: :deploy,
             mode: :reload,
             sha: ^live,
             step: nil,
             started: %DateTime{},
             finished: %DateTime{},
             result: {:ok, ^message},
             steps: steps
           } = Deploy.last_deploy()

    assert Enum.map(steps, & &1.step) == [:merge, :deps, :tests, :packages, :assets, :load]
    assert Enum.all?(steps, &(&1.status == :ok and is_integer(&1.ms)))

    # DEPLOY-25, DEPLOY-17: the revision it loaded is one the app has run, with
    # when and by what, and it is the revision `status/1` reports.
    assert [%{sha: ^live, at: %DateTime{}, by: :deploy, mode: :reload} | _older] =
             Deploy.loaded_revisions()

    assert Deploy.loaded_revision() == live
    assert {:ok, %{loaded: ^live, behind?: false}} = Deploy.status()
  end

  # DEPLOY-23: a record that is not there, or that cannot be read, reads as
  # nothing at all — a page renders it.
  test "a missing or corrupt record reads as nothing (DEPLOY-23)" do
    assert Deploy.last_deploy() == nil
    assert Deploy.loaded_revisions() == []

    File.mkdir_p!(Workspace.data_dir())
    File.write!(Deploy.record_path(), "{ this is not json")

    assert Deploy.last_deploy() == nil
    assert Deploy.loaded_revisions() == []

    # A record a page can read renders; a page never crashes on it.
    assert Deploy.last_deploy() == nil
  end

  # DEPLOY-25: the revisions the app has run are kept, newest first, so one it
  # has run and no longer is can still be gone back to (DEPLOY-26).
  test "the revisions the app has run are kept, newest first (DEPLOY-25)", %{tree: tree} do
    running_server()
    {_id, path} = new_worktree()

    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    first = head(tree)

    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    second = head(tree)

    assert second != first

    assert [
             %{sha: ^second, by: :deploy, mode: :reload},
             %{sha: ^first, by: :deploy, mode: :reload}
           ] =
             Deploy.loaded_revisions()

    # The newest is what the app reports it is running (DEPLOY-17).
    assert Deploy.loaded_revision() == second
    assert {:ok, %{loaded: ^second}} = Deploy.status()

    # And loading the same revision again does not list it twice.
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    assert [%{sha: ^second}, %{sha: ^first}] = Deploy.loaded_revisions()
  end

  # DEPLOY-25: a tree deployed before the record existed has the loaded revision
  # and nothing else, and that revision is still a rollback target.
  test "a tree with only the loaded-revision file still reports a revision to go back to (DEPLOY-25)",
       %{tree: tree} do
    running_server()
    {_id, path} = new_worktree()

    old = head(tree)
    assert :ok = Deploy.record_loaded()

    # The record is gone, the way a tree deployed by an older Elia has none.
    File.rm!(Deploy.record_path())
    assert Deploy.loaded_revision() == old
    assert [%{sha: ^old}] = Deploy.loaded_revisions()

    # A deploy loads a new revision, and the one before it is still a target.
    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    live = head(tree)

    assert [%{sha: ^live}, %{sha: ^old}] = Deploy.loaded_revisions()

    assert {:ok, message} = Deploy.rollback(old, :reload)
    assert message =~ "Rolled live back"
    assert head(tree) == old
  end

  ## The bundle a deploy loads (DEPLOY-24)

  # DEPLOY-24: a build that exits 0 having written nothing is a failed deploy,
  # not a running app with no hook: `live` is rolled back and nothing is loaded,
  # and the error names the file.
  test "a bundle the build did not write fails the deploy (DEPLOY-24)" do
    running_server()
    tree = front_end_tree()

    # A misconfigured `esbuild`, or a wiped `priv/static`: the build is happy and
    # the entry point the browser loads is gone.
    stub_step(:packages, fn _root -> {:ok, ""} end)

    stub_step(:assets, fn _root ->
      File.rm!(Path.join(tree, "priv/static/assets/js/app.js"))
      {:ok, ""}
    end)

    {_id, path} = new_worktree()
    file = work_on_trunk(path)
    live = head(tree)

    assert {:error, message} = Deploy.hot_reload()
    assert message =~ "Could not build the live tree's front end (DEPLOY-19)"
    assert message =~ "priv/static/assets/js/app.js"
    assert message =~ "DEPLOY-24"

    # Nothing is deployed, and the live tree is the one it was (DEPLOY-5).
    assert head(tree) == live
    assert branch(tree) == "live"
    refute File.exists?(Path.join(tree, file))
    refute_received :loaded
  end

  # DEPLOY-24: a bundle that is there but empty is no bundle either.
  test "an empty bundle fails the deploy (DEPLOY-24)" do
    running_server()
    tree = front_end_tree()

    stub_step(:packages, fn _root -> {:ok, ""} end)

    stub_step(:assets, fn _root ->
      File.write!(Path.join(tree, "priv/static/assets/css/app.css"), "")
      {:ok, ""}
    end)

    {_id, path} = new_worktree()
    work_on_trunk(path)
    live = head(tree)

    assert {:error, message} = Deploy.hot_reload()
    assert message =~ "priv/static/assets/css/app.css"
    assert head(tree) == live
    refute_received :loaded
  end

  ## Going back (DEPLOY-26)

  # DEPLOY-26: going back is a load, not a merge — `live` moves back with a
  # `git reset --hard`, that revision's front end is made current, and it is
  # loaded and recorded.
  test "a rollback moves live back, rebuilds the front end and loads it (DEPLOY-26)" do
    running_server()
    tree = front_end_tree()
    build_front_end_with(self())
    {_id, path} = new_worktree()

    first = head(tree)
    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    second = head(tree)

    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    third = head(tree)

    assert {:ok, message} = Deploy.rollback(second, :reload)
    assert message =~ "Rolled live back to #{String.slice(second, 0, 7)}"
    assert message =~ "front end was rebuilt"
    assert_receive :loaded

    assert head(tree) == second
    assert branch(tree) == "live"
    # The tree is behind the trunk again, so the section offers a deploy
    # (CONF-19).
    assert {:ok, %{pending: 1}} = Deploy.status()

    # DEPLOY-17, DEPLOY-25: what a rollback loaded is recorded as loaded by a
    # rollback.
    assert Deploy.loaded_revision() == second

    assert [%{sha: ^second, by: :rollback, mode: :reload}, %{sha: ^third} | _rest] =
             Deploy.loaded_revisions()

    refute first == second
  end

  # DEPLOY-15, DEPLOY-16, DEPLOY-21, DEPLOY-22: a rollback runs in the runner as
  # an operation of its own — one at a time, reporting its steps the way a
  # deploy does.
  test "the runner runs a rollback as an operation of its own (DEPLOY-26)" do
    running_server()
    tree = front_end_tree()
    test_pid = self()

    # The install waits for the test, so it can look at the operation mid-flight.
    stub_step(:packages, fn _root ->
      send(test_pid, {:packages, self()})

      receive do
        :continue -> {:ok, ""}
      after
        30_000 -> {:ok, ""}
      end
    end)

    stub_step(:assets, fn _root -> {:ok, ""} end)

    {_id, path} = new_worktree()
    Runner.subscribe()

    work_on_trunk(path)
    assert :ok = reload_now()
    first = head(tree)

    work_on_trunk(path)
    assert :ok = reload_now()
    second = head(tree)

    # What the test has settled is done with, so what it looks at next is the
    # rollback's own steps.
    flush_messages()

    assert :ok = Runner.rollback(first, :reload)
    assert_receive {:deploy_started, %{mode: :reload}}, 5_000
    assert_receive {:packages, operation}, 120_000

    # DEPLOY-16: a rollback is an operation, and only one runs at a time.
    assert Runner.rollback(first, :reload) == {:error, :busy}
    assert Runner.start(:reload) == {:error, :busy}

    # DEPLOY-22: the runner says which operation it is, and where it is.
    assert %{
             running: %{
               kind: :rollback,
               mode: :reload,
               sha: ^first,
               step: :packages,
               steps: [%{step: :reset, status: :ok}]
             }
           } = Runner.state()

    send(operation, :continue)
    assert {:ok, message} = await_deploy()
    assert message =~ "Rolled live back"
    assert head(tree) == first
    assert second != first

    assert deploy_progress() == [
             {:reset, :started},
             {:reset, :finished},
             {:packages, :started},
             {:packages, :finished},
             {:assets, :started},
             {:assets, :finished},
             {:load, :started},
             {:load, :finished}
           ]

    # DEPLOY-23: the record says it was a rollback, and where it went.
    assert %{kind: :rollback, mode: :reload, sha: ^first, result: {:ok, _}, finished: %DateTime{}} =
             Deploy.last_deploy()

    assert [%{sha: ^first, by: :rollback} | _rest] = Deploy.loaded_revisions()
  end

  # DEPLOY-25, DEPLOY-26: a rollback is refused, changing nothing, for a
  # revision the app has not run and for the one it is running now.
  test "a rollback refuses a revision the app has not run, or is running now (DEPLOY-26)",
       %{tree: tree} do
    running_server()
    {_id, path} = new_worktree()

    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    running = head(tree)

    # A commit that exists but was never loaded.
    work_on_trunk(path)
    never_loaded = trunk(tree)
    live = head(tree)

    assert {:error, message} = Deploy.rollback(never_loaded, :reload)
    assert message =~ "has not run"
    assert head(tree) == live
    refute_received :loaded

    # The revision it is running now: there is nothing to go back to.
    assert {:error, message} = Deploy.rollback(running, :reload)
    assert message =~ "nothing to go back to"
    assert head(tree) == live
  end

  # DEPLOY-5, DEPLOY-26: a rollback refuses a live tree with uncommitted changes
  # rather than resetting over them.
  test "a rollback refuses a live tree with uncommitted changes (DEPLOY-26)", %{tree: tree} do
    running_server()
    {_id, path} = new_worktree()

    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded
    first = head(tree)

    work_on_trunk(path)
    assert {:ok, _message} = Deploy.hot_reload()
    assert_receive :loaded

    File.write!(Path.join(tree, "lib/hand_edited.ex"), "defmodule HandEdited do\nend\n")
    live = head(tree)

    assert {:error, message} = Deploy.rollback(first, :reload)
    assert message =~ "uncommitted changes"
    assert head(tree) == live
    assert File.exists?(Path.join(tree, "lib/hand_edited.ex"))
    refute_received :loaded
  end

  # DEPLOY-14, DEPLOY-26: a tree that isn't set up for deployment is refused
  # before anything runs.
  test "a rollback refuses a live tree that isn't set up for deployment (DEPLOY-26)" do
    plain = Path.join(System.tmp_dir!(), "elia-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf!(plain) end)
    Application.put_env(:elia, :runtime_root, plain)

    assert {:error, message} = Deploy.rollback(String.duplicate("a", 40), :reload)
    assert message =~ "not on the branch live"
    assert File.ls!(plain) == []
  end

  # DEPLOY-24, DEPLOY-26: a rollback that fails once `live` has moved puts it
  # back where it was and loads nothing, so the tree it leaves is the one the
  # app is running.
  test "a rollback whose front end fails puts live back and loads nothing (DEPLOY-26)" do
    running_server()
    tree = front_end_tree()
    test_pid = self()

    # The build asks the test whether it should work, so the rollback's own
    # build can fail where the deploys' did not.
    stub_step(:packages, fn _root -> {:ok, ""} end)

    stub_step(:assets, fn _root ->
      send(test_pid, {:assets, self()})

      receive do
        :ok -> {:ok, ""}
        :fail -> {:error, "mix assets.build exited with 1"}
      after
        30_000 -> {:error, "the test did not answer"}
      end
    end)

    {_id, path} = new_worktree()

    Runner.subscribe()

    work_on_trunk(path)
    assert :ok = Runner.start(:reload)
    assert_receive {:assets, deploy}, 120_000
    send(deploy, :ok)
    assert {:ok, _message} = await_deploy()
    assert_receive :loaded
    first = head(tree)

    work_on_trunk(path)
    assert :ok = Runner.start(:reload)
    assert_receive {:assets, deploy}, 120_000
    send(deploy, :ok)
    assert {:ok, _message} = await_deploy()
    assert_receive :loaded
    second = head(tree)

    assert :ok = Runner.rollback(first, :reload)
    assert_receive {:assets, rollback}, 120_000
    send(rollback, :fail)

    assert {:error, message} = await_deploy()
    assert message =~ "Could not build the live tree's front end (DEPLOY-19)"
    assert message =~ "mix assets.build exited with 1"

    # `live` is back where it was, and nothing was loaded.
    assert head(tree) == second
    assert branch(tree) == "live"
    refute_received :loaded
    assert Deploy.loaded_revision() == second

    assert %{kind: :rollback, sha: ^first, result: {:error, _}, steps: steps} =
             Deploy.last_deploy()

    assert Enum.map(steps, & &1.step) == [:reset, :packages, :assets]
    assert [%{status: :ok}, %{status: :ok}, %{status: {:failed, _}}] = steps
  end

  # DEPLOY-23, DEPLOY-25: a restart deploy records the revision the server comes
  # back on, and how it loaded it, before the server stops (DEPLOY-17).
  test "a restart deploy records what it did before the server stops (DEPLOY-23)",
       %{tree: tree} do
    running_server()
    stop_server_with(self())
    {_id, path} = new_worktree()
    work_on_trunk(path)

    Runner.subscribe()
    assert :ok = Runner.start(:restart)
    assert {:ok, message} = await_deploy()
    assert message =~ "Restarting the server"
    assert_receive {:stop, status}
    assert status != 0

    live = head(tree)

    assert %{kind: :deploy, mode: :restart, sha: ^live, step: nil, steps: steps} =
             Deploy.last_deploy()

    assert List.last(steps).step == :restart
    assert [%{sha: ^live, by: :deploy, mode: :restart} | _rest] = Deploy.loaded_revisions()
  end
end
