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
