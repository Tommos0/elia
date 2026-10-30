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
end
