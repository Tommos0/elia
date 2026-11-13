defmodule Elia.Skills.ShellTest do
  # The timeout settings are application-wide, and a test that exercises the
  # ceiling sets them (SHELL-10), so this module doesn't run async.
  use ExUnit.Case, async: false

  alias Elia.Skills.Shell

  test "returns output and exit code" do
    assert {:ok, "hi\n\n[exit: 0]"} = Shell.run(%{"command" => "echo hi"})
    assert {:error, output} = Shell.run(%{"command" => "echo oops >&2; exit 3"})
    assert output =~ "oops"
    assert output =~ "[exit: 3]"
  end

  # SHELL-8, FILE-24
  test "instructions and tool description send file work to the file tools" do
    assert String.starts_with?(
             Shell.instructions(),
             "Never use the shell to read, create or edit"
           )

    assert Shell.instructions() =~ "file tools"
    assert [%{description: description}] = Shell.tools()

    assert description =~
             "use read_file, list_files, search_files, write_file, edit_file and delete_file"

    # FILE-24: finding text in the tree is `search_files`, not `grep`.
    for text <- [Shell.instructions(), description] do
      assert text =~ "grep"
      assert text =~ "search_files"
    end
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

  # SHELL-10
  test "a timeout above the configured maximum runs with the maximum and says so" do
    # The settings are global, which is why this module doesn't run async.
    previous = Application.get_env(:elia, Shell, [])

    Application.put_env(:elia, Shell,
      default_timeout: 5,
      max_timeout: 1,
      max_output: 30_000
    )

    on_exit(fn -> Application.put_env(:elia, Shell, previous) end)

    assert {:error, output} =
             Shell.run(%{"command" => "echo start; sleep 30", "timeout_seconds" => 600})

    assert output =~ "start"
    assert output =~ "timeout after 1s (asked for 600s, the most is 1s)"

    # The tool's description names the default and the ceiling, so a long run is
    # asked for rather than run into (SHELL-8, SHELL-9).
    [tool] = Shell.tools()
    text = get_in(tool.input_schema, ["properties", "timeout_seconds", "description"])

    assert text =~ "The default is 5"
    assert text =~ "the most is 1"
  end

  # SHELL-10
  test "a timeout that isn't a whole number of seconds of at least 1 is refused" do
    assert {:error, output} = Shell.run(%{"command" => "echo hi", "timeout_seconds" => 0})
    assert output =~ "timeout_seconds must be a whole number of seconds of at least 1"
    assert output =~ "the default is 300s and the most is 1800s"
    refute output =~ "hi"

    assert {:error, _} = Shell.run(%{"command" => "echo hi", "timeout_seconds" => -5})
  end
end
