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

    # WS-5: the classes are decided on the path as written, so a caller that
    # must not be fooled by a link asks for the real location instead.
    test "the real location follows symlinks, and a missing path by its ancestor" do
      outside = Path.join(System.tmp_dir!(), "elia-real-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "file.txt"), "x")
      File.mkdir_p!(in_root("real"))
      File.ln_s!(outside, in_root("real/link"))
      File.ln_s!(Path.join(outside, "gone.txt"), in_root("real/broken"))

      on_exit(fn ->
        File.rm_rf!(in_root("real"))
        File.rm_rf!(outside)
      end)

      assert Workspace.real_location(in_root("real/link/file.txt")) ==
               Path.join(outside, "file.txt")

      # A path that isn't there yet is judged by where it would land.
      assert Workspace.real_location(in_root("real/link/new/deep.txt")) ==
               Path.join([outside, "new", "deep.txt"])

      # `File.realpath/1` gives up on a link whose target is missing; the link
      # is followed by hand instead.
      assert Workspace.real_location(in_root("real/broken")) ==
               Path.join(outside, "gone.txt")

      assert Workspace.real_location(in_root("real")) == in_root("real")
    end
  end

  describe "the file tools under the jail" do
    # FILE-12, FILE-13: with the jail on, the file tools reach what a jailed
    # command in this workspace reaches and nothing else (ISOL-25). The suite
    # runs with the jail off (config/test.exs), so each test turns it on.
    setup do
      previous = Application.get_env(:elia, Elia.Shell)
      Application.put_env(:elia, Elia.Shell, jail: true)
      on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
      :ok
    end

    # FILE-12
    test "reads outside the workspace are refused, not offered for approval" do
      assert {:deny, reason} = Files.read_policy(%{"path" => "/etc/hostname"}, %{jail: true})
      assert reason =~ "/etc/hostname"
      assert reason =~ "jail"

      assert {:error, reason} = Files.read_file(%{"path" => "/etc/hostname"}, %{jail: true})
      assert reason =~ "outside the workspace"

      assert {:deny, _} = Files.write_policy(%{"path" => "/tmp/x"}, %{jail: true})

      # The chat's own setting, and the host's, is what turns the confinement
      # off (ISOL-16, ISOL-20) — not bubblewrap (ISOL-12). A caller with no chat
      # gets the default, which is on (ISOL-15).
      assert Files.read_policy(%{"path" => "/etc/hostname"}, %{jail: false}) == :required
      assert {:deny, _} = Files.read_policy(%{"path" => "/etc/hostname"}, %{})

      Application.put_env(:elia, Elia.Shell, jail: false)
      assert Files.read_policy(%{"path" => "/etc/hostname"}, %{jail: true}) == :required
    end

    # FILE-12: the workspace is untouched by it.
    test "the workspace itself is still fully usable" do
      assert Files.read_policy(%{"path" => "lib/x.ex"}, %{jail: true}) == :never
      assert Files.write_policy(%{"path" => "lib/x.ex"}, %{jail: true}) == :required
      assert Files.write_policy(%{"path" => "skills/x/SKILL.md"}, %{jail: true}) == :never

      ctx = %{jail: true}
      assert {:ok, _} = Files.write_file(%{"path" => "notes/a.txt", "content" => "hi"}, ctx)
      assert {:ok, "hi"} = Files.read_file(%{"path" => "notes/a.txt"}, ctx)
    after
      File.rm_rf!(in_root("notes"))
    end

    # FILE-13
    test "a link out of the workspace is refused, and named for where it goes" do
      outside = Path.join(System.tmp_dir!(), "elia-outside-#{System.unique_integer([:positive])}")
      File.write!(outside, "not for the tools")
      File.ln_s!(outside, in_root("link-out"))
      File.ln_s!(Path.dirname(outside), in_root("link-dir"))

      on_exit(fn ->
        File.rm(in_root("link-out"))
        File.rm(in_root("link-dir"))
        File.rm(outside)
      end)

      assert {:deny, reason} = Files.read_policy(%{"path" => "link-out"}, %{jail: true})
      assert reason =~ "resolves to #{outside}"

      assert {:error, reason} = Files.read_file(%{"path" => "link-out"}, %{jail: true})
      assert reason =~ "resolves to #{outside}"

      # A write that would land outside through a link is refused too.
      assert {:deny, _} =
               Files.write_policy(%{"path" => "link-dir/evil.txt"}, %{jail: true})

      assert {:error, _} =
               Files.write_file(
                 %{"path" => "link-dir/evil.txt", "content" => "x"},
                 %{jail: true}
               )

      # Unjailed the link is an ordinary workspace path (FILE-12, FILE-13): it
      # is the jail that refuses it.
      assert Files.read_policy(%{"path" => "link-out"}, %{jail: false}) == :never
      assert {:ok, "not for the tools"} = Files.read_file(%{"path" => "link-out"}, %{jail: false})
      assert Files.write_policy(%{"path" => "link-dir/evil.txt"}, %{jail: false}) == :required
    end

    # FILE-13, ISOL-13: a chat worktree reaches the trees its jail profile also
    # binds — the shared deps and the repository's git directory.
    test "a worktree reaches the shared deps and the repo's git dir" do
      live = Workspace.root()
      worktree = Path.join([live, ".elia", "worktrees", "reach"])
      File.mkdir_p!(Path.join([live, "deps", "shared"]))
      File.write!(Path.join([live, "deps", "shared", "mix.exs"]), "x")
      File.write!(Path.join(live, "outside.txt"), "x")
      File.mkdir_p!(worktree)
      File.ln_s!(Path.join(live, "deps"), Path.join(worktree, "deps"))
      File.ln_s!(Path.join(live, ".git"), Path.join(worktree, ".gitdir"))

      on_exit(fn ->
        File.rm_rf!(worktree)
        File.rm_rf!(Path.join(live, "deps"))
        File.rm(Path.join(live, "outside.txt"))
      end)

      ctx = %{jail: true, workspace: worktree}

      # `deps` is a link to the shared tree, which the jail binds (ISOL-7).
      assert Files.read_policy(%{"path" => "deps/shared/mix.exs"}, ctx) == :never
      assert Files.read_policy(%{"path" => ".gitdir/config"}, ctx) == :never

      # The live tree around the worktree is not bound, so it is out of reach,
      # by an absolute path or one that leaves the worktree (ISOL-6).
      assert {:deny, _} = Files.read_policy(%{"path" => Path.join(live, "outside.txt")}, ctx)
      assert {:deny, _} = Files.read_policy(%{"path" => "../outside.txt"}, ctx)
      assert {:deny, _} = Files.read_policy(%{"path" => "/etc/hostname"}, ctx)
    end

    # FILE-13, ISOL-6: a chat that works in the live tree itself (DEPLOY-14)
    # reaches the tree but not the `.elia` its jail masks.
    test "the live tree's own .elia is out of reach" do
      assert {:deny, _} =
               Files.read_policy(%{"path" => ".elia/sessions/chat.json"}, %{jail: true})

      assert {:error, _} =
               Files.read_file(%{"path" => ".elia/sessions/chat.json"}, %{jail: true})

      # Unjailed it is an ordinary protected path: not writable, readable.
      assert Files.read_policy(%{"path" => ".elia/sessions/chat.json"}, %{jail: false}) == :never
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
