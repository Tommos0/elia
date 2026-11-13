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

  defp tool(name), do: Elia.Skills.Files.tools() |> Enum.find(&(&1.name == name))

  # FILE-37: no argument of `edit_file` defaults. `new_string` in particular
  # does not default to empty: the calls it would rescue are calls whose
  # replacement text went out under a misspelled key (`new_text`, `new_str`),
  # and an empty default would turn each into a deletion its caller never asked
  # for.
  test "edit_file requires all three of its arguments" do
    edit = tool("edit_file")

    assert edit.input_schema["required"] == ["path", "old_string", "new_string"]
    assert edit.input_schema["properties"]["new_string"]["description"] =~ "empty"
    assert edit.input_schema["properties"]["replace_all"]["description"] =~ "every occurrence"

    # A call that omits `new_string`, and one that carries it under another
    # name, are both refused before the tool runs, so neither can edit anything.
    assert {:error, reason} = Elia.Tool.validate(edit, %{"path" => "a", "old_string" => "b"})
    assert reason =~ "new_string is required"

    assert {:error, reason} =
             Elia.Tool.validate(edit, %{"path" => "a", "old_string" => "b", "new_text" => "c"})

    assert reason =~ "new_string is required"
  end

  # FILE-38: the model reads the description and the instructions, so both say
  # how a match is found — and that an ambiguous one is never guessed at.
  test "the description and the instructions state the match rules" do
    description = tool("edit_file").description
    instructions = Elia.Skills.Files.instructions()

    for text <- [description, instructions] do
      assert text =~ "exact"
      assert text =~ "ignoring indentation, trailing whitespace and line endings"
      assert text =~ "unique"
      assert text =~ "never a guess"
    end

    assert description =~ "empty `new_string` removes"
  end
end
