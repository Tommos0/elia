defmodule Elia.SelfModificationTest do
  use ExUnit.Case, async: false

  alias Elia.{Harness, Workspace}
  alias Elia.Skills.{Files, Folder}

  defp in_root(path), do: Path.join(Workspace.root(), path)

  # One throwaway project for the whole module (VERIFY-8, VERIFY-9): the runs
  # below are real `mix test` runs, and sharing one tree keeps them to a single
  # compile — and costs the other tests in the module nothing but a temp dir.
  setup_all do
    %{hangs_tree: hanging_tree()}
  end

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

      # FILE-18: listing with no path means the workspace root, inside like any
      # other workspace path.
      assert Files.read_policy(%{}, %{}) == :never

      # FILE-21: deleting follows the write policy.
      assert Files.delete_policy(%{"path" => "skills/x/SKILL.md"}, %{}) == :never
      assert Files.delete_policy(%{"path" => "lib/x.ex"}, %{}) == :required
      assert {:deny, _} = Files.delete_policy(%{"path" => ".git/hooks/pre-commit"}, %{})
      assert {:deny, _} = Files.delete_policy(%{"path" => "/tmp/x"}, %{})
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

    # FILE-18: listing follows the read policy, so under the jail a path
    # outside the workspace is refused, not offered for approval (FILE-12).
    test "listing outside the workspace is refused" do
      assert {:deny, reason} = Files.read_policy(%{"path" => "/etc"}, %{jail: true})
      assert reason =~ "outside the workspace"

      assert {:error, reason} = Files.list_files(%{"path" => "/etc"}, %{jail: true})
      assert reason =~ "outside the workspace"

      # Unjailed it is the user's to approve (FILE-4); the workspace itself is
      # always listed.
      assert Files.read_policy(%{"path" => "/etc"}, %{jail: false}) == :required
      assert {:ok, "[. (" <> _} = Files.list_files(%{}, %{jail: true})
    end

    # FILE-20, FILE-13: deleting a link that resolves out of the workspace is
    # refused under the jail, as reading or writing it would be.
    test "deleting a link out of the workspace is refused" do
      outside = Path.join(System.tmp_dir!(), "elia-del-#{System.unique_integer([:positive])}")
      File.write!(outside, "keep me")
      File.ln_s!(outside, in_root("link-del"))

      on_exit(fn ->
        File.rm(in_root("link-del"))
        File.rm(outside)
      end)

      assert {:error, reason} = Files.delete_file(%{"path" => "link-del"}, %{jail: true})
      assert reason =~ "resolves to #{outside}"
      assert File.read!(outside) == "keep me"
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

    # FILE-15, FILE-16, FILE-17
    test "lists a directory, directories first and sorted" do
      dir = "skills/notes/list"
      File.mkdir_p!(in_root(Path.join(dir, "sub")))
      File.write!(in_root(Path.join(dir, "b.txt")), "b")
      File.write!(in_root(Path.join(dir, "A.txt")), "abc")
      File.ln_s!("/tmp", in_root(Path.join(dir, "link")))

      on_exit(fn -> File.rm_rf!(in_root("skills/notes")) end)

      assert {:ok, out} = Files.list_files(%{"path" => dir}, %{})

      assert String.split(out, "\n") == [
               "[skills/notes/list (4 entries)]",
               "skills/notes/list/sub/",
               "skills/notes/list/A.txt (3 bytes)",
               "skills/notes/list/b.txt (1 bytes)",
               "skills/notes/list/link -> /tmp"
             ]

      # No path means the workspace root, named `.`.
      assert {:ok, "[. (" <> _} = Files.list_files(%{}, %{})

      # FILE-16: `limit` lowers the count and says what was left out.
      assert {:ok, out} = Files.list_files(%{"path" => dir, "limit" => 2}, %{})
      assert out |> String.split("\n") |> List.last() == "[+2 more entries]"

      many = "skills/notes/many"
      File.mkdir_p!(in_root(many))
      Enum.each(1..205, &File.write!(in_root("#{many}/f#{&1}"), "x"))

      # `limit` can never raise the cap: 205 entries still show 200.
      assert {:ok, out} = Files.list_files(%{"path" => many, "limit" => 500}, %{})
      lines = String.split(out, "\n")
      assert length(lines) == 202
      assert List.last(lines) == "[+5 more entries]"

      # FILE-17: an empty directory is the header alone; a file or a missing
      # path fails, naming it.
      File.mkdir_p!(in_root("skills/notes/empty"))

      assert {:ok, "[skills/notes/empty (0 entries)]"} =
               Files.list_files(%{"path" => "skills/notes/empty"}, %{})

      assert {:error, reason} = Files.list_files(%{"path" => "#{dir}/A.txt"}, %{})
      assert reason =~ "Cannot list #{dir}/A.txt"

      assert {:error, reason} = Files.list_files(%{"path" => "skills/notes/gone"}, %{})
      assert reason =~ "Cannot list skills/notes/gone"
    end

    # FILE-19, FILE-20
    test "deletes a file and an empty directory, and refuses the rest" do
      dir = "skills/notes/del"
      File.mkdir_p!(in_root(Path.join(dir, "sub")))
      File.write!(in_root(Path.join(dir, "a.txt")), "x")
      File.write!(in_root(Path.join(dir, "sub/b.txt")), "y")

      on_exit(fn -> File.rm_rf!(in_root("skills/notes")) end)

      assert {:ok, "Deleted skills/notes/del/a.txt"} =
               Files.delete_file(%{"path" => "#{dir}/a.txt"}, %{})

      refute File.exists?(in_root("#{dir}/a.txt"))

      assert {:error, "skills/notes/del/sub is not empty"} =
               Files.delete_file(%{"path" => "#{dir}/sub"}, %{})

      assert File.read!(in_root("#{dir}/sub/b.txt")) == "y"

      File.mkdir_p!(in_root("#{dir}/empty"))

      assert {:ok, "Deleted skills/notes/del/empty"} =
               Files.delete_file(%{"path" => "#{dir}/empty"}, %{})

      refute File.exists?(in_root("#{dir}/empty"))

      assert {:error, reason} = Files.delete_file(%{"path" => "#{dir}/a.txt"}, %{})
      assert reason =~ "Cannot delete skills/notes/del/a.txt"

      # FILE-20: the link goes, what it points at stays.
      File.ln_s!(in_root("#{dir}/sub/b.txt"), in_root("#{dir}/link"))

      assert {:ok, "Deleted skills/notes/del/link"} =
               Files.delete_file(%{"path" => "#{dir}/link"}, %{})

      refute File.exists?(in_root("#{dir}/link"))
      assert File.read!(in_root("#{dir}/sub/b.txt")) == "y"
    end

    # FILE-22: a delete waits for the lock the writers use (FILE-11).
    test "a delete takes the same per-file lock as a write" do
      path = "skills/notes/locked.txt"
      abs = in_root(path)
      File.mkdir_p!(in_root("skills/notes"))
      File.write!(abs, "x")
      parent = self()

      on_exit(fn -> File.rm_rf!(in_root("skills/notes")) end)

      holder =
        Task.async(fn ->
          :global.trans(
            {{Files, abs}, self()},
            fn ->
              send(parent, :held)

              receive do
                :release -> :ok
              end
            end,
            [node()]
          )
        end)

      assert_receive :held, 500
      deleter = Task.async(fn -> Files.delete_file(%{"path" => path}, %{}) end)

      # Still waiting while the lock is held, and done once it is free.
      assert Task.yield(deleter, 100) == nil
      send(holder.pid, :release)
      assert {:ok, "Deleted skills/notes/locked.txt"} = Task.await(deleter, 5_000)
      assert Task.await(holder, 5_000) == :ok
      refute File.exists?(abs)
    end
  end

  describe "search_files" do
    @dir "skills/notes/search"

    defp notes!(files) do
      File.mkdir_p!(in_root(@dir))

      for {name, content} <- files do
        File.mkdir_p!(in_root(Path.join(@dir, Path.dirname(name))))
        File.write!(in_root(Path.join(@dir, name)), content)
      end

      on_exit(fn -> File.rm_rf!(in_root("skills/notes")) end)
    end

    # FILE-25, FILE-26: one call returns the matched regions — a `path:line`
    # header and the lines around the match, the matched ones marked — so a
    # search doesn't need a `read_file` after it.
    test "returns the matched regions with their context" do
      notes!(%{"a.txt" => "one\ntwo\nthree\nfour\nfive\n"})

      assert {:ok, out} =
               Files.search_files(%{"pattern" => "three", "path" => @dir, "context" => 1}, %{})

      assert String.split(out, "\n") == [
               "[1 matches in 1 files]",
               "#{@dir}/a.txt:3",
               "  2 | two",
               "> 3 | three",
               "  4 | four"
             ]
    end

    # FILE-26: regions that overlap or touch are one, so no line is shown twice.
    test "nearby matches form one region, far apart ones two" do
      notes!(%{"m.txt" => "1\nhit\n3\nhit\n5\n6\n7\n8\n9\n10\n11\nhit\n13\n14\n15\n"})

      assert {:ok, out} = Files.search_files(%{"pattern" => "hit", "path" => @dir}, %{})

      assert String.split(out, "\n") == [
               "[3 matches in 1 files]",
               "#{@dir}/m.txt:2",
               "  1 | 1",
               "> 2 | hit",
               "  3 | 3",
               "> 4 | hit",
               "  5 | 5",
               "  6 | 6",
               "#{@dir}/m.txt:12",
               "  10 | 10",
               "  11 | 11",
               "> 12 | hit",
               "  13 | 13",
               "  14 | 14"
             ]
    end

    # FILE-25: the pattern is literal text, matched case-sensitively.
    test "matches literally, not as a regular expression" do
      notes!(%{"r.txt" => "abc\na.c\nABC\n"})

      assert {:ok, out} = Files.search_files(%{"pattern" => "a.c", "path" => @dir}, %{})

      assert out =~ "[1 matches in 1 files]"
      assert out =~ "> 2 | a.c"
      refute out =~ "> 1 | abc"
      refute out =~ "> 3 | ABC"
    end

    # FILE-25: `glob` picks the files — by name when it has no `/` in it, by the
    # path relative to the search root when it has, and `**/` matches no
    # directory at all as well.
    test "a glob picks the files" do
      notes!(%{
        "a.ex" => "needle\n",
        "a.txt" => "needle\n",
        "sub/b.ex" => "needle\n",
        "sub/deep/c.exs" => "needle\n"
      })

      assert {:ok, out} =
               Files.search_files(%{"pattern" => "needle", "path" => @dir, "glob" => "*.ex"}, %{})

      assert out =~ "#{@dir}/a.ex:1"
      assert out =~ "#{@dir}/sub/b.ex:1"
      refute out =~ "a.txt"
      refute out =~ "c.exs"

      assert {:ok, out} =
               Files.search_files(
                 %{"pattern" => "needle", "path" => @dir, "glob" => "**/*.ex"},
                 %{}
               )

      assert out =~ "#{@dir}/a.ex:1"
      assert out =~ "#{@dir}/sub/b.ex:1"

      assert {:ok, out} =
               Files.search_files(
                 %{"pattern" => "needle", "path" => @dir, "glob" => "sub/**/*.exs"},
                 %{}
               )

      assert out =~ "#{@dir}/sub/deep/c.exs:1"
      refute out =~ "a.ex"

      # A glob that matches nothing is not an error, just no matches.
      assert {:ok, "[no matches for \"needle\"]"} =
               Files.search_files(%{"pattern" => "needle", "path" => @dir, "glob" => "*.md"}, %{})

      # A file named as the path is searched whatever the glob says (FILE-25).
      assert {:ok, out} =
               Files.search_files(
                 %{"pattern" => "needle", "path" => "#{@dir}/a.txt", "glob" => "*.ex"},
                 %{}
               )

      assert out =~ "#{@dir}/a.txt:1"
    end

    # FILE-26: files in the order of their paths, lines in line order.
    test "files come in the order of their paths" do
      notes!(%{"b.txt" => "hit\n", "A.txt" => "hit\n", "sub/z.txt" => "hit\n"})

      assert {:ok, out} = Files.search_files(%{"pattern" => "hit", "path" => @dir}, %{})

      assert out
             |> String.split("\n")
             |> Enum.filter(&String.ends_with?(&1, ":1")) == [
               "#{@dir}/A.txt:1",
               "#{@dir}/b.txt:1",
               "#{@dir}/sub/z.txt:1"
             ]
    end

    # FILE-27: at most `limit` matched lines, a region only as far as the budget
    # allows, and the header counting everything found so the model can narrow
    # the search instead of paging.
    test "caps the matched lines and says what was left out" do
      notes!(%{"many.txt" => Enum.map_join(1..10, "", &"line#{&1} needle\n")})

      assert {:ok, out} =
               Files.search_files(
                 %{"pattern" => "needle", "path" => @dir, "context" => 0, "limit" => 4},
                 %{}
               )

      assert String.split(out, "\n") == [
               "[10 matches in 1 files]",
               "#{@dir}/many.txt:1",
               "> 1 | line1 needle",
               "> 2 | line2 needle",
               "> 3 | line3 needle",
               "> 4 | line4 needle",
               "[+6 more matches not shown]"
             ]

      # `limit` can never raise the cap (FILE-25).
      assert {:ok, out} =
               Files.search_files(
                 %{"pattern" => "needle", "path" => @dir, "context" => 0, "limit" => 500},
                 %{}
               )

      refute out =~ "more matches not shown"
      assert Enum.count(String.split(out, "\n"), &String.starts_with?(&1, "> ")) == 10
    end

    # FILE-27: a line longer than 400 characters is cut, so a minified file
    # can't fill the result.
    test "cuts a very long line" do
      notes!(%{"long.txt" => String.duplicate("x", 500) <> " needle\n"})

      assert {:ok, out} =
               Files.search_files(%{"pattern" => "needle", "path" => @dir, "context" => 0}, %{})

      assert ["[1 matches in 1 files]", "#{@dir}/long.txt:1", line] = String.split(out, "\n")
      assert line == "> 1 | " <> String.duplicate("x", 399) <> "…"
    end

    # FILE-28: binary files and symlinks are skipped, and so is a protected
    # directory (WS-1) — unless it is named as the path, since reading it isn't
    # refused either (FILE-15).
    test "skips binary files, symlinks and the protected directories" do
      notes!(%{"text.txt" => "needle\n", "target.txt" => "needle\n"})
      File.write!(in_root("#{@dir}/binary.bin"), "needle" <> <<0xFF, 0xFE>> <> "\n")
      File.ln_s!(in_root("#{@dir}/target.txt"), in_root("#{@dir}/link.txt"))
      File.mkdir_p!(in_root("_build/search"))
      File.write!(in_root("_build/search/hidden.txt"), "needle\n")

      on_exit(fn -> File.rm_rf!(in_root("_build/search")) end)

      assert {:ok, out} = Files.search_files(%{"pattern" => "needle", "path" => @dir}, %{})
      assert out =~ "#{@dir}/text.txt:1"
      assert out =~ "#{@dir}/target.txt:1"
      refute out =~ "binary.bin"
      refute out =~ "link.txt"

      # From the workspace root, `_build` is not walked into...
      assert {:ok, out} = Files.search_files(%{"pattern" => "needle"}, %{})
      assert out =~ "#{@dir}/text.txt:1"
      refute out =~ "_build"

      # ...but naming it as the path searches it.
      assert {:ok, out} =
               Files.search_files(%{"pattern" => "needle", "path" => "_build/search"}, %{})

      assert out =~ "_build/search/hidden.txt:1"
    end

    # FILE-29: a search follows the read policy — never inside the workspace,
    # approval outside it, and under the jail a path outside it is refused
    # (FILE-12), the run enforcing the same refusal.
    test "approval follows the read policy" do
      # The suite runs with the jail off (config/test.exs); this test turns the
      # host's on, since the host's setting is what turns the confinement off
      # (ISOL-20), as the file-tools-under-the-jail tests do.
      previous = Application.get_env(:elia, Elia.Shell)
      Application.put_env(:elia, Elia.Shell, jail: true)
      on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

      [tool] = Enum.filter(Files.tools(), &(&1.name == "search_files"))
      policy = fn input, ctx -> Elia.Tool.approval(tool, input, ctx) end

      assert policy.(%{"pattern" => "x", "path" => "lib"}, %{}) == :never
      assert policy.(%{"pattern" => "x"}, %{}) == :never
      assert policy.(%{"pattern" => "x", "path" => "/etc"}, %{jail: false}) == :required

      assert {:deny, reason} = policy.(%{"pattern" => "x", "path" => "/etc"}, %{jail: true})
      assert reason =~ "outside the workspace"

      assert {:error, reason} =
               Files.search_files(%{"pattern" => "x", "path" => "/etc"}, %{jail: true})

      assert reason =~ "outside the workspace"

      # A link out of the workspace is refused for where it goes (FILE-13).
      outside = Path.join(System.tmp_dir!(), "elia-search-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "notes.txt"), "needle\n")
      File.ln_s!(outside, in_root("link-search"))

      on_exit(fn ->
        File.rm(in_root("link-search"))
        File.rm_rf!(outside)
      end)

      assert {:deny, reason} =
               policy.(%{"pattern" => "needle", "path" => "link-search"}, %{jail: true})

      assert reason =~ "resolves to #{outside}"

      assert {:error, reason} =
               Files.search_files(%{"pattern" => "needle", "path" => "link-search"}, %{jail: true})

      assert reason =~ "resolves to #{outside}"
    end

    # FILE-30: a path that isn't there, or is neither a file nor a directory,
    # fails; nothing matching is its own result; and an empty pattern is an
    # error rather than every line in the tree.
    test "reports a missing path, no matches and an empty pattern" do
      notes!(%{"a.txt" => "one\n"})

      assert {:ok, "[no matches for \"needle\"]"} =
               Files.search_files(%{"pattern" => "needle", "path" => @dir}, %{})

      assert {:error, reason} =
               Files.search_files(%{"pattern" => "needle", "path" => "#{@dir}/gone"}, %{})

      assert reason =~ "Cannot search #{@dir}/gone"
      assert reason =~ "no such file or directory"

      # A broken symlink is neither a file nor a directory.
      File.ln_s!(in_root("#{@dir}/nowhere.txt"), in_root("#{@dir}/broken"))

      assert {:error, reason} =
               Files.search_files(%{"pattern" => "needle", "path" => "#{@dir}/broken"}, %{})

      assert reason =~ "no such file or directory"

      assert {:error, "pattern must not be empty"} =
               Files.search_files(%{"pattern" => "", "path" => @dir}, %{})
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

    # VERIFY-8: the per-test timeout is `mix test`'s own, so a test that sets no
    # timeout of its own fails the run instead of holding it. A real run in a
    # throwaway project, because the flag has to reach ExUnit.
    test "the per-test timeout reaches ExUnit", %{hangs_tree: tree} do
      assert {:error, output} =
               Harness.run_tests(["test/hangs_test.exs"], tree,
                 jail: false,
                 timeout_seconds: 120,
                 test_timeout_ms: 1_000
               )

      assert output =~ "timed out after 1000ms"
      assert output =~ "[exit: 2]"
    end

    # VERIFY-9, VERIFY-10: the run's own timeout is the configured one, a call
    # may ask for another within the ceiling — and a run stopped by it says so
    # and names the lever, rather than reading as a suite that failed.
    test "the run's timeout is the configured one, clamped to the configured maximum", %{
      hangs_tree: tree
    } do
      previous = Application.get_env(:elia, Harness, [])

      Application.put_env(:elia, Harness, Keyword.merge(previous, timeout: 2, max_timeout: 3))
      on_exit(fn -> Application.put_env(:elia, Harness, previous) end)

      # A call that gives none gets the default, and it holds however long the
      # suite would otherwise run.
      assert {:error, output} = Harness.run_tests(["test/hangs_test.exs"], tree, jail: false)
      assert output =~ "[exit: timeout after 2s]"
      assert output =~ "stopped by its timeout (2s)"
      assert output =~ "`timeout_seconds`"

      # A call that asks for more than the maximum runs with the maximum, and is
      # told which ceiling it hit (SHELL-10).
      assert {:error, output} =
               Harness.run_tests(["test/hangs_test.exs"], tree,
                 jail: false,
                 timeout_seconds: 9_999
               )

      assert output =~ "[exit: timeout after 3s (asked for 9999s, the most is 3s)]"
      assert output =~ "stopped by its timeout (3s)"
    end

    # VERIFY-9: a timeout that isn't one changes nothing and runs nothing.
    test "rejects a timeout that isn't a whole number of at least 1" do
      assert {:error, output} = Harness.run_tests([], "test", timeout_seconds: 0)

      assert output =~ "timeout_seconds must be a whole number of at least 1"
      assert output =~ "the default is 600 and the most is 1800"

      assert {:error, output} = Harness.run_tests([], "test", test_timeout_ms: -1)

      assert output =~ "test_timeout_ms must be a whole number of at least 1"
      assert output =~ "the default is 60000 and the most is 600000"
    end

    # VERIFY-8, VERIFY-9: the settings say what a run uses, whatever the code
    # around them does.
    test "the timeouts are settings with defaults" do
      for key <- [:timeout, :max_timeout, :test_timeout, :max_test_timeout] do
        assert is_integer(Harness.timeout_config(key))
        assert Harness.timeout_config(key) > 0
      end

      assert Harness.timeout_config(:timeout) <= Harness.timeout_config(:max_timeout)

      assert Harness.timeout_config(:test_timeout) <=
               Harness.timeout_config(:max_test_timeout)
    end
  end

  # A throwaway Mix project (DEPLOY-2) with a test that hangs, so a run in it can
  # only end by a timeout (VERIFY-8, VERIFY-9).
  defp hanging_tree do
    tree = Elia.LiveTree.create()

    File.write!(Path.join(tree, "test/hangs_test.exs"), """
    defmodule HangsTest do
      use ExUnit.Case, async: false

      test "hangs" do
        Process.sleep(60_000)
      end
    end
    """)

    on_exit(fn -> Elia.LiveTree.remove(tree) end)
    tree
  end
end
