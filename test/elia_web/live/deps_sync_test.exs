defmodule EliaWeb.DepsSyncTest do
  # ISOL-23, UI-70: the chat shows the sync of its worktree's shared
  # dependencies while it is in flight — the one a chat start begins in the
  # background, and the one a command is waiting for — and it goes when the sync
  # ends, whether that was a success or a failure. It never blocks the composer
  # or the transcript.
  use EliaWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Elia.{Agent, DepsSync, FakeLLM}

  @lock ~s(%{"phoenix": {:hex, :phoenix, "1.7.0"}}\n)

  setup do
    start_supervised!(FakeLLM)

    previous = Application.get_env(:elia, Elia.DepsSync, [])
    on_exit(fn -> Application.put_env(:elia, Elia.DepsSync, previous) end)

    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    Agent.subscribe(id)

    %{id: id}
  end

  ## Helpers

  # A chat's worktree of the live tree (DEPLOY-1): its directory is the chat id,
  # which is how the sync's event finds the chat. Created *after* the chat is
  # open, so the mount resolves no worktree and starts no sync of its own — the
  # test's own sync is the only one in flight.
  defp worktree(id) do
    dir = Path.join([Elia.Workspace.data_dir(), "worktrees", id])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.lock"), @lock)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A sync the test holds: it reports the step it is about to run (and the pid
  # running it) and waits for `release/1`, so the sync can't end behind the
  # test's back. A real sync runs `mix deps.get` and `mix deps.compile`, which
  # no test may do (ISOL-7).
  defp hold_sync(fail? \\ false) do
    test_pid = self()
    result = if fail?, do: {:ok, "boom", 1}, else: {:ok, "", 0}

    Application.put_env(:elia, Elia.DepsSync,
      run: fn command, opts ->
        send(test_pid, {:run, command, opts, self()})
        receive do: (:release -> result)
      end
    )
  end

  defp release(pid), do: send(pid, :release)

  defp await_sync(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end

  ## Requirements

  # ISOL-23, UI-70: a sync the chat started in the background shows while it is
  # in flight, and goes when it ends.
  test "the chat shows a sync in flight, and it goes when the sync ends (ISOL-23, UI-70)", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    refute has_element?(view, "#deps-sync")

    dir = worktree(id)
    hold_sync()

    # ISOL-7: a chat that just got its worktree starts the sync in the
    # background; a command in the worktree would wait for it.
    DepsSync.sync_in_background(dir)
    assert_receive {:run, "mix deps.get", _opts, runner}, 5_000

    assert has_element?(view, "#deps-sync", "Preparing shared dependencies")
    # UI-70: the sync never blocks the composer or the transcript.
    assert has_element?(view, "#chat-input")
    assert has_element?(view, "#transcript")

    release(runner)
    assert_receive {:run, "mix deps.compile", _opts, ^runner}, 5_000
    release(runner)
    await_sync(runner)

    refute has_element?(view, "#deps-sync")
    assert DepsSync.recorded(dir) == @lock
  end

  # ISOL-23, UI-70: the other case the indicator has to cover — a command
  # waiting for the sync it owes the worktree.
  test "the chat shows a sync a command is waiting for (ISOL-23, UI-70)", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    refute has_element?(view, "#deps-sync")

    dir = worktree(id)
    hold_sync()

    task = Task.async(fn -> Elia.Shell.run("echo hi", cd: dir) end)
    assert_receive {:run, "mix deps.get", _opts, runner}, 5_000

    assert has_element?(view, "#deps-sync", "Preparing shared dependencies")

    release(runner)
    assert_receive {:run, "mix deps.compile", _opts, ^runner}, 5_000
    release(runner)

    assert {:ok, "hi\n", 0} = Task.await(task, 5_000)
    refute has_element?(view, "#deps-sync")
  end

  # ISOL-23, UI-70: a sync that failed leaves the chat usable, the indicator goes
  # all the same, and the failure shows up in the result of the next command.
  test "the indicator goes when the sync fails, and the next command says why (ISOL-23, UI-70)",
       %{
         conn: conn,
         id: id
       } do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    refute has_element?(view, "#deps-sync")

    dir = worktree(id)
    hold_sync(fail?: true)

    DepsSync.sync_in_background(dir)
    assert_receive {:run, "mix deps.get", _opts, runner}, 5_000

    assert has_element?(view, "#deps-sync", "Preparing shared dependencies")

    capture_log(fn ->
      release(runner)
      await_sync(runner)
    end)

    # The sync failed: nothing is remembered, and the chat says no more than it
    # did before it started — but it stays usable.
    refute has_element?(view, "#deps-sync")
    assert DepsSync.recorded(dir) == nil
    assert has_element?(view, "#chat-input")

    # ISOL-23: the failure is in the result of the next command, which doesn't
    # run against a half-synced tree. It isn't held this time, so the command
    # gets there.
    Application.put_env(:elia, Elia.DepsSync, run: fn _command, _opts -> {:ok, "boom", 1} end)

    log =
      capture_log(fn ->
        assert {:ok, output, status} = Elia.Shell.run("echo hi", cd: dir)
        assert output =~ "The shared dependencies could not be synced"
        assert status != 0
      end)

    # A failure is logged, not raised: it can't take the chat down.
    assert log =~ "Could not sync the dependencies"
  end
end
