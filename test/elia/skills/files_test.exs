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

  # FILE-23: everywhere the file tools are named, all five are.
  test "the five file tools are named together" do
    names = Elia.Skills.Files.tools() |> Enum.map(& &1.name)

    assert names == ~w(read_file write_file edit_file list_files delete_file)
    assert Elia.Skills.Files.description() =~ "list"
    assert Elia.Skills.Files.description() =~ "delete"

    instructions = Elia.Skills.Files.instructions()
    assert instructions =~ "`list_files`"
    assert instructions =~ "`delete_file`"

    assert [shell] = Enum.filter(Elia.Skills.Shell.tools(), &(&1.name == "shell"))
    assert shell.description =~ "list_files"
    assert shell.description =~ "delete_file"
  end
end
