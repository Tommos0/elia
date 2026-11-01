defmodule Elia.DeploymentTest do
  use ExUnit.Case, async: false

  alias Elia.{Agent, Deploy, Explorer, FakeLLM, LiveTree, Projects, Store, Workspace}
  alias Elia.LLM.Message

  @moduletag timeout: 120_000

  # The live tree these tests run against: a tiny git repo on branch `live`,
  # holding a one-module Mix project, so a deploy's `mix test` runs for real
  # (DEPLOY-5).
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

    :ok
  end

  ## Helpers

  defp head(dir), do: LiveTree.head(dir)
  defp branch(dir), do: LiveTree.branch(dir)
  defp commit(dir, message), do: LiveTree.commit(dir, message)
  defp chat_work!(path), do: LiveTree.work!(path)
  defp git(dir, args), do: LiveTree.git(dir, args)

  # A chat's worktree, from `live`, removed again at the end of the test.
  defp new_worktree do
    id = Agent.new_id()
    assert {:ok, path} = Deploy.ensure_worktree(id)
    on_exit(fn -> Deploy.remove_worktree(id) end)
    {id, path}
  end

  # DEPLOY-1: the file tools, checkpoints and verification of a chat in Elia's
  # own project work in its own worktree, not in the tree the server runs from.
  defp chat do
    id = Agent.new_id()

    {:ok, pid} =
      Agent.ensure_started(id,
        project: Projects.harness(),
        loop_opts: [llm: %{provider: FakeLLM}]
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

  defp dev_server do
    previous = Application.get_env(:elia, EliaWeb.Endpoint)
    Application.put_env(:elia, EliaWeb.Endpoint, Keyword.put(previous, :code_reloader, true))
    on_exit(fn -> Application.put_env(:elia, EliaWeb.Endpoint, previous) end)
  end

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
    # (no `live` branch, DEPLOY-1) works in the live tree itself.
    other_live = Path.join(System.tmp_dir!(), "elia-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(other_live)
    on_exit(fn -> File.rm_rf!(other_live) end)
    Application.put_env(:elia, :runtime_root, other_live)

    assert {:error, message} = Deploy.ensure_worktree(id)
    assert message =~ "not on the branch live"
    assert Deploy.workspace(Projects.harness(), id) == other_live
    refute File.exists?(Deploy.worktree_path(id))
  end

  # DEPLOY-1
  test "a chat's worktree is on its own branch, forked from live", %{tree: tree} do
    {id, path} = new_worktree()

    assert path == Path.join([tree, ".elia", "worktrees", id])
    assert branch(path) == "chat/#{id}"
    # Forked from `live`, so it has the live tree's committed files.
    assert head(path) == head(tree)
    assert File.exists?(Path.join(path, "mix.exs"))

    # Asking again keeps the worktree, and the work in it (DEPLOY-10).
    File.write!(Path.join(path, "notes.txt"), "wip")
    assert {:ok, ^path} = Deploy.ensure_worktree(id)
    assert File.read!(Path.join(path, "notes.txt")) == "wip"
  end

  # DEPLOY-1, PROJ-12
  test "a chat's tools work in its own worktree, not in the live tree", %{tree: tree} do
    id = chat()
    path = Deploy.worktree_path(id)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("w1", "write_file", %{"path" => "skills/note.txt", "content" => "here"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Written.")]))

    :ok = Agent.send_message(id, "write a note")
    await_status(id, :idle)

    assert File.read!(Path.join(path, "skills/note.txt")) == "here"
    refute File.exists?(Path.join(tree, "skills/note.txt"))
  end

  # DEPLOY-5
  test "a deploy runs the tests in the worktree, then fast-forwards live", %{tree: tree} do
    {_id, path} = new_worktree()
    file = chat_work!(path)

    before = head(tree)
    assert {:ok, message} = Deploy.deploy(path)

    assert message =~ "merged into live"
    assert head(tree) != before
    assert head(tree) == head(path)
    # The code is in the live tree now, and the running app is unchanged until a
    # deploy loads it (DEPLOY-8).
    assert File.exists?(Path.join(tree, file))
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

    live = head(tree)
    assert {:tests_failed, output} = Deploy.deploy(path)
    assert output =~ "1 failure"
    assert head(tree) == live
    refute File.exists?(Path.join(tree, "test/broken_test.exs"))
  end

  # DEPLOY-5
  test "a deploy is fast-forward only: a rebase is needed first", %{tree: tree} do
    {id, path} = new_worktree()
    chat_work!(path)

    # The live tree moves on after the chat forked, so the branch has diverged
    # and the merge can't be a fast-forward.
    File.write!(Path.join(tree, "lib/other.ex"), "defmodule Other do\nend\n")
    live = commit(tree, "another chat merged first")

    assert {:error, message} = Deploy.merge(path)
    assert message =~ "fast-forward only"
    assert message =~ "chat/#{id}"
    assert head(tree) == live
  end

  # DEPLOY-6, HOT-5
  test "hot reload runs the tests, merges, then reloads the running app", %{tree: tree} do
    dev_server()
    {_id, path} = new_worktree()
    file = chat_work!(path)

    before = head(tree)
    assert {:ok, message} = Elia.Harness.hot_reload(nil, path)

    assert message =~ "merged into live"
    assert message =~ "Recompiled and reloaded"
    assert head(tree) != before
    assert File.exists?(Path.join(tree, file))
  end

  # DEPLOY-6, HOT-2
  test "hot reload is only available when the dev server runs", %{tree: tree} do
    {_id, path} = new_worktree()
    chat_work!(path)

    before = head(tree)
    assert {:error, message} = Elia.Harness.hot_reload(nil, path)
    assert message =~ "only available when running the dev server"
    assert head(tree) == before
  end

  # DEPLOY-7, RESTART-11, RESTART-1, RESTART-2
  test "the restart button merges and restarts the server on a non-zero status", %{tree: tree} do
    dev_server()
    test_pid = self()
    Application.put_env(:elia, Elia.Deploy, stop: &send(test_pid, {:stop, &1}))
    on_exit(fn -> Application.delete_env(:elia, Elia.Deploy) end)

    {_id, path} = new_worktree()
    chat_work!(path)

    before = head(tree)
    assert {:ok, message} = Deploy.restart(path)

    # A non-zero status is what makes `bin/serve` start the server again.
    assert_receive {:stop, status}
    assert status != 0
    assert message =~ "merged into live"
    assert head(tree) != before
  end

  # DEPLOY-7, RESTART-2
  test "the restart button refuses when nothing would bring the server back", %{tree: tree} do
    {_id, path} = new_worktree()
    chat_work!(path)

    before = head(tree)
    assert {:error, message} = Deploy.restart(path)
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

  # DEPLOY-9, SUBTASK-23
  test "a sub-task works in its parent's worktree and branch", %{tree: tree} do
    parent = chat()
    path = Deploy.worktree_path(parent)
    test_pid = self()

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("s1", "spawn_task", %{"title" => "T", "brief" => "Write a note."})
      ])
    )

    # The child writes its note where its own tools put it — its workspace.
    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:child, Elia.Tasks.active().child_id})

      {:ok,
       %{
         message:
           FakeLLM.assistant([
             FakeLLM.tool_call("w1", "write_file", %{
               "path" => "skills/child-note.txt",
               "content" => "child"
             }),
             FakeLLM.tool_call("f1", "finish_task", %{"status" => "done", "summary" => "wrote it"})
           ]),
         stop_reason: :tool_use,
         model: "fake",
         usage: %{}
       }}
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Closing.")]))
    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    :ok = Agent.send_message(parent, "go")
    await_status(parent, :awaiting_approval)
    :ok = Agent.approve(parent, "s1")
    await_status(parent, :idle)

    assert_receive {:child, child}

    # The child's work is in the parent's worktree, on the parent's branch.
    assert File.read!(Path.join(path, "skills/child-note.txt")) == "child"
    refute File.exists?(Path.join(tree, "skills/child-note.txt"))
    assert branch(path) == "chat/#{parent}"

    # And its result is reported relative to that workspace.
    result =
      FakeLLM.requests()
      |> Enum.flat_map(& &1.messages)
      |> Enum.find_value(fn
        %Message{role: :tool, content: [%{tool_call_id: "s1"} = result]} -> result
        _message -> nil
      end)

    assert %{content: content, is_error: false} = result
    assert %{"status" => "done", "files" => files} = Jason.decode!(content)
    assert "skills/child-note.txt" in files
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
end
