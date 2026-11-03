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

  test "the home directory is stripped to what mix needs (ISOL-4, ISOL-5, ISOL-8)" do
    assert {:ok, output, 0} = jailed("ls -A $HOME")
    assert String.split(output, "\n", trim: true) in [[], [".mix"]]
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
end
