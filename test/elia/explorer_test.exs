defmodule Elia.ExplorerTest do
  use ExUnit.Case, async: false

  alias Elia.{Explorer, Workspace}

  @dir "explorer_fixture"

  defp in_root(path), do: Path.join(Workspace.root(), path)

  setup do
    File.rm_rf!(in_root(@dir))
    File.mkdir_p!(in_root("#{@dir}/Sub"))
    File.mkdir_p!(in_root("#{@dir}/alpha"))
    File.write!(in_root("#{@dir}/b.txt"), "hello\nworld\n")
    File.write!(in_root("#{@dir}/A.txt"), "A")
    File.write!(in_root("#{@dir}/bin.dat"), <<1, 0, 2>>)
    File.write!(in_root("#{@dir}/latin1.txt"), <<0xE9, 0xE8>>)
    on_exit(fn -> File.rm_rf!(in_root(@dir)) end)
  end

  # EXPL-3
  test "lists directories first, then files, sorted ignoring case" do
    assert {:ok, entries} = Explorer.list(@dir)
    assert Enum.map(entries, & &1.name) == ~w(alpha Sub A.txt b.txt bin.dat latin1.txt)

    assert %{type: :dir, size: nil, path: "explorer_fixture/alpha"} = hd(entries)

    assert %{type: :file, size: 12, path: "explorer_fixture/b.txt"} =
             Enum.find(entries, &(&1.name == "b.txt"))
  end

  # EXPL-3
  test "the root listing leaves out protected entries" do
    assert {:ok, entries} = Explorer.list("")
    names = Enum.map(entries, & &1.name)
    assert @dir in names
    refute ".git" in names
  end

  # EXPL-1
  test "refuses outside and protected paths" do
    for path <- ["..", "../etc", "/etc/passwd", ".git", ".git/config", ".elia", "deps", "a\0b"] do
      assert {:error, :forbidden} = Explorer.list(path), path
      assert {:error, :forbidden} = Explorer.read(path), path
    end
  end

  # EXPL-2
  test "refuses paths through symlinks" do
    File.ln_s!("/etc", in_root("#{@dir}/etc-link"))
    File.ln_s!(in_root("#{@dir}/b.txt"), in_root("#{@dir}/b-link"))

    assert {:error, :forbidden} = Explorer.list("#{@dir}/etc-link")
    assert {:error, :forbidden} = Explorer.read("#{@dir}/etc-link/hostname")
    assert {:error, :forbidden} = Explorer.read("#{@dir}/b-link")

    # ...but the links themselves are listed
    {:ok, entries} = Explorer.list(@dir)
    assert %{type: :symlink} = Enum.find(entries, &(&1.name == "etc-link"))
  end

  # EXPL-4
  test "reads text files" do
    assert {:ok,
            %{
              content: "hello\nworld\n",
              size: 12,
              truncated?: false,
              path: "explorer_fixture/b.txt"
            }} =
             Explorer.read("#{@dir}/b.txt")
  end

  # EXPL-4
  test "cuts large files and keeps the text valid" do
    max = Explorer.max_bytes()
    # "é" is two bytes, so the cut lands inside a character.
    File.write!(in_root("#{@dir}/big.txt"), String.duplicate("é", max))

    assert {:ok, %{truncated?: true, size: size, content: content}} =
             Explorer.read("#{@dir}/big.txt")

    assert size == 2 * max
    assert String.valid?(content)
    assert byte_size(content) == max
  end

  # EXPL-4
  test "reports binary files" do
    assert {:error, :binary} = Explorer.read("#{@dir}/bin.dat")
    assert {:error, :binary} = Explorer.read("#{@dir}/latin1.txt")
  end

  # EXPL-5
  test "distinguishes error kinds" do
    assert {:error, :not_found} = Explorer.list("#{@dir}/nope")
    assert {:error, :not_found} = Explorer.read("#{@dir}/nope")
    assert {:error, :not_found} = Explorer.read("#{@dir}/b.txt/deeper")
    assert {:error, :directory} = Explorer.read(@dir)
    assert {:error, :not_a_directory} = Explorer.list("#{@dir}/b.txt")
  end

  # EXPL-11
  test "maps file names to highlight.js languages" do
    assert Explorer.language("lib/elia/agent.ex") == "elixir"
    assert Explorer.language("mix.lock") == "elixir"
    assert Explorer.language("lib/x.HEEX") == "xml"
    assert Explorer.language("assets/js/app.js") == "javascript"
    assert Explorer.language("Makefile") == "makefile"
    assert Explorer.language("a/b/Dockerfile") == "dockerfile"
    assert Explorer.language("config/config.toml") == "ini"
    assert Explorer.language("notes.txt") == nil
    assert Explorer.language("LICENSE") == nil
    assert Explorer.language(".gitignore") == nil
  end

  # EXPL-15: every function takes the folder it works against, and paths outside
  # it are refused.
  test "browses a project folder and refuses paths outside it" do
    root = in_root("#{@dir}/project")
    File.mkdir_p!(Path.join(root, "inner"))
    File.write!(Path.join(root, "note.txt"), "hi\n")
    File.write!(Path.join(root, "inner/deep.txt"), "deep")

    assert {:ok, entries} = Explorer.list("", root)
    assert Enum.map(entries, & &1.name) == ["inner", "note.txt"]

    assert %{path: "note.txt", type: :file, size: 3} =
             Enum.find(entries, &(&1.name == "note.txt"))

    assert {:ok, %{content: "hi\n", path: "note.txt", size: 3}} = Explorer.read("note.txt", root)
    assert {:ok, [%{path: "inner/deep.txt"}]} = Explorer.list("inner", root)

    # Anything outside the project folder is forbidden, even Elia's own files.
    for path <- ["..", "../b.txt", "../../b.txt", "/etc/passwd"] do
      assert {:error, :forbidden} = Explorer.list(path, root), path
      assert {:error, :forbidden} = Explorer.read(path, root), path
    end

    # The default root is still Elia's own.
    assert {:ok, entries} = Explorer.list(@dir)
    assert Enum.any?(entries, &(&1.name == "project"))
  end

  # EXPL-20: the browsed root is judged by what it points at, so a project
  # whose folder is itself a symlink is browsed — while a path through a link
  # inside it, or out of it, is refused as before (EXPL-2).
  test "browses a root that is itself a symlink" do
    base = in_root("tmp/symlink_root")
    real = Path.join(base, "real")
    root = Path.join(base, "link")
    File.mkdir_p!(Path.join(real, "inner"))
    File.write!(Path.join(real, "note.txt"), "through the link\n")
    File.write!(Path.join(real, "inner/deep.txt"), "deep")
    File.ln_s!("real", root)
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, entries} = Explorer.list("", root)
    assert Enum.map(entries, & &1.name) == ["inner", "note.txt"]

    assert %{path: "note.txt", type: :file, size: 17} =
             Enum.find(entries, &(&1.name == "note.txt"))

    assert {:ok, %{content: "deep", path: "inner/deep.txt"}} =
             Explorer.read("inner/deep.txt", root)

    assert {:error, :directory} = Explorer.read("", root)

    # A link inside that root is still refused, and so is a path out of it.
    File.ln_s!("/etc", Path.join(real, "etc-link"))
    assert {:error, :forbidden} = Explorer.list("etc-link", root)
    assert {:error, :forbidden} = Explorer.read("etc-link/hostname", root)
    assert {:error, :forbidden} = Explorer.list("../real", root)

    # ...but the links themselves are listed, as at any other root.
    {:ok, entries} = Explorer.list("", root)
    assert %{type: :symlink} = Enum.find(entries, &(&1.name == "etc-link"))
  end

  # EXPL-21: a root whose link leads to something that isn't a directory, to
  # nothing, or into a chain that can't be followed is reported, not browsed.
  test "reports a root link that is not a directory or leads nowhere" do
    dir = in_root("tmp/symlink_root_bad")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "target.txt"), "not a folder")
    File.ln_s!("target.txt", Path.join(dir, "file-link"))
    File.ln_s!("nowhere", Path.join(dir, "gone-link"))
    File.ln_s!("loop-b", Path.join(dir, "loop-a"))
    File.ln_s!("loop-a", Path.join(dir, "loop-b"))
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, :not_a_directory} = Explorer.list("", Path.join(dir, "file-link"))
    assert {:error, :not_found} = Explorer.list("", Path.join(dir, "gone-link"))
    assert {:error, :unreadable} = Explorer.list("", Path.join(dir, "loop-a"))

    # The links are ordinary entries of the directory that holds them.
    assert {:ok, entries} = Explorer.list("", dir)

    assert Enum.map(entries, & &1.name) == [
             "file-link",
             "gone-link",
             "loop-a",
             "loop-b",
             "target.txt"
           ]
  end
end
