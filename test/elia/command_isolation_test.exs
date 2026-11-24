defmodule Elia.CommandIsolationTest do
  # ISOL: a jailed command holds the workspace and the toolchain and nothing
  # else, so the settings database (CONF-1), the credentials and the server
  # itself are out of reach. Skipped where bubblewrap is missing (ISOL-12).
  use ExUnit.Case, async: false

  alias Elia.Shell

  @moduletag skip:
               if(Elia.Shell.available?(),
                 do: false,
                 else: "bubblewrap is not available (ISOL-12)"
               )

  setup do
    # The suite runs unjailed (config/test.exs). Here the host allows the jail
    # and each call turns it on, which is what a tool call does (ISOL-1, ISOL-16).
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
    :ok
  end

  defp jailed(command, opts \\ []) do
    Shell.run(command, [jail: true, shell: "sh"] ++ opts)
  end

  test "a jailed command runs and reports normally (ISOL-10)" do
    assert {:ok, "hi\n", 0} = jailed("echo hi")
  end

  test "the home directory is stripped to mix, the browser cache and the Playwright CLI (ISOL-4, ISOL-5, ISOL-26, ISOL-8)" do
    assert {:ok, output, 0} = jailed("ls -A $HOME")

    assert output
           |> String.split("\n", trim: true)
           |> Enum.all?(&(&1 in [".cache", ".local", ".mix"]))
  end

  test "the browser the real-browser tests drive is there, read-only (ISOL-4)" do
    cache = Path.join([System.user_home!(), ".cache", "ms-playwright"])

    if File.dir?(cache) do
      # Only the browser cache is bound, not the cache directory itself.
      assert {:ok, output, 0} = jailed("ls -A $HOME/.cache")
      assert String.split(output, "\n", trim: true) == ["ms-playwright"]

      assert {:ok, _output, 0} = jailed("ls -d $HOME/.cache/ms-playwright/*")

      assert {:ok, _output, status} = jailed("touch $HOME/.cache/ms-playwright/probe")
      assert status != 0, "the browser cache must be read-only"
    end
  end

  test "the user-wide Playwright CLI is there, read-only, and nothing else of ~/.local is (ISOL-26)" do
    dir = Elia.Shell.playwright_dir()
    package = Path.join([dir, "node_modules", "playwright"])

    if File.dir?(package) do
      # What the driver starts is reachable inside the jail, at the same
      # absolute path it was told to use (ISOL-3).
      assert {:ok, output, 0} = jailed("ls #{package}/cli.js")
      assert output =~ "cli.js"

      assert {:ok, _output, status} = jailed("touch #{package}/probe")
      assert status != 0, "the Playwright CLI must be read-only"

      # Only the package is bound: the rest of ~/.local is absent, so nothing
      # else the user keeps there is reachable (ISOL-5).
      assert {:ok, output, 0} = jailed("ls -A $HOME/.local")
      assert String.split(output, "\n", trim: true) == ["lib"]

      assert {:ok, output, 0} = jailed("ls -A $HOME/.local/lib")
      assert String.split(output, "\n", trim: true) == ["node_modules"]

      for path <- ["$HOME/.local/bin", "$HOME/.local/share"] do
        assert {:ok, _output, status} = jailed("ls -d #{path} 2>/dev/null")
        assert status != 0, "#{path} must not be reachable inside the jail"
      end
    end
  end

  test "credentials and the settings store are absent (ISOL-5)" do
    for path <- [
          "$HOME/.ssh",
          "$HOME/.git-credentials",
          "$HOME/.config/gh",
          "$HOME/.netrc",
          "$HOME/.local/share/elia",
          "$HOME/.aws",
          Elia.Settings.path()
        ] do
      assert {:ok, _output, status} = jailed("ls -d #{path} 2>/dev/null")
      assert status != 0, "#{path} must not be reachable inside the jail"
    end
  end

  # SHELL-14, ISOL-8: what a caller adds to a jailed command's environment
  # reaches it — `--setenv` comes after `--clearenv`, so the chat's id is there
  # although the allowlist knows nothing of it.
  test "a jailed command is told the chat id the caller gave it (SHELL-14, ISOL-8)" do
    assert {:ok, output} =
             Elia.Skills.Shell.run(%{"command" => "printenv ELIA_CHAT_ID"}, %{
               session_id: "chat-jailed",
               jail: true
             })

    assert output =~ "chat-jailed"
  end

  # ISOL-31, SHELL-16: a call may ask for no jail, and that call runs outside it
  # whatever the chat's setting is — the tool passes the call's own request to
  # the run.
  test "a call that asks for no jail runs outside it (ISOL-31)" do
    # The chat's setting is on here (setup), and the jail's `/tmp` is a fresh
    # tmpfs (ISOL-1), so a file the machine has under /tmp is what tells the two
    # apart.
    probe = "/tmp/elia-jail-probe-#{System.unique_integer([:positive])}"
    File.write!(probe, "x")
    on_exit(fn -> File.rm(probe) end)

    assert {:error, output} =
             Elia.Skills.Shell.run(%{"command" => "ls -d #{probe} 2>/dev/null"}, %{jail: true})

    refute output =~ probe

    assert {:ok, output} =
             Elia.Skills.Shell.run(
               %{"command" => "ls -d #{probe}", "jail" => false},
               %{jail: true}
             )

    assert output =~ probe
    assert output =~ "[jail: off at this call's request]"
  end

  test "the server is not visible (ISOL-9)" do
    # A process that is definitely running outside the jail.
    assert {:ok, output, 0} =
             Shell.run("setsid sleep 62 >/dev/null 2>&1 & echo $!", shell: "sh", jail: false)

    pid = String.trim(output)
    assert {:ok, _output, 0} = Shell.run("ls -d /proc/#{pid}", shell: "sh", jail: false)

    assert {:ok, _output, status} = jailed("ls -d /proc/#{pid}")
    assert status != 0, "a process outside the jail must not be visible in it"

    Shell.run("kill -KILL #{pid}", shell: "sh", jail: false)
  end

  test "the workspace is writable and git works in it (ISOL-1, ISOL-3)" do
    assert {:ok, "hi\n", 0} = jailed("echo hi > jail_probe && cat jail_probe && rm jail_probe")

    assert {:ok, "true\n", 0} = jailed("git rev-parse --is-inside-work-tree")
  end

  test "a timed-out jail leaves nothing running (ISOL-10)" do
    assert {:timeout, _output} = jailed("sleep 61", timeout: 500)

    assert {:ok, "0\n", _status} =
             Shell.run("ps -eo args | grep -c '^sleep 61$'", shell: "sh")
  end

  test "a call that wanted a jail and didn't get one says so (ISOL-12)" do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true, bwrap: "/nonexistent/bwrap")
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    refute Shell.available?()
    refute Shell.jailed?(jail: true)
    assert {:ok, output, 0} = Shell.run("echo hi", jail: true, shell: "sh")
    assert output =~ "[jail: skipped, bubblewrap is unavailable]"
  end

  test "a chat is jailed by default where the host allows it (ISOL-1, ISOL-16)" do
    assert Shell.jailed?([])
    refute Shell.jailed?(jail: false)
  end

  # ISOL-15: the tool context carries the chat's jail decision, so a tool jails
  # its call according to the chat it runs in, and a caller with no chat gets the
  # default, which is on.
  describe "the tool context's jail setting (ISOL-15)" do
    # These build the argv/behaviour without needing a real jail (ISOL-12).
    @describetag skip: false

    setup do
      # The host allows a jail but has no bubblewrap, so a call that asked for
      # one reports it was skipped (ISOL-12) and one that didn't says nothing.
      previous = Application.get_env(:elia, Elia.Shell)
      Application.put_env(:elia, Elia.Shell, jail: true, bwrap: "/nonexistent/bwrap")
      on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
      %{notice: "[jail: skipped, bubblewrap is unavailable]"}
    end

    test "the shell tool follows the context, and jails a call with no chat", %{notice: notice} do
      # No chat at all: the default, which is jailed.
      assert {:ok, output} = Elia.Skills.Shell.run(%{"command" => "echo hi"}, %{})
      assert output =~ notice

      assert {:ok, output} = Elia.Skills.Shell.run(%{"command" => "echo hi"}, %{jail: true})
      assert output =~ notice

      # A chat whose jail is off runs the command unjailed.
      assert {:ok, output} = Elia.Skills.Shell.run(%{"command" => "echo hi"}, %{jail: false})

      refute output =~ notice
    end

    # FOLDER-6: a script tool runs its `command` through `Elia.Shell.run/2` like
    # the shell tool, so it follows the call's jail and workspace (ISOL-15).
    test "a folder skill's script tool follows the context", %{notice: notice} do
      dir = Path.join(System.tmp_dir!(), "elia-jail-folder-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      File.write!(
        Path.join(dir, "SKILL.md"),
        "---\nname: probe\ndescription: probe\n---\nprobe\n"
      )

      File.write!(
        Path.join(dir, "tools.json"),
        Jason.encode!([
          %{
            "name" => "probe",
            "description" => "probe",
            "command" => "echo hi",
            "input_schema" => %{"type" => "object", "properties" => %{}}
          }
        ])
      )

      {:ok, skill} = Elia.Skills.Folder.load(dir)
      [tool] = skill.tools

      assert {:ok, output} = Elia.Tool.call(tool, %{}, %{jail: true})
      assert output =~ notice

      assert {:ok, output} = Elia.Tool.call(tool, %{}, %{jail: false})
      refute output =~ notice
    end

    test "run_tests follows the context", %{notice: notice} do
      dir = Path.join(System.tmp_dir!(), "elia-jail-tests-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "test"))
      on_exit(fn -> File.rm_rf(dir) end)

      # No project to test, so `mix test` fails fast — enough to see the notice.
      assert {:error, output} = Elia.Harness.run_tests(["test/nope_test.exs"], dir)
      assert output =~ notice

      assert {:error, output} = Elia.Harness.run_tests(["test/nope_test.exs"], dir, jail: false)
      refute output =~ notice
    end
  end

  describe "a chat's worktree in the live tree's jail (ISOL-4, ISOL-6, ISOL-13)" do
    # A chat's commands run in a tree of its own — the worktree it makes for
    # itself inside the live tree (DEPLOY-28) — jailed to the workspace the call
    # belongs to (ISOL-13). The harness makes none, so the test makes the one a
    # chat would.
    setup do
      tree = Elia.LiveTree.create()
      previous = Application.get_env(:elia, :runtime_root)
      Application.put_env(:elia, :runtime_root, tree)

      worktree = Elia.LiveTree.worktree(tree, Elia.Agent.new_id())

      on_exit(fn ->
        Elia.LiveTree.remove(tree)

        if previous,
          do: Application.put_env(:elia, :runtime_root, previous),
          else: Application.delete_env(:elia, :runtime_root)
      end)

      %{git: Path.join(tree, ".git"), tree: tree, worktree: worktree}
    end

    # ISOL-4, DEPLOY-13: a commit and the fast-forward of `master` work from
    # inside the jail, because the repository's git directory comes with the
    # worktree.
    test "a chat still commits and fast-forwards master", %{tree: tree, worktree: worktree} do
      command =
        "printf 'x' > committed.txt && git add committed.txt && " <>
          "git -c user.name=t -c user.email=t@e commit -q -m work && " <>
          "git push -q . HEAD:master"

      assert {:ok, output, 0} = jailed(command, cd: worktree)
      refute output =~ "Read-only"

      assert Elia.LiveTree.sha(tree, "master") == Elia.LiveTree.head(worktree)
    end

    # ISOL-6: the live tree around the worktree is not bound, so Elia's data and
    # the rest of the tree are out of reach.
    test "the live tree around the worktree is not in its jail", %{tree: tree, worktree: worktree} do
      File.mkdir_p!(Path.join(tree, ".elia/sessions"))
      File.write!(Path.join(tree, ".elia/sessions/one.term"), "secret\n")
      File.write!(Path.join(tree, "outside.txt"), "outside\n")

      for path <- [Path.join(tree, "outside.txt"), Path.join(tree, ".elia/sessions/one.term")] do
        assert {:ok, output, status} = jailed("cat #{path} 2>&1", cd: worktree)
        assert status != 0, "#{path} must not be reachable inside the jail"
        assert output =~ "No such file"
      end
    end

    # DEPLOY-29: a chat's worktree holds its own copies of `deps` and `_build`,
    # which the chat copied in itself, so a command writes into its own copy —
    # and the live tree's `deps` is not bound at all (ISOL-6), so what the live
    # tree compiles against is untouched by anything a chat's command does.
    test "a command writes inside its own worktree's deps, not the live tree's", %{
      tree: tree,
      worktree: worktree
    } do
      live_deps = Path.join(tree, "deps")
      mine = Path.join(worktree, "deps/phoenix/priv/templates")
      File.mkdir_p!(mine)
      File.mkdir_p!(live_deps)
      File.write!(Path.join(live_deps, "kept.eex"), "shared\n")

      assert {:ok, output, 0} =
               jailed(
                 "echo written > deps/phoenix/priv/templates/new.eex && " <>
                   "ls deps/phoenix/priv/templates",
                 cd: worktree
               )

      assert output =~ "new.eex"
      assert File.read!(Path.join(mine, "new.eex")) == "written\n"
      assert File.read!(Path.join(live_deps, "kept.eex")) == "shared\n"
      refute File.exists?(Path.join(live_deps, "phoenix/priv/templates/new.eex"))
    end

    # ISOL-13: the jail holds the workspace, not the directory the call runs in.
    # A chat that `cd`-ed into a subdirectory reads a file beside the tree's root
    # — outside that subdirectory — because its call is jailed to the whole tree.
    test "a call in a subdirectory is jailed to the whole workspace", %{worktree: worktree} do
      sub = Path.join(worktree, "sub")
      File.mkdir_p!(sub)
      File.write!(Path.join(worktree, "root_file"), "at the root\n")

      assert {:ok, output} =
               Elia.Skills.Shell.run(%{"command" => "cat ../root_file"},
                 cwd: sub,
                 workspace: worktree,
                 jail: true
               )

      assert output =~ "at the root"
    end

    # ISOL-13, FOLDER-6, FOLDER-7: a folder skill's script runs in the skill's own
    # folder, and the jail still holds the chat's workspace — so it reaches the
    # whole project rather than only its own folder.
    test "a folder skill's script is jailed to the whole workspace", %{worktree: worktree} do
      File.write!(Path.join(worktree, "root_file"), "at the root\n")
      dir = Path.join([worktree, "skills", "probe"])
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "SKILL.md"),
        "---\nname: probe\ndescription: probe\n---\nprobe\n"
      )

      File.write!(
        Path.join(dir, "tools.json"),
        Jason.encode!([
          %{
            "name" => "probe",
            "description" => "probe",
            "command" => "echo \"ws=$ELIA_WORKSPACE\"; cat ../../root_file",
            "input_schema" => %{"type" => "object", "properties" => %{}}
          }
        ])
      )

      {:ok, skill} = Elia.Skills.Folder.load(dir)
      [tool] = skill.tools

      assert {:ok, output} = Elia.Tool.call(tool, %{}, %{jail: true, workspace: worktree})
      assert output =~ "ws=#{worktree}"
      assert output =~ "at the root"
    end
  end
end
