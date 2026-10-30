defmodule Elia.Skills.FilesTest do
  use ExUnit.Case, async: true

  # FILE-10
  test "instructions open by sending file work to these tools, not the shell" do
    instructions = Elia.Skills.Files.instructions()

    assert String.starts_with?(instructions, "Always use these tools, never shell commands")
    assert instructions =~ "workspace policy"
  end
end
