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

  # ISOL-7: a chat's commands see the shared dependency tree as an overlay — the
  # live tree's `deps` read-only as the lower layer, the worktree's own writable
  # layer on top — so a compile that writes inside a dependency succeeds, and
  # what the live tree and the other chats compile against is unchanged.
  test "a command writes inside the shared deps without changing it (ISOL-7)" do
    live = Elia.Workspace.runtime_root()
    id = "overlay-#{System.unique_integer([:positive])}"
    worktree = Path.join([live, ".elia", "worktrees", id])
    deps = Path.join(live, "deps")
    templates = Path.join(deps, "phoenix/priv/templates")

    File.mkdir_p!(templates)
    File.write!(Path.join(templates, "kept.eex"), "shared\n")
    File.mkdir_p!(worktree)
    File.ln_s(deps, Path.join(worktree, "deps"))

    on_exit(fn ->
      File.rm_rf!(worktree)
      File.rm_rf!(deps)
      Elia.Deps.remove(worktree, live)
    end)

    # The worktree's `deps` is the live tree's (DEPLOY-1), and a write through it
    # lands in the worktree's own layer.
    assert {:ok, output, 0} =
             jailed(
               "cat deps/phoenix/priv/templates/kept.eex && " <>
                 "echo written > deps/phoenix/priv/templates/new.eex && " <>
                 "ls deps/phoenix/priv/templates",
               cd: worktree
             )

    assert output =~ "shared"
    assert output =~ "new.eex"

    # The shared tree is unchanged: the write is in the layer, which the command
    # can't reach either (ISOL-6).
    refute File.exists?(Path.join(templates, "new.eex"))

    layer = Elia.Deps.layer(worktree, live)

    assert File.read!(Path.join([layer, "upper", "phoenix/priv/templates/new.eex"])) ==
             "written\n"

    assert {:ok, output, status} =
             jailed("ls #{Path.join(live, ".elia/deps_layer")} 2>&1", cd: worktree)

    assert status != 0
    assert output =~ "No such file"
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
end
