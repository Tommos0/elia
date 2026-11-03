defmodule Elia.SelfModificationTest do
  use ExUnit.Case, async: false

  alias Elia.{Harness, Workspace}
  alias Elia.Skills.{Files, Folder}

  defp in_root(path), do: Path.join(Workspace.root(), path)

  describe "workspace policy" do
    test "classifies paths" do
      assert {_, :extension} = Workspace.resolve("skills/foo/SKILL.md")
      assert {_, :core} = Workspace.resolve("lib/elia/agent.ex")
      assert {_, :protected} = Workspace.resolve(".git/config")
      assert {_, :protected} = Workspace.resolve("deps/req/mix.exs")
      assert {_, :outside} = Workspace.resolve("../elsewhere")
      assert {_, :outside} = Workspace.resolve("/etc/passwd")
      assert {_, :outside} = Workspace.resolve("skills/../../etc")
    end

    test "symlinks under skills/ are treated as core" do
      File.mkdir_p!(in_root("skills"))
      File.mkdir_p!(in_root("lib"))
      File.ln_s!(in_root("lib"), in_root("skills/sneaky"))
      assert {_, :core} = Workspace.resolve("skills/sneaky/agent.ex")
    after
      File.rm(in_root("skills/sneaky"))
    end

    test "file tools ask, allow or deny accordingly" do
      assert Files.write_policy(%{"path" => "skills/x/SKILL.md"}, %{}) == :never
      assert Files.write_policy(%{"path" => "lib/x.ex"}, %{}) == :required
      assert {:deny, _} = Files.write_policy(%{"path" => ".git/hooks/pre-commit"}, %{})
      assert {:deny, _} = Files.write_policy(%{"path" => "/tmp/x"}, %{})
      assert Files.read_policy(%{"path" => "lib/x.ex"}, %{}) == :never
      assert Files.read_policy(%{"path" => "/etc/hostname"}, %{}) == :required
    end
  end

  describe "file tools" do
    test "write, read and edit" do
      path = "skills/notes/a.txt"
      assert {:ok, _} = Files.write_file(%{"path" => path, "content" => "one\ntwo\ntwo\n"}, %{})
      assert {:ok, "one\ntwo\ntwo\n"} = Files.read_file(%{"path" => path})

      assert {:ok, "[lines 2-2 of 4]\ntwo"} =
               Files.read_file(%{"path" => path, "offset" => 2, "limit" => 1})

      assert {:error, "old_string occurs 2 times" <> _} =
               Files.edit_file(%{"path" => path, "old_string" => "two", "new_string" => "2"}, %{})

      assert {:ok, _} =
               Files.edit_file(
                 %{"path" => path, "old_string" => "one\ntwo", "new_string" => "1\n2"},
                 %{}
               )

      assert {:ok, "1\n2\ntwo\n"} = Files.read_file(%{"path" => path})
    after
      File.rm_rf!(in_root("skills/notes"))
    end

    # FILE-11
    test "concurrent edits of one file all apply" do
      path = "skills/notes/concurrent.txt"
      lines = for i <- 1..30, do: "line#{i}"
      File.mkdir_p!(in_root("skills/notes"))
      File.write!(in_root(path), Enum.join(lines, "\n") <> "\n")

      results =
        lines
        |> Task.async_stream(
          fn line ->
            Files.edit_file(
              %{"path" => path, "old_string" => line <> "\n", "new_string" => line <> "!\n"},
              %{}
            )
          end,
          max_concurrency: 30,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert File.read!(in_root(path)) == Enum.map_join(lines, "", &(&1 <> "!\n"))
    after
      File.rm_rf!(in_root("skills/notes"))
    end
  end

  describe "folder skills" do
    setup do
      dir = in_root("skills/tmp-skill")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "reports helpful errors", %{dir: dir} do
      assert {:error, "cannot read SKILL.md" <> _} = Folder.load(dir)

      File.write!(Path.join(dir, "SKILL.md"), "no frontmatter")
      assert {:error, "SKILL.md must start" <> _} = Folder.load(dir)

      File.write!(Path.join(dir, "SKILL.md"), "---\nname: Bad Name\ndescription: x\n---\n")
      assert {:error, "name \"Bad Name\" must match" <> _} = Folder.load(dir)

      File.write!(Path.join(dir, "SKILL.md"), "---\nname: ok\ndescription: x\n---\nBody")
      File.write!(Path.join(dir, "tools.json"), ~s([{"name": "t"}]))
      assert {:error, "tools.json entry 0: missing description"} = Folder.load(dir)
    end

    test "registry reports load errors and conflicts", %{dir: dir} do
      File.write!(Path.join(dir, "SKILL.md"), "---\nname: shell\ndescription: dup\n---\n")
      %{errors: errors} = Elia.Skills.reload()
      assert {"skills/tmp-skill", "a skill named shell already exists"} in errors
    after
      File.rm_rf!(dir)
      Elia.Skills.reload()
    end
  end

  describe "self-modification" do
    # SKILL-7, PROJ-17
    test "is a built-in skill with no tools of its own" do
      assert Elia.Skills.SelfModification in Elia.Skills.builtin()
      assert Elia.Skills.SelfModification.name() == "self-modification"
      assert Elia.Skills.SelfModification.tools() == []
    end

    # SKILL-9, PROJ-17
    test "instructions carry the guardrails and the spec workflow" do
      instructions = Elia.Skills.SelfModification.instructions()

      assert instructions =~ "approval"
      assert instructions =~ "Nothing verifies a turn"
      assert instructions =~ "rolled back"
      # DEPLOY-13: merging its own branch into the trunk is where the agent's
      # part ends; deploying is the user's step, from Settings (SKILL-9).
      assert instructions =~ "git push . HEAD:master"
      assert instructions =~ "Settings"
      refute instructions =~ "hot_reload"
      assert instructions =~ "specs/README.md"
      assert instructions =~ "requirement IDs"
      assert instructions =~ "Never renumber"
      # Folder skills apply in every project: they are the harness skill's.
      refute instructions =~ "folder skill"
    end
  end

  describe "run_tests" do
    test "rejects arguments that could run arbitrary code" do
      assert {:error, "Unsupported test argument: skills/x_test.exs"} =
               Harness.run_tests(["skills/x_test.exs"])

      assert {:error, _} = Harness.run_tests(["test/../skills/x_test.exs"])
      assert {:error, _} = Harness.run_tests(["--seed", "1; rm -rf /"])
      assert {:error, _} = Harness.run_tests(["--include-anything"])
    end
  end
end
