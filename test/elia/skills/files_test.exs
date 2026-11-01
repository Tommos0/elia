defmodule Elia.Skills.FilesTest do
  use ExUnit.Case, async: true

  # FILE-10
  test "instructions open by sending file work to these tools, not the shell" do
    instructions = Elia.Skills.Files.instructions()

    assert String.starts_with?(instructions, "Always use these tools, never shell commands")
    assert instructions =~ "workspace policy"
    # PROJ-12: the root is the chat's project folder, not hard-coded.
    refute instructions =~ Elia.Workspace.root()
    assert instructions =~ "project folder"
  end
end
