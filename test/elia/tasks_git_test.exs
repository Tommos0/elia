defmodule Elia.TasksGitTest do
  # ISOL-1: the git calls the harness itself makes go through `Elia.Shell.run/2`,
  # like every other process it spawns, so they run jailed. They run in a chat's
  # worktree, whose profile binds the repository's git directory — the
  # worktree's `.git` is a pointer file into it (ISOL-13) — so git answers
  # inside the jail. Skipped where bubblewrap is missing (ISOL-12).
  use ExUnit.Case, async: false

  alias Elia.{Agent, Deploy, LiveTree, Shell, Tasks}

  @moduletag skip:
               if(Shell.available?(), do: false, else: "bubblewrap is not available (ISOL-12)")

  # A throwaway live tree, so the test never touches the server's own tree
  # (DEPLOY-2), and a chat's worktree in it, which is where the harness's git
  # calls run (DEPLOY-1).
  setup do
    tree = LiveTree.create()
    previous_root = Application.get_env(:elia, :runtime_root)
    previous_shell = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, :runtime_root, tree)
    # What a tool call sees by default (ISOL-1); config/test.exs turns it off.
    Application.put_env(:elia, Elia.Shell, jail: true)

    on_exit(fn ->
      Application.put_env(:elia, Elia.Shell, previous_shell)

      if previous_root,
        do: Application.put_env(:elia, :runtime_root, previous_root),
        else: Application.delete_env(:elia, :runtime_root)

      LiveTree.remove(tree)
    end)

    chat = Agent.new_id()
    assert {:ok, path} = Deploy.ensure_worktree(chat)
    on_exit(fn -> Deploy.remove_worktree(chat, tree) end)

    %{tree: tree, worktree: path}
  end

  test "the harness's git calls work in a chat's worktree under the jail (ISOL-1, ISOL-13)", %{
    tree: tree,
    worktree: path
  } do
    # The test is only about the jail if the jail is on: the suite runs unjailed
    # (ISOL-12, ISOL-20), so it turns it on here.
    assert Shell.jailed?([])

    # The worktree's `.git` is a pointer file into the live tree's `.git`, whose
    # `worktrees/<id>` holds the real git dir (ISOL-3, ISOL-4). Nothing but that
    # bind lets a git call answer there, so this is the check that the calls
    # still work under the jail.
    assert Tasks.git_out(["rev-parse", "--git-common-dir"], path)
           |> Path.expand(path) == Path.join(tree, ".git")

    assert Tasks.git_out(["rev-parse", "HEAD"], path) == LiveTree.head(path)
    assert Tasks.git_out(["status", "--porcelain"], path) == ""
  end

  test "a git call that fails still reports nothing (ISOL-1)", %{worktree: path} do
    assert Tasks.git_out(["rev-parse", "no-such-ref"], path) == nil

    # The NUL-separated list `changed_files/2` reads, verbatim: quoting the
    # arguments for the shell must not change what git sees (SUBTASK).
    assert Tasks.git_out(
             ["ls-files", "--others", "--exclude-standard", "--full-name", "-z"],
             path,
             false
           ) == ""
  end

  # ISOL-12: a run whose jail was skipped says so in the shell's output, but a
  # harness caller reads that output as a value, so the notice is stripped
  # before it reaches one (a prepended notice used to break `Elia.Deploy`'s
  # reading of git's output).
  test "the skip notice never reaches the value a caller reads (ISOL-12)", %{
    worktree: path
  } do
    Application.put_env(:elia, Elia.Shell, jail: true, bwrap: "/nonexistent/bwrap")
    refute Shell.jailed?([])

    out = Tasks.git_out(["rev-parse", "HEAD"], path)
    assert out == LiveTree.head(path)
    refute out =~ "jail: skipped"
  end

  # ISOL-1, ISOL-8: the calls go through `Elia.Shell.run/2` rather than around
  # it. A jailed run has its environment rebuilt from an allowlist, so an alias
  # injected through the server's own environment never reaches git — a call
  # that did its own `System.cmd("git", …)` would run it.
  test "the calls go through Elia.Shell, whose jail clears the environment (ISOL-1, ISOL-8)", %{
    tree: tree,
    worktree: path
  } do
    for {key, value} <- [
          {"GIT_CONFIG_COUNT", "1"},
          {"GIT_CONFIG_KEY_0", "alias.jailprobe"},
          {"GIT_CONFIG_VALUE_0", "rev-parse --git-common-dir"}
        ],
        do: System.put_env(key, value)

    on_exit(fn ->
      for key <- ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"],
          do: System.delete_env(key)
    end)

    # Jailed: the environment is cleared, so the alias doesn't exist.
    assert Tasks.git_out(["jailprobe"], path) == nil

    # The same alias does work with the jail off, so the check has teeth.
    Application.put_env(:elia, Elia.Shell, jail: false)

    assert Tasks.git_out(["jailprobe"], path)
           |> Path.expand(path) == Path.join(tree, ".git")
  end
end
