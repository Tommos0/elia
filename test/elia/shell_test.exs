defmodule Elia.ShellTest do
  use ExUnit.Case, async: true

  alias Elia.{Priority, Shell}

  # SHELL-14: a caller that passes an id of its own keeps it — the unset is for a
  # command that belongs to no chat, not for one that names its chat.
  test "a caller's own chat id reaches the command" do
    assert {:ok, output, 0} = Shell.run("printenv ELIA_CHAT_ID", env: [{"ELIA_CHAT_ID", "chatX"}])

    assert output == "chatX\n"
  end

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

  # SHELL-5: output longer than the cap is cut in the middle, with a marker that
  # gives the number of characters removed.
  test "long output is cut in the middle with a marker" do
    assert Shell.truncate("short", 30_000) == "short"

    cut = Shell.truncate(String.duplicate("a", 50), 20)
    assert cut =~ "... [30 characters truncated] ..."
    assert String.starts_with?(cut, String.duplicate("a", 10))
    assert String.ends_with?(cut, String.duplicate("a", 10))
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

  # SHELL-12: a command never outlives the process waiting on it. The command
  # leaves a child of its own in the group, and the caller is killed the way a
  # stopped turn's tool call is: the shell and that child both go, long before
  # the command's deadline.
  for jail <- [false, true] do
    @tag jail: jail
    test "a command whose waiting process exits is killed with its group (jail: #{jail})",
         %{jail: jail} do
      if jail and not Shell.available?() do
        :ok
      else
        family = if jail, do: "3171", else: "3170"
        marker = sleep_marker(family)
        command = "sleep #{marker} & sleep #{marker}; wait"
        caller = spawn(fn -> Shell.run(command, jail: jail, timeout: 120_000) end)
        on_exit(fn -> Process.exit(caller, :kill) end)

        assert eventually(fn -> running(marker) == 2 end)

        Process.exit(caller, :kill)
        assert eventually(fn -> running(marker) == 0 end)
      end
    end
  end

  # SHELL-12: a command that ends on its own is never killed after it ends — a
  # process it left running, detached from its output, outlives the run and its
  # caller both.
  test "a command that ends on its own is not killed when its caller exits later" do
    marker = sleep_marker("3172")
    test_pid = self()

    caller =
      spawn(fn ->
        send(test_pid, {:ran, Shell.run("sleep #{marker} >/dev/null 2>&1 &", jail: false)})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:ran, {:ok, _, 0}}, 10_000
    ref = Process.monitor(caller)
    send(caller, :exit)
    assert_receive {:DOWN, ^ref, :process, ^caller, :normal}

    refute eventually(fn -> running(marker) == 0 end, 500)
    assert running(marker) == 1
  end

  # SHELL-13: a capped run that is flooded holds only a bounded part of the
  # output while it runs — sampled from the process running it, which owns the
  # buffer — and its one marker counts what was removed. ASCII is one byte a
  # character, so here the count is exact.
  #
  # The sample is every binary the process references, so it also counts the
  # port's messages still waiting in its mailbox, which grow when the node is
  # loaded. The buffer itself is about 120 KB here; the bound leaves room for
  # that backlog and is still far below what an uncapped run held (100 MB for
  # this flood).
  test "a capped run holds bounded output while a command floods it" do
    test_pid = self()
    total = 50_000_000
    command = "head -c #{total} /dev/zero | tr '\\0' a"

    runner = spawn(fn -> send(test_pid, {:ran, Shell.run(command, max_output: 30_000)}) end)
    peak = peak_binary_bytes(runner, 0)

    assert_receive {:ran, {:ok, output, 0}}, 60_000
    assert peak < 20_000_000
    assert [_head, _tail] = String.split(output, "characters truncated")
    assert output =~ "... [#{total - 30_000} characters truncated] ..."
    assert String.starts_with?(output, String.duplicate("a", 15_000) <> "\n...")
    assert String.ends_with?(output, "...\n" <> String.duplicate("a", 15_000))
  end

  # SHELL-13: output that fits is whole, and output over the cap that never had
  # to be dropped while running is cut exactly as SHELL-5 always cut it.
  test "a capped run that drops nothing is cut as before" do
    assert {:ok, "abc", 0} = Shell.run("printf abc", max_output: 10)

    assert {:ok, output, 0} = Shell.run("printf '%01500d' 0", max_output: 1_000)
    assert output == Shell.truncate(String.duplicate("0", 1_500), 1_000)
  end

  # SHELL-13: what was dropped while running is counted in bytes, so for
  # multi-byte characters the count may overstate what was removed — never
  # understate it.
  test "with multi-byte output the count never understates what was removed" do
    chars = 10_000
    command = "for i in $(seq #{chars}); do printf 'é'; done"

    assert {:ok, output, 0} = Shell.run(command, max_output: 1_000)

    assert [_, head, removed, tail] =
             Regex.run(~r/\A(.*)\n\.\.\. \[(\d+) characters truncated\] \.\.\.\n(.*)\z/su, output)

    assert String.to_integer(removed) >= chars - 1_000
    assert head == String.duplicate("é", 500)
    assert tail == String.duplicate("é", 500)
  end

  # The most bytes of refc binaries `pid` references at any sample until it
  # exits, sampled every 5 ms.
  defp peak_binary_bytes(pid, peak) do
    case Process.info(pid, :binary) do
      nil ->
        peak

      {:binary, binaries} ->
        now = binaries |> Enum.map(fn {_id, size, _refs} -> size end) |> Enum.sum()

        receive do
        after
          5 -> peak_binary_bytes(pid, max(peak, now))
        end
    end
  end

  # A sleep length no other run uses — `<family>.<unique>` seconds — so a count
  # is this run's processes only, and a process an earlier run leaked can't be
  # counted by a later one. That run's leftovers of the family are killed
  # first, and this run's own on every exit path, a failed assertion included.
  defp sleep_marker(family) do
    System.cmd("pkill", ["-KILL", "-f", "^sleep #{family}"])
    marker = "#{family}.#{System.unique_integer([:positive])}"
    on_exit(fn -> System.cmd("pkill", ["-KILL", "-x", "-f", "sleep #{marker}"]) end)
    marker
  end

  # How many processes run `sleep <marker>`, read from outside any jail.
  defp running(marker) do
    {count, _} = System.cmd("pgrep", ["-c", "-x", "-f", "sleep #{marker}"])
    count |> String.trim() |> String.to_integer()
  end

  # Whether `check` holds within `ms`, asked every 20 ms: there is no event for
  # an OS process ending that this test could wait on instead. The default is
  # generous because a loaded node can be slow to start or reap a process.
  defp eventually(check, ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + ms

    Stream.repeatedly(fn ->
      receive do
      after
        20 -> check.()
      end
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > deadline end)
  end

  # SHELL-9: the POSIX fallback has no bash-only syntax, so it fails loudly
  # instead of quietly reporting a different status.
  test "bash-only syntax fails under POSIX sh" do
    assert {:ok, output, status} = Shell.run("echo ${PIPESTATUS[0]}", shell: "sh")
    assert output =~ "Bad substitution"
    assert status != 0
  end

  # PRIO-1, PRIO-3, PRIO-5: a command starts below the priority of whoever
  # asked for it — `nice` adds its adjustment to the niceness the process would
  # inherit — and everything the command starts inherits it. `priority:
  # [nice: 0]` is a call asking for its own priority instead, which is what a
  # step that needs the whole machine does.
  test "a command runs below its caller's priority, and the whole tree it starts has it" do
    if File.exists?("/proc/self/stat") do
      parent = own_niceness()
      below = min(parent + (Priority.settings()[:nice] || 0), 19)

      assert {:ok, output, 0} =
               Shell.run("ps -o ni= -p $$; sh -c 'ps -o ni= -p $$'", shell: "sh")

      assert output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) ==
               [to_string(below), to_string(below)]

      assert {:ok, output, 0} =
               Shell.run("ps -o ni= -p $$", shell: "sh", priority: [nice: 0])

      assert String.trim(output) == to_string(parent)
    end
  end

  # PRIO-4, PRIO-6: the command's I/O is in the configured class too — a
  # best-effort level, or the idle class — and never the realtime one, which
  # would need privileges.
  test "a command's own I/O class is the configured one" do
    if System.find_executable("ionice") do
      assert {:ok, output, 0} = Shell.run("ionice -p $$", shell: "sh")
      refute output =~ "realtime"

      expected =
        case Priority.settings()[:ionice] do
          :idle -> "idle"
          level when is_integer(level) -> "prio #{level}"
          nil -> "none"
        end

      assert output =~ expected
    end
  end

  # PRIO-3, PRIO-7: the priority is a prefix on the executable, and the programs
  # it names `exec`, so the process Elia started is still the session and
  # process group leader whose group the timeout kills (SHELL-3, ISOL-10) — and
  # a niced command is killed with everything it started, like any other.
  test "a niced command is still its own group leader, and a timeout still cleans up" do
    assert {:ok, output, 0} = Shell.run("ps -o pid=,pgid= -p $$", shell: "sh", jail: false)
    assert [pid, pgid] = String.split(String.trim(output))
    assert pid == pgid

    assert {:timeout, _output} = Shell.run("sleep 61 | cat", timeout: 500, jail: false)

    assert {:ok, "0\n", _status} =
             Shell.run("ps -eo args | grep -c '^sleep 61$'", shell: "sh", jail: false)
  end

  # SHELL-11: the timeout is a deadline for the whole run, not a quiet period. A
  # receive that ends on a timeout only while nothing arrives would let this
  # command run until the machine ran out of memory.
  test "a command that floods stdout still ends at its deadline" do
    started = System.monotonic_time(:millisecond)

    assert {:timeout, output} =
             Shell.run("while true; do echo hi; done", timeout: 500, jail: false)

    assert output =~ "hi"
    assert System.monotonic_time(:millisecond) - started < 30_000
  end

  # SHELL-4, SHELL-10
  test "the status of a run that reached its timeout, and of a clamped one" do
    assert Shell.timeout_status(600_000, nil) == "timeout after 600s"

    assert Shell.timeout_status(600_000, 3_600) ==
             "timeout after 600s (asked for 3600s, the most is 600s)"
  end

  # SHELL-10: what a call asked for, resolved against the default and the
  # ceiling it may not pass.
  test "resolves a call's timeout against the default and the maximum" do
    assert Shell.resolve_timeout(nil, 60, 1_800) == {:ok, 60, nil}
    assert Shell.resolve_timeout(300, 60, 1_800) == {:ok, 300, nil}

    # Above the maximum the maximum is used, and what was asked for comes back
    # beside it, so a result can say which ceiling it hit.
    assert Shell.resolve_timeout(86_400, 60, 1_800) == {:ok, 1_800, 86_400}

    # A configured default above the maximum can never win.
    assert Shell.resolve_timeout(nil, 3_600, 1_800) == {:ok, 1_800, nil}

    assert Shell.resolve_timeout(0, 60, 1_800) == {:error, :invalid}
    assert Shell.resolve_timeout(-1, 60, 1_800) == {:error, :invalid}
    assert Shell.resolve_timeout("60", 60, 1_800) == {:error, :invalid}
  end

  # The niceness of this process, which is the one a command it spawns inherits
  # and `nice` adds its adjustment to (PRIO-1). In `/proc/self/stat` the value
  # is field 17, counting from `state`, so index 16 after the `(comm)` field
  # (which may itself hold spaces and parentheses).
  defp own_niceness do
    [_, fields] = String.split(File.read!("/proc/self/stat"), ") ", parts: 2)
    fields |> String.split(" ") |> Enum.at(16) |> String.to_integer()
  end
end

defmodule Elia.ShellJailSettingTest do
  # ISOL-16, ISOL-20, ISOL-12: what a call wants, whatever bubblewrap can do.
  # The module turns the host's setting on and off, so it doesn't run async.
  use ExUnit.Case, async: false

  alias Elia.Shell

  # ISOL-16, ISOL-20, ISOL-12: what turns a confinement off is the chat's
  # setting or the host's, not bubblewrap.
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

  # ISOL-12: a caller that reads a run's output as a value takes the notice off
  # it.
  test "the notice a run may put in front of its output comes off it" do
    assert Shell.strip_notices(Shell.jail_skipped_notice() <> "\nhi\n") == "hi\n"
    assert Shell.strip_notices("hi\n") == "hi\n"
  end
end

defmodule Elia.ShellJailTest do
  # ISOL-13, ISOL-6, ISOL-4: the bind list of the jail, built from the workspace
  # the call belongs to — one profile, decided by which tree that is — with
  # `--chdir` left at the directory the call runs in (WD-1). These check the
  # argv, so bubblewrap is only needed to build one (ISOL-12) — but the worktree
  # case makes a real git worktree, so the module doesn't run async.
  use ExUnit.Case, async: false

  alias Elia.{LiveTree, Shell}

  @moduletag skip:
               if(Elia.Shell.available?(),
                 do: false,
                 else: "bubblewrap is not available (ISOL-12)"
               )

  setup do
    # The suite runs unjailed (config/test.exs); these are about the jail's argv,
    # so the host is made to allow one (ISOL-20). The tree is a live tree of the
    # test's own, with the `.elia` a live tree holds (DEPLOY-2).
    previous = Application.get_env(:elia, Elia.Shell)
    previous_root = Application.get_env(:elia, :runtime_root)
    tree = LiveTree.create()
    File.mkdir_p!(Path.join(tree, ".elia"))

    Application.put_env(:elia, Elia.Shell, jail: true)
    Application.put_env(:elia, :runtime_root, tree)

    on_exit(fn ->
      Application.put_env(:elia, Elia.Shell, previous)

      if previous_root,
        do: Application.put_env(:elia, :runtime_root, previous_root),
        else: Application.delete_env(:elia, :runtime_root)

      LiveTree.remove(tree)
    end)

    %{tree: tree}
  end

  # NET-12, NET-16: the namespace a mode puts in the jail's argv — what
  # `Elia.Net.prepare/1` hands `Shell.run/2` as `:net`. Unrestricted is the jail
  # as it was; none mode is the namespace alone, with nothing to reach.
  test "an unrestricted or none network is the jail's argv", %{tree: tree} do
    {_exe, args} = Shell.argv("echo hi", tree, jail: true)
    refute "--unshare-net" in args
    assert Enum.take(args, -4) == ["--", Shell.shell([]), "-c", "echo hi"]

    {_exe, args} = Shell.argv("echo hi", tree, jail: true, net: %{mode: :none})
    assert "--unshare-net" in args
    # NET-16: no proxy and no relay: nothing to reach, so nothing to carry it.
    refute Enum.any?(args, &String.contains?(&1, "relay.exs"))
    assert Enum.take(args, -4) == ["--", Shell.shell([]), "-c", "echo hi"]
  end

  # NET-13: an allowlist's namespace holds the relay and the proxy's socket, and
  # the command runs behind a wrapper that starts the relay first — the same
  # shell and the same script it would have run (SHELL-2).
  test "an allowlist's namespace holds the relay and the wrapper", %{tree: tree} do
    {:ok, proxy} = Elia.Net.Proxy.start(mode: :allowlist, hosts: [], chat_id: nil)
    net = Elia.Net.Proxy.net(proxy)
    on_exit(fn -> Elia.Net.Proxy.stop(proxy) end)

    {_exe, args} = Shell.argv("echo hi", tree, jail: true, net: net)

    assert "--unshare-net" in args
    assert net.dir in args
    assert Path.join(net.dir, "run") in args

    # The wrapper is the script, and the command's shell and script are its
    # arguments.
    assert Enum.take(args, -5) == [
             "-c",
             Enum.at(args, -4),
             "elia-net",
             Shell.shell([]),
             "echo hi"
           ]

    wrapper = Enum.at(args, -4)
    assert wrapper =~ "relay.exs"
    assert wrapper =~ "#{net.port}"
    assert wrapper =~ net.socket
  end

  # ISOL-2: the jail is bubblewrap with its own namespaces — a fresh pid, UTS,
  # IPC and cgroup namespace, its own `/proc`, `/dev` and `/tmp` — and a `chdir`
  # into the directory the call runs in.
  test "the jail is bubblewrap with its own namespaces", %{tree: tree} do
    {_exe, args} = Shell.argv("echo hi", tree, jail: true)

    for flag <-
          ~w(--die-with-parent --unshare-pid --unshare-uts --unshare-ipc --unshare-cgroup-try --proc --dev --tmpfs) do
      assert flag in args
    end

    assert Enum.take(args, -4) == ["--", Shell.shell([]), "-c", "echo hi"]
    assert chdir(args) == tree
  end

  # ISOL-13, WD-1: the jail holds the workspace the call belongs to and `--chdir`
  # is still the directory it runs in — so a call that `cd`s into a subdirectory
  # is jailed to the whole tree and runs in the subdirectory.
  test "the jail holds the workspace and chdir the directory the call runs in", %{tree: tree} do
    sub = Path.join(tree, "lib")

    {_exe, args} = Shell.argv("echo hi", sub, jail: true, workspace: tree)

    assert tree_binds(args, tree) == [{tree, tree}]
    assert chdir(args) == sub
  end

  # ISOL-13: a caller that names no workspace gets the directory it runs in
  # bound — the one tree it could mean.
  test "without a workspace the jail holds the directory the call runs in", %{tree: tree} do
    sub = Path.join(tree, "lib")

    {_exe, args} = Shell.argv("echo hi", sub, jail: true)

    assert tree_binds(args, tree) == [{sub, sub}]
    assert chdir(args) == sub
  end

  # ISOL-6: the live tree is bound whole, and its `.elia` masked with an empty
  # tmpfs made *after* that bind — bubblewrap mounts in argument order, so the
  # mask wins.
  test "the live tree is bound, then its .elia masked over it", %{tree: tree} do
    data = Path.join(tree, ".elia")

    {_exe, args} = Shell.argv("echo hi", tree, jail: true, workspace: tree)

    assert tree_binds(args, tree) == [{tree, tree}]
    assert index(args, "--tmpfs", data) > index(args, "--bind", tree)
  end

  # ISOL-4, DEPLOY-13: a chat's worktree — one it made itself inside the live
  # tree (DEPLOY-28) — is bound with the repository's git directory behind its
  # `.git` pointer file, read-write, so a commit, a rebase and its fast-forward
  # of `master` all work from inside. The live tree itself is not bound, so
  # Elia's data and the other chats' worktrees are out of reach (ISOL-6).
  test "a worktree is bound with the repository's git directory", %{tree: tree} do
    id = "jail-#{System.unique_integer([:positive])}"
    worktree = LiveTree.worktree(tree, id)
    git = Path.join(tree, ".git")

    {_exe, args} = Shell.argv("echo hi", worktree, jail: true, workspace: worktree)
    bound = tree_binds(args, tree)

    assert {worktree, worktree} in bound
    assert {Path.join([git, "worktrees", id]), Path.join([git, "worktrees", id])} in bound
    assert {git, git} in bound
    refute {tree, tree} in bound
    assert chdir(args) == worktree
  end

  # ISOL-7 retired, DEPLOY-29: no dependency tree is bound into a jail and
  # nothing is overlaid any more — a chat's worktree holds its own copies of
  # `deps` and `_build`, which the chat made itself — so there is no mount to
  # report on or to serialise (ISOL-28).
  test "no jail overlays or binds a dependency tree", %{tree: tree} do
    worktree = LiveTree.worktree(tree, "deps-#{System.unique_integer([:positive])}")
    deps = Path.join(tree, "deps")

    for opts <- [[workspace: worktree], [workspace: tree], []] do
      {_exe, args} = Shell.argv("echo hi", worktree, [jail: true] ++ opts)

      refute "--overlay" in args
      refute "--overlay-src" in args
      refute "--info-fd" in args
      refute Enum.any?(binds(args), fn {source, _dest} -> source == deps end)
    end
  end

  # ISOL-4: another project's folder is bound on its own (PROJ-12).
  test "another project's folder is bound on its own", %{tree: tree} do
    project =
      Path.join(System.tmp_dir!(), "elia-jail-project-#{System.unique_integer([:positive])}")

    File.mkdir_p!(project)
    on_exit(fn -> File.rm_rf!(project) end)

    {_exe, args} = Shell.argv("echo hi", project, jail: true, workspace: project)

    assert {project, project} in binds(args)
    refute {tree, tree} in binds(args)
    assert chdir(args) == project
  end

  # The binds a jail's argv makes, in order: `--bind` and `--bind-try` both bind
  # read-write. `tree_binds/2` keeps the ones into one tree, since the toolchain
  # and `$HOME` are bound beyond them (ISOL-4).
  defp binds(args), do: triples(args, ~w(--bind --bind-try))

  defp tree_binds(args, tree) do
    Enum.filter(binds(args), fn {source, _dest} ->
      source == tree or String.starts_with?(source, tree <> "/")
    end)
  end

  defp triples(args, flags) do
    args
    |> Enum.with_index()
    |> Enum.filter(fn {arg, _index} -> arg in flags end)
    |> Enum.map(fn {_flag, index} -> {Enum.at(args, index + 1), Enum.at(args, index + 2)} end)
  end

  # The position of a flag followed by `path`, or nil when there is none.
  defp index(args, flag, path) do
    Enum.find_index(Enum.with_index(args), fn {arg, at} ->
      arg == flag and Enum.at(args, at + 1) == path
    end)
  end

  defp chdir(args) do
    at = Enum.find_index(args, &(&1 == "--chdir"))
    Enum.at(args, at + 1)
  end
end
