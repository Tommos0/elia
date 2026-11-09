defmodule EliaWeb.FileLinksTest do
  use ExUnit.Case, async: false

  alias Elia.{Deploy, Projects, Workspace}
  alias EliaWeb.FileLinks

  # STORE-5: a chat id is 12 URL-safe characters.
  @chat "flinkschat01"
  @dir "file_links_fixture"

  defp in_root(path), do: Path.join(Workspace.root(), path)
  defp in_worktree(path), do: Path.join(Deploy.worktree_path(@chat), path)

  setup do
    File.rm_rf!(in_root(@dir))
    File.rm_rf!(Deploy.worktree_path(@chat))
    # A chat in Elia's own project works in its own worktree (DEPLOY-1, PROJ-12),
    # and its project folder is the live tree: both hold a file of the same
    # relative path, so a test can tell which one is browsed.
    File.mkdir_p!(in_worktree(@dir))
    File.write!(in_worktree("#{@dir}/note.txt"), "the chat's copy\n")
    File.mkdir_p!(in_worktree("#{@dir}/nested"))
    File.mkdir_p!(in_root(@dir))
    File.write!(in_root("#{@dir}/note.txt"), "the live tree's copy\n")
    # A file only the live tree has, and one only the worktree has.
    File.write!(in_root("#{@dir}/uncommitted.ex"), "uncommitted\n")

    on_exit(fn ->
      File.rm_rf!(in_root(@dir))
      File.rm_rf!(Deploy.worktree_path(@chat))
    end)

    %{links: FileLinks.context(Projects.harness(), @chat)}
  end

  # FLINK-5, EXPL-17: the link is the Files page for the chat's own workspace,
  # so it opens the file as that chat has it.
  test "links a mention in the chat's own workspace", %{links: links} do
    assert FileLinks.url(links, "#{@dir}/note.txt") ==
             "/files?chat=#{@chat}&path=#{@dir}%2Fnote.txt"

    # A directory is browsable too (EXPL-6).
    assert FileLinks.url(links, "#{@dir}/nested") ==
             "/files?chat=#{@chat}&path=#{@dir}%2Fnested"

    # The live tree's own copy of the same path is not this chat's (PROJ-12).
    assert FileLinks.url(links, "#{@dir}/uncommitted.ex") == nil

    # A chat with no worktree is browsed in its project's folder, and a chat in
    # another project has that project's folder (PROJ-12, EXPL-17).
    without = FileLinks.context(Projects.harness(), "flinksnochat")

    assert FileLinks.url(without, "#{@dir}/note.txt") ==
             "/files?chat=flinksnochat&path=#{@dir}%2Fnote.txt"

    assert FileLinks.url(without, "#{@dir}/uncommitted.ex") =~ "uncommitted"

    other = %{id: "flinksproject", name: "Other", folder: Workspace.root(), harness?: false}

    assert FileLinks.url(FileLinks.context(other, "flinksother1"), "#{@dir}/note.txt") ==
             "/files?chat=flinksother1&path=#{@dir}%2Fnote.txt"
  end

  # FLINK-2: the line suffix is part of the label, never of the target.
  test "a mention's line suffix stays out of the link", %{links: links} do
    expected = "/files?chat=#{@chat}&path=#{@dir}%2Fnote.txt"

    for mention <- [
          "#{@dir}/note.txt:3",
          "#{@dir}/note.txt:3:7",
          "#{@dir}/note.txt:3-9"
        ] do
      assert FileLinks.url(links, mention) == expected, mention
    end

    # A suffix that isn't one is part of the path.
    refute FileLinks.url(links, "#{@dir}/note.txt:3-") == expected
  end

  # FLINK-3: an absolute path inside the chat's workspace is the same file.
  test "an absolute path inside the workspace links too", %{links: links} do
    assert FileLinks.url(links, in_worktree("#{@dir}/note.txt")) ==
             "/files?chat=#{@chat}&path=#{@dir}%2Fnote.txt"

    # One outside it is no mention at all (FLINK-5).
    assert FileLinks.url(links, in_root("#{@dir}/uncommitted.ex")) == nil
    assert FileLinks.url(links, "/etc/passwd") == nil
  end

  # FLINK-5: only a path the Files page could show — otherwise the link would
  # land on a page that shows an error (EXPL-9).
  test "refuses what the Files page could not show", %{links: links} do
    File.ln_s!("/etc", in_worktree("#{@dir}/etc-link"))
    File.ln_s!(in_worktree("#{@dir}/note.txt"), in_worktree("#{@dir}/note-link.txt"))

    for mention <- [
          # not there
          "#{@dir}/missing.txt",
          # protected (WS-1, EXPL-1)
          ".git/HEAD",
          ".elia",
          "deps",
          "_build",
          # through a symlink (EXPL-2)
          "#{@dir}/etc-link/hostname",
          "#{@dir}/note-link.txt",
          # outside the workspace
          "..",
          "../#{@dir}/note.txt",
          # not a path at all: prose and commands stay text
          "mix test",
          "mongoose",
          "Elia.Preview",
          ""
        ] do
      assert FileLinks.url(links, mention) == nil, mention
    end

    # FLINK-5: the answer follows the filesystem, as the page would see it.
    File.rm!(in_worktree("#{@dir}/note.txt"))
    assert FileLinks.url(links, "#{@dir}/note.txt") == nil
  end

  # FLINK-6: the URL holds no text of its own, so any path is linkable.
  test "percent-encodes the path it links", %{links: links} do
    File.write!(in_worktree("#{@dir}/a & b<c>.ex"), "x\n")

    url = FileLinks.url(links, "#{@dir}/a & b<c>.ex")
    refute url =~ "<"

    assert url |> String.trim_leading("/files?") |> URI.decode_query() |> Map.get("path") ==
             "#{@dir}/a & b<c>.ex"
  end

  # FLINK-4: a tool card's path gets the same link — and only its `path` does.
  test "a tool call's path is a mention, its command is not", %{links: links} do
    expected = "/files?chat=#{@chat}&path=#{@dir}%2Fnote.txt"

    for name <- ~w(read_file write_file edit_file list_files delete_file) do
      item = %{name: name, input: %{"path" => "#{@dir}/note.txt"}}
      assert FileLinks.card_url(links, item) == expected, name
    end

    assert FileLinks.card_url(links, %{
             name: "read_file",
             input: %{"path" => "#{@dir}/missing.txt"}
           }) == nil

    assert FileLinks.card_url(links, %{
             name: "shell",
             input: %{"command" => "cat #{@dir}/note.txt"}
           }) == nil

    assert FileLinks.card_url(links, %{name: "spawn_task", input: %{"title" => "A task"}}) == nil

    assert FileLinks.card_url(nil, %{name: "read_file", input: %{"path" => "#{@dir}/note.txt"}}) ==
             nil
  end
end
