defmodule Elia.ShellTest do
  use ExUnit.Case, async: true

  alias Elia.Shell

  # SHELL-2
  test "runs with bash when it is installed, and POSIX sh when it is not" do
    case System.find_executable("bash") do
      nil -> assert Shell.shell([]) == System.find_executable("sh")
      bash -> assert Shell.shell([]) == bash
    end
  end

  # SHELL-2
  test "an explicit shell is the one that runs the command" do
    assert Shell.shell(shell: "sh") == System.find_executable("sh")
    assert Shell.shell(shell: "/bin/dash") == "/bin/dash"

    assert {:ok, "hi\n", 0} = Shell.run("echo hi", shell: "sh")
  end

  # SHELL-2: bash-only syntax works through the default shell where bash is
  # installed, which is why it is preferred.
  test "bash-only syntax works in the default shell when bash is installed" do
    if System.find_executable("bash") do
      assert {:ok, output, 0} = Shell.run("false | true; echo ${PIPESTATUS[0]}")
      assert output =~ "1\n"
    end
  end

  # SHELL-3, ISOL-10: a timeout kills the command and everything it started,
  # jailed or not. Unjailed is the case that leaked: the pid the port reports
  # has to be the process group leader for the negative-pid kill to reach the
  # command, and a `setsid` wrapper forked out of the group we knew. A pipeline
  # covers the whole group, not just the shell.
  test "a timed-out command leaves nothing running when it runs unjailed" do
    assert {:timeout, _output} = Shell.run("sleep 61 | cat", timeout: 500, jail: false)

    assert {:ok, "0\n", _status} =
             Shell.run("ps -eo args | grep -c '^sleep 61$'", shell: "sh", jail: false)
  end

  # SHELL-9: the POSIX fallback has no bash-only syntax, so it fails loudly
  # instead of quietly reporting a different status.
  test "bash-only syntax fails under POSIX sh" do
    assert {:ok, output, status} = Shell.run("echo ${PIPESTATUS[0]}", shell: "sh")
    assert output =~ "Bad substitution"
    assert status != 0
  end
end

defmodule Elia.ShellReachTest do
  # ISOL-25: what a jailed command can reach is a property of the jail's profile
  # (ISOL-13), and the file tools follow it (FILE-12) rather than reimplementing
  # it. This is the bind list, not a run, so it needs no bubblewrap (ISOL-12) —
  # but it does write links in the scratch workspace, and `wanted?/1` is the
  # host's setting, so the module doesn't run async.
  use ExUnit.Case, async: false

  alias Elia.{Shell, Workspace}

  setup do
    live = Workspace.runtime_root()

    worktree =
      Path.join([live, ".elia", "worktrees", "reach-#{System.unique_integer([:positive])}"])

    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf!(worktree) end)
    %{live: live, worktree: worktree}
  end

  # ISOL-13, ISOL-4: a chat worktree is bound on its own, with the repository's
  # git directory and the shared `deps` — and nothing else of the live tree.
  test "a worktree reaches itself, the repo's git dir and the shared deps", %{
    live: live,
    worktree: worktree
  } do
    assert Shell.reachable?(Path.join(worktree, "lib/x.ex"), worktree)
    assert Shell.reachable?(Path.join([live, ".git", "config"]), worktree)
    assert Shell.reachable?(Path.join([live, "deps", "req", "mix.exs"]), worktree)

    refute Shell.reachable?(Path.join(live, "lib/elia/shell.ex"), worktree)
    refute Shell.reachable?(Path.join([live, ".elia", "sessions"]), worktree)
    refute Shell.reachable?("/etc/passwd", worktree)
  end

  # ISOL-6: the live tree is bound with `.elia` masked over it (DEPLOY-14).
  test "the live tree reaches itself, but not its .elia", %{live: live} do
    assert Shell.reachable?(Path.join(live, "lib/elia/shell.ex"), live)
    refute Shell.reachable?(Path.join([live, ".elia", "sessions"]), live)

    # The harness's own steps keep `.elia` in reach (ISOL-22): a worktree is
    # created inside it.
    assert Shell.reachable?(Path.join([live, ".elia", "worktrees"]), live, profile: :deps_sync)
  end

  # ISOL-4: another project's folder is bound on its own (PROJ-12).
  test "another project's folder reaches no further than itself" do
    project = Path.join(System.tmp_dir!(), "elia-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(project)
    on_exit(fn -> File.rm_rf!(project) end)

    assert Shell.reachable?(Path.join(project, "mix.exs"), project)
    refute Shell.reachable?(Path.join(Workspace.runtime_root(), "deps/req/mix.exs"), project)
  end

  # WS-5, ISOL-25: a link inside the workspace that points out of it reaches no
  # further than the link does — the toolchain is bound for running a program,
  # not for reading.
  test "a link out of a workspace is not reachable", %{worktree: worktree} do
    File.ln_s!("/etc", Path.join(worktree, "etc"))

    refute Shell.reachable?(Path.join(worktree, "etc"), worktree)
    refute Shell.reachable?(Path.join(worktree, "etc/passwd"), worktree)
  end

  # ISOL-16, ISOL-20, ISOL-12: the file tools follow this one (FILE-12), so what
  # turns a confinement off is the chat's setting or the host's, not bubblewrap.
  test "what wants a jail" do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    assert Shell.wanted?(jail: true)
    refute Shell.wanted?(jail: false)

    # A caller with no chat gets the default, which is on.
    assert Shell.wanted?([])

    # The host can turn it off for every chat, whatever a chat says.
    Application.put_env(:elia, Elia.Shell, jail: false)
    refute Shell.wanted?(jail: true)
  end
end

defmodule Elia.ShellMixEnvTest do
  # ISOL-24: the server's own `MIX_ENV` (`bin/serve`'s, RESTART-8) is a property
  # of the server, not of the commands it runs. A port's environment can only add
  # to the one it inherits, so the unset happens in the command's own shell, and
  # Mix then honours a project's `preferred_envs` (a `mix precommit` that
  # compiles and tests in `dev` was what went wrong).
  #
  # It puts a value in the *process* environment, which every test of the node
  # shares, so this module doesn't run async (the module above does).
  use ExUnit.Case, async: false

  alias Elia.Shell

  setup do
    previous = System.get_env("MIX_ENV")
    System.put_env("MIX_ENV", "dev")

    on_exit(fn ->
      if previous, do: System.put_env("MIX_ENV", previous), else: System.delete_env("MIX_ENV")
    end)

    :ok
  end

  # ISOL-24
  test "an unjailed command doesn't inherit the server's MIX_ENV" do
    assert {:ok, output, 0} =
             Shell.run("printenv MIX_ENV; echo status=$?", shell: "sh", jail: false)

    assert output == "status=1\n"
  end

  # ISOL-24: the caller's own value is what the command sees, not the server's.
  test "a caller's MIX_ENV is passed through to the command" do
    assert {:ok, "test\n", 0} =
             Shell.run("printenv MIX_ENV", shell: "sh", jail: false, env: [{"MIX_ENV", "test"}])
  end

  # ISOL-24: a caller may build its `:env` keys as atoms; that counts as setting
  # the value too, so no unset follows it.
  test "an atom MIX_ENV key counts as the caller setting the value" do
    assert {:ok, "test\n", 0} =
             Shell.run("printenv MIX_ENV", shell: "sh", jail: false, env: [{:MIX_ENV, "test"}])
  end

  # ISOL-24, ISOL-8: jailed, the environment is rebuilt from the allowlist, so
  # the server's MIX_ENV is absent there as well (the shell's unset changes
  # nothing), and the caller's own value still reaches the command.
  test "a jailed command has no MIX_ENV either, and keeps a caller's value" do
    if Shell.available?() do
      # The suite runs with the jail off (config/test.exs); a call turns it on
      # per call, as a chat's tool call does (ISOL-1, ISOL-16).
      previous = Application.get_env(:elia, Elia.Shell)
      Application.put_env(:elia, Elia.Shell, jail: true)
      on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

      assert Shell.jailed?(jail: true)

      assert {:ok, output, 0} =
               Shell.run("printenv MIX_ENV; echo status=$?", shell: "sh", jail: true)

      assert output == "status=1\n"

      assert {:ok, "test\n", 0} =
               Shell.run("printenv MIX_ENV", shell: "sh", jail: true, env: [{"MIX_ENV", "test"}])
    end
  end
end
