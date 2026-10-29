defmodule Elia.Skills.ShellTest do
  use ExUnit.Case, async: true

  alias Elia.Skills.Shell

  test "returns output and exit code" do
    assert {:ok, "hi\n\n[exit: 0]"} = Shell.run(%{"command" => "echo hi"})
    assert {:error, output} = Shell.run(%{"command" => "echo oops >&2; exit 3"})
    assert output =~ "oops"
    assert output =~ "[exit: 3]"
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
