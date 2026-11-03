defmodule Elia.DepsSyncTest do
  # ISOL-7: a chat worktree's `deps` is the live tree's, bound read-only for a
  # command that runs there (ISOL-13), so the harness keeps the shared tree
  # compiled itself, in the worktree, before a jailed command can need it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Elia.{Agent, DepsSync, Deploy, LiveTree, Projects, Shell, Workspace}

  # A `mix.lock` as a worktree of Elia's own project has one: the live tree's,
  # checked out with it (DEPLOY-1).
  @lock ~s(%{"phoenix": {:hex, :phoenix, "1.7.0"}}\n)

  setup do
    tree = LiveTree.create()
    previous_root = Application.get_env(:elia, :runtime_root)
    previous = Application.get_env(:elia, Elia.DepsSync, [])
    Application.put_env(:elia, :runtime_root, tree)

    # A real sync compiles the worktree's dependency tree. The tests record the
    # commands and answer them instead, and assert on those and on what is
    # remembered (`config :elia, Elia.DepsSync, run: fun`).
    test_pid = self()

    Application.put_env(:elia, Elia.DepsSync,
      run: fn command, opts ->
        send(test_pid, {:run, command, opts, self()})
        {:ok, "", 0}
      end
    )

    on_exit(fn ->
      Application.put_env(:elia, Elia.DepsSync, previous)
      LiveTree.remove(tree)

      if previous_root,
        do: Application.put_env(:elia, :runtime_root, previous_root),
        else: Application.delete_env(:elia, :runtime_root)
    end)

    %{tree: tree}
  end

  ## Helpers

  defp tree, do: Workspace.runtime_root()

  # A chat worktree of the live tree (DEPLOY-1), with a `mix.lock` when `lock`
  # is given.
  defp worktree(id \\ "w1", lock \\ @lock) do
    dir = Path.join([tree(), ".elia", "worktrees", id])
    File.mkdir_p!(dir)
    if lock, do: File.write!(Path.join(dir, "mix.lock"), lock)
    dir
  end

  # The syncs the harness ran, in order, since the last call:
  # `{command, opts, pid}`, where the pid is the sync's own process.
  defp synced do
    receive do
      {:run, command, opts, pid} -> [{command, opts, pid} | synced()]
    after
      0 -> []
    end
  end

  defp commands(ran), do: Enum.map(ran, &elem(&1, 0))

  defp options(ran, command) do
    Enum.find_value(ran, fn
      {^command, opts, _pid} -> opts
      _other -> nil
    end)
  end

  # A sync the test holds: it reports the command it is about to run and waits
  # for `release/1`, so the test knows it is still in flight — and a caller that
  # needs the same sync can't get past it. A real sync runs `mix deps.get` and
  # `mix deps.compile`, which no test may do (ISOL-7).
  defp hold_sync do
    test_pid = self()

    Application.put_env(:elia, Elia.DepsSync,
      run: fn command, opts ->
        send(test_pid, {:run, command, opts, self()})
        receive do: (:release -> {:ok, "", 0})
      end
    )
  end

  defp release(pid), do: send(pid, :release)

  # The sync runs in the background now, so a test waits for its task to end —
  # the pid the runner reported is the sync's own process — rather than for a
  # sleep. Everything the sync does, including what it recorded, is done by then
  # (ISOL-7).
  defp await_sync(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  # One command in the worktree, as a tool call makes: `cd` alone, so the
  # profile follows it (ISOL-13) and the sync it owes runs first (ISOL-7).
  defp command(dir), do: Shell.run("echo hi", cd: dir)

  ## Requirements

  # ISOL-7: the first jailed command in a worktree compiles the shared tree
  # first, in that worktree, under the profile whose bind list has `deps`
  # writable — the only one that lets a compile write inside a dependency.
  test "a worktree is synced before the first jailed command in it (ISOL-7)" do
    dir = worktree()

    assert {:ok, "hi\n", 0} = command(dir)
    ran = synced()

    assert commands(ran) == ["mix deps.get", "mix deps.compile"]

    for cmd <- ["mix deps.get", "mix deps.compile"] do
      assert options(ran, cmd)[:cd] == dir
      assert options(ran, cmd)[:profile] == :deps_sync
    end

    # The compile is for the environment the suite runs in (ISOL-8's allowlist is
    # where MIX_ENV reaches the command).
    assert options(ran, "mix deps.compile")[:env] == [{"MIX_ENV", "test"}]

    # What it remembers is that worktree's mix.lock, one value per worktree.
    assert DepsSync.recorded(dir) == File.read!(Path.join(dir, "mix.lock"))
    assert DepsSync.recorded(dir) == @lock
  end

  # ISOL-7: an unchanged mix.lock needs no fetch and no compile.
  test "an unchanged mix.lock is not synced again (ISOL-7)" do
    dir = worktree()
    command(dir)
    assert commands(synced()) == ["mix deps.get", "mix deps.compile"]

    command(dir)

    assert synced() == []
    assert DepsSync.recorded(dir) == @lock
  end

  # ISOL-7: only a changed mix.lock fetches and compiles again.
  test "a changed mix.lock is synced again (ISOL-7)" do
    dir = worktree()
    command(dir)
    assert commands(synced()) == ["mix deps.get", "mix deps.compile"]

    changed = @lock <> ~s(%{"jason": {:hex, :jason, "1.4.0"}}\n)
    File.write!(Path.join(dir, "mix.lock"), changed)

    command(dir)

    assert commands(synced()) == ["mix deps.get", "mix deps.compile"]
    assert DepsSync.recorded(dir) == changed
  end

  # ISOL-7: one value per worktree, so syncing one never stands in for another.
  test "each worktree keeps its own mix.lock (ISOL-7)" do
    first = worktree("first")
    second = worktree("second", "# another lock\n")

    command(first)
    command(second)

    assert commands(synced()) ==
             ["mix deps.get", "mix deps.compile", "mix deps.get", "mix deps.compile"]

    assert DepsSync.recorded(first) == @lock
    assert DepsSync.recorded(second) == "# another lock\n"
    assert DepsSync.record_path(first) != DepsSync.record_path(second)

    # The second worktree's lock changes; the first one's own value still holds.
    File.write!(Path.join(second, "mix.lock"), "# changed\n")
    command(first)

    assert synced() == []
    assert DepsSync.recorded(first) == @lock
  end

  # ISOL-7: nothing to sync without a mix.lock (a project with no dependencies,
  # or a worktree whose tree has no lock).
  test "a worktree with no mix.lock is not synced (ISOL-7)" do
    dir = worktree("unlocked", nil)

    command(dir)

    assert synced() == []
    assert DepsSync.recorded(dir) == nil
  end

  # ISOL-7: only the `:worktree` profile syncs, so the sync's own `:deps_sync`
  # run can't re-enter it, and the live tree's `:live_tree` run syncs nothing
  # (it isn't a worktree).
  test "only a worktree command syncs, and the sync's own run never re-enters (ISOL-7)" do
    dir = worktree()

    Shell.run("echo hi", cd: dir, profile: :deps_sync)
    Shell.run("echo hi", cd: tree(), profile: :live_tree)
    Shell.run("echo hi", cd: tree())

    assert synced() == []
    assert DepsSync.recorded(dir) == nil
  end

  # ISOL-7: a failed step is not remembered, so the next command in the worktree
  # tries again rather than compiling against a half-synced tree.
  test "a failed sync is not remembered (ISOL-7)" do
    Application.put_env(:elia, Elia.DepsSync, run: fn _command, _opts -> {:ok, "boom", 1} end)
    dir = worktree()

    log =
      capture_log(fn ->
        assert {:error, reason} = DepsSync.sync(dir)
        assert reason =~ "mix deps.get exited with 1"
      end)

    assert log =~ "Could not sync the dependencies"
    assert DepsSync.recorded(dir) == nil
  end

  # ISOL-7: two syncs of the same shared `deps` never run at once — they write
  # the same files — and the caller that waited its turn re-checks what the
  # worktree recorded, so it doesn't compile the same tree a second time.
  test "two syncs of the same deps compile once, and the one that waited doesn't redo it (ISOL-7)" do
    hold_sync()
    dir = worktree()

    first = Task.async(fn -> DepsSync.sync(dir) end)
    assert_receive {:run, "mix deps.get", _opts, runner}, 5_000

    # The second sync of the same worktree waits for the lock the first holds.
    second = Task.async(fn -> DepsSync.sync(dir) end)
    assert Task.yield(second, 100) == nil

    release(runner)
    assert_receive {:run, "mix deps.compile", _opts, ^runner}, 5_000
    release(runner)

    assert :ok = Task.await(first, 5_000)
    assert :ok = Task.await(second, 5_000)

    # Nothing else ran: the second sync found the compile done, re-checked after
    # taking the lock.
    refute_received {:run, _, _, _}
    assert DepsSync.recorded(dir) == @lock
  end

  # ISOL-7: two worktrees of the same live tree compile against the same `deps`,
  # so their syncs are serialized as well — the resource the lock is keyed on is
  # that shared tree, not the worktree.
  test "syncs of two worktrees of the same tree are serialized (ISOL-7)" do
    hold_sync()
    first = worktree("first")
    second = worktree("second")

    task = Task.async(fn -> DepsSync.sync(first) end)
    assert_receive {:run, "mix deps.get", opts, runner}, 5_000
    assert opts[:cd] == first

    other = Task.async(fn -> DepsSync.sync(second) end)
    # Nothing of its own runs while the first worktree's compile is in flight.
    assert Task.yield(other, 100) == nil

    release(runner)
    assert_receive {:run, "mix deps.compile", _opts, ^runner}, 5_000
    release(runner)
    assert :ok = Task.await(task, 5_000)

    # The second worktree has nothing recorded either, so it syncs its own —
    # after the first, not during it.
    assert_receive {:run, "mix deps.get", opts, other_runner}, 5_000
    assert opts[:cd] == second
    release(other_runner)
    assert_receive {:run, "mix deps.compile", _opts, ^other_runner}, 5_000
    release(other_runner)

    assert :ok = Task.await(other, 5_000)
    assert DepsSync.recorded(first) == @lock
    assert DepsSync.recorded(second) == @lock
  end

  # ISOL-7: the first jailed command in a worktree that isn't synced yet waits
  # for the sync it owes — including one already running — rather than starting
  # a second compile of the shared tree, and never compiles against a half-synced
  # one.
  test "a command waits for the sync in flight and starts no second one (ISOL-7)" do
    hold_sync()
    dir = worktree()

    # A chat's worktree sync, in the background, as a chat start begins it.
    DepsSync.sync_in_background(dir)
    assert_receive {:run, "mix deps.get", _opts, runner}, 5_000

    task = Task.async(fn -> command(dir) end)
    # The command is waiting for that sync: while its first step is held, the
    # command can't have run.
    assert Task.yield(task, 100) == nil

    release(runner)
    assert_receive {:run, "mix deps.compile", _opts, ^runner}, 5_000
    release(runner)

    assert {:ok, "hi\n", 0} = Task.await(task, 5_000)

    # Exactly the one sync ran, and the command ran after it.
    refute_received {:run, _, _, _}
    assert DepsSync.recorded(dir) == @lock
  end

  # ISOL-7: a chat start doesn't wait for the worktree's compile. The sync is
  # held here, so a caller that waited for it would not return.
  test "a chat start doesn't wait for the worktree's sync (ISOL-7)" do
    hold_sync()

    File.write!(Path.join(tree(), "mix.lock"), @lock)
    LiveTree.commit(tree(), "lock")
    LiveTree.git!(tree(), ["branch", "-f", LiveTree.trunk(), "live"])

    id = Agent.new_id()
    assert {:ok, path} = Deploy.ensure_worktree(id)
    on_exit(fn -> Deploy.remove_worktree(id) end)

    assert_receive {:run, "mix deps.get", _opts, task}, 5_000
    release(task)
    assert_receive {:run, "mix deps.compile", _opts, ^task}, 5_000
    release(task)

    await_sync(task)
    assert DepsSync.recorded(path) == @lock
  end

  # ISOL-7, ISOL-23, UI-70: while a sync of the shared tree a worktree compiles
  # against is in flight, the chat says so — both to a page that asks and as an
  # event — and it stops saying so when the sync ends.
  test "the chat is told a sync of its worktree is in flight (ISOL-23, UI-70)" do
    hold_sync()
    id = Agent.new_id()
    dir = worktree(id)
    Agent.subscribe(id)

    refute DepsSync.syncing?(dir)

    task = Task.async(fn -> DepsSync.sync(dir) end)
    assert_receive {:run, "mix deps.get", _opts, runner}, 5_000

    assert DepsSync.syncing?(dir)
    assert_receive {:agent, ^id, {:deps_sync, true}}, 5_000

    release(runner)
    assert_receive {:run, "mix deps.compile", _opts, ^runner}, 5_000
    release(runner)

    assert :ok = Task.await(task, 5_000)
    assert_receive {:agent, ^id, {:deps_sync, false}}, 5_000
    refute DepsSync.syncing?(dir)
  end

  # ISOL-23: a sync that failed leaves the chat usable — the command it was owed
  # still runs, carrying the failure — and a command that does need the
  # dependencies fails with its own error. Nothing is remembered, so a later
  # command tries the sync again (ISOL-7).
  test "a command whose worktree sync failed reports it and still runs (ISOL-23)" do
    Application.put_env(:elia, Elia.DepsSync, run: fn _command, _opts -> {:ok, "boom", 1} end)
    dir = worktree()

    log =
      capture_log(fn ->
        assert {:ok, output, status} = Shell.run("touch ran.txt", cd: dir)
        assert output =~ "The shared dependencies could not be synced"
        assert output =~ "mix deps.get exited with 1"

        # The command ran all the same: a broken sync must not make the chat
        # unusable over a dependency this command doesn't need.
        assert status == 0
        assert File.exists?(Path.join(dir, "ran.txt"))
      end)

    assert log =~ "Could not sync the dependencies"
    assert DepsSync.recorded(dir) == nil

    # A later command tries again rather than giving up on the worktree.
    capture_log(fn ->
      assert {:ok, output, 0} = Shell.run("echo hi", cd: dir)
      assert output =~ "The shared dependencies could not be synced"
      assert output =~ "hi\n"
    end)
  end

  # ISOL-7, DEPLOY-1: a chat's worktree is synced where it is resolved — one it
  # just created, and one that predates this feature (an existing worktree with
  # nothing recorded for it) — and the chat doesn't wait for the compile: the
  # sync runs in the background.
  test "a chat's worktree is synced when it is created and when it is resolved (ISOL-7)" do
    # The trunk carries the mix.lock a new worktree forks from.
    File.write!(Path.join(tree(), "mix.lock"), @lock)
    LiveTree.commit(tree(), "lock")
    LiveTree.git!(tree(), ["branch", "-f", LiveTree.trunk(), "live"])

    id = Agent.new_id()
    assert {:ok, path} = Deploy.ensure_worktree(id)
    on_exit(fn -> Deploy.remove_worktree(id) end)

    assert :ok = synced_to_end(path)

    # A worktree from before this feature: nothing is recorded for it, and it is
    # synced when the chat resolves it again.
    DepsSync.forget(path)
    assert Deploy.workspace(Projects.harness(), id) == path

    assert :ok = synced_to_end(path)

    # A sub-task's own worktree is synced the same way (DEPLOY-9).
    child = Agent.new_id()
    assert {:ok, child_path} = Deploy.ensure_child_worktree(child, id)
    on_exit(fn -> Deploy.remove_worktree(child) end)

    assert :ok = synced_to_end(child_path)
  end

  # ISOL-7: the sync started by a chat's worktree runs `mix deps.get` and
  # `MIX_ENV=test mix deps.compile` there, once, and remembers the lock. It is a
  # background task, so this waits for it to end before reading what it recorded.
  defp synced_to_end(dir) do
    assert_receive {:run, "mix deps.get", opts, task}, 5_000
    assert opts[:cd] == dir
    assert opts[:profile] == :deps_sync
    assert_receive {:run, "mix deps.compile", opts, ^task}, 5_000
    assert opts[:env] == [{"MIX_ENV", "test"}]

    await_sync(task)
    assert DepsSync.recorded(dir) == @lock
    :ok
  end

  # ISOL-7, ISOL-13: what the sync is for — the shared tree a worktree compiles
  # against is read-only for a command that runs there, and writable for the
  # harness's own `:deps_sync` step, which is what a compile that writes inside a
  # dependency (as `deps/phoenix` does with its installer templates) needs.
  @tag skip: if(Elia.Shell.available?(), do: false, else: "bubblewrap is not available (ISOL-12)")
  test "the shared deps are read-only for a worktree command and writable for the sync (ISOL-7)" do
    deps = Path.join(tree(), "deps")
    File.mkdir_p!(Path.join(deps, "some_dep"))

    dir = worktree("jailed")
    File.ln_s(deps, Path.join(dir, "deps"))

    with_jail(fn ->
      # A tool call in the worktree is jailed with the live tree's deps bound
      # read-only (ISOL-13).
      assert {:ok, output, status} =
               Shell.run("echo x > deps/some_dep/priv.txt", cd: dir, shell: "sh")

      assert status != 0
      assert output =~ "Read-only file system"
      refute File.exists?(Path.join(deps, "some_dep/priv.txt"))

      # The sync's own run has them writable (ISOL-7).
      assert {:ok, _output, 0} =
               Shell.run("echo x > deps/some_dep/priv.txt",
                 cd: dir,
                 profile: :deps_sync,
                 shell: "sh"
               )

      assert File.read!(Path.join(deps, "some_dep/priv.txt")) == "x\n"
    end)
  end

  # ISOL-7: for real — the sync runs `mix deps.get` and `MIX_ENV=test mix
  # deps.compile` in the worktree and remembers the lock it synced with. A
  # fixture project with no dependencies, so it compiles (almost) nothing.
  test "the real sync runs the two steps in the worktree and remembers the lock (ISOL-7)" do
    Application.delete_env(:elia, Elia.DepsSync)

    dir = worktree("fixture", nil)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule DepsSyncFixture.MixProject do
      use Mix.Project

      def project do
        [app: :deps_sync_fixture, version: "0.1.0", elixir: "~> 1.17", deps: []]
      end
    end
    """)

    File.write!(Path.join(dir, "mix.lock"), "%{}\n")

    assert :ok = DepsSync.sync(dir)

    # The lock the sync worked from is the one remembered, so an unchanged one
    # has nothing left to do.
    assert DepsSync.recorded(dir) == File.read!(Path.join(dir, "mix.lock"))

    assert :ok = DepsSync.sync(dir)
    assert DepsSync.recorded(dir) == File.read!(Path.join(dir, "mix.lock"))
  end

  # The host allows the jail for the duration of the test, as a chat's tool call
  # does (ISOL-1); the suite runs unjailed by default (config/test.exs).
  defp with_jail(fun) do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
    fun.()
  end
end
