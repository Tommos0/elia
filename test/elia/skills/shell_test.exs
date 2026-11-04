defmodule Elia.Skills.ShellTest do
  use ExUnit.Case, async: true

  alias Elia.Skills.Shell

  test "returns output and exit code" do
    assert {:ok, "hi\n\n[exit: 0]"} = Shell.run(%{"command" => "echo hi"})
    assert {:error, output} = Shell.run(%{"command" => "echo oops >&2; exit 3"})
    assert output =~ "oops"
    assert output =~ "[exit: 3]"
  end

  # SHELL-8
  test "instructions and tool description send file work to the file tools" do
    assert String.starts_with?(
             Shell.instructions(),
             "Never use the shell to read, create or edit"
           )

    assert Shell.instructions() =~ "file tools"
    assert [%{description: description}] = Shell.tools()

    assert description =~
             "use read_file, list_files, write_file, edit_file and delete_file"
  end

  # SHELL-9
  test "instructions and tool description say which shell runs and warn off bash-only syntax" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      assert text =~ "bash -c"
      assert text =~ "POSIX"
      assert text =~ "PIPESTATUS"
      assert text =~ "set -o pipefail"
    end
  end

  # ISOL-21
  test "instructions and tool description explain the jail and when it is off" do
    assert [%{description: description}] = Shell.tools()

    for text <- [Shell.instructions(), description] do
      assert text =~ "jail by default"
      assert text =~ "workspace"
      assert text =~ "toolchain"
      assert text =~ "settings database"
      assert text =~ "saved conversations"
      assert text =~ "credentials"
      assert text =~ "expected, not broken"
      assert text =~ "unjailed"
    end
  end

  test "does not wait on stdin" do
    assert {:ok, "\n[exit: 0]"} = Shell.run(%{"command" => "cat", "timeout_seconds" => 5})
  end

  test "kills commands that time out" do
    assert {:error, output} =
             Shell.run(%{"command" => "echo start; sleep 30", "timeout_seconds" => 1})

    assert output =~ "start"
    assert output =~ "timeout after 1s"
  end
end
