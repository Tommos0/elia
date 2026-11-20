defmodule Elia.ProjectsTest do
  use ExUnit.Case, async: false

  alias Elia.{Projects, Settings, Workspace}

  # The keys Elia.Projects keeps its own state under: the default project
  # (PROJ-8), the projects root (PROJ-32) and Elia's own project's colour
  # (PROJ-44).
  @default_key :default_project
  @root_key :projects_root
  @color_key :harness_project_color

  setup do
    on_exit(fn ->
      File.rm(Projects.path())
      Settings.delete(@default_key)
      Settings.delete(@root_key)
      Settings.delete(@color_key)
    end)

    :ok
  end

  defp write_registry(projects) do
    File.mkdir_p!(Workspace.data_dir())
    File.write!(Projects.path(), :erlang.term_to_binary(%{version: 1, projects: projects}))
  end

  # PROJ-1, PROJ-2
  test "create/2 saves a project as one term, with only the others on disk" do
    assert {:ok, project} = Projects.create("My App", Workspace.root())

    assert project.id =~ ~r/^[A-Za-z0-9_-]{12}$/
    assert project.name == "My App"
    assert project.folder == Workspace.root()
    refute project.harness?

    # One Erlang term, atomic and safe to read back.
    %{version: 1, projects: stored} = Projects.path() |> File.read!() |> :erlang.binary_to_term()
    assert [%{id: id, name: "My App", harness?: false}] = stored
    assert id == project.id
    refute File.exists?(Projects.path() <> ".tmp")

    assert Projects.get(project.id) == project
  end

  # PROJ-2
  test "a missing or corrupt registry reads as no projects, never raising" do
    File.rm(Projects.path())
    assert Projects.list() == [Projects.harness()]

    File.mkdir_p!(Workspace.data_dir())
    File.write!(Projects.path(), "not an Erlang term")
    assert Projects.list() == [Projects.harness()]

    File.write!(Projects.path(), :erlang.term_to_binary([1, 2, 3]))
    assert Projects.list() == [Projects.harness()]

    # A corrupt project entry is dropped, the rest still load.
    write_registry([%{id: "bad", name: 1, folder: 2}, %{id: "ok", name: "Ok", folder: "/x"}])
    assert [%{id: "harness"}, %{id: "ok"}] = Projects.list()
  end

  # PROJ-3
  test "Elia's own project is always first and follows the workspace root" do
    harness = Projects.harness()
    root = Workspace.root()
    assert %{id: "harness", name: "Elia", folder: ^root, harness?: true} = harness

    # Even when the file holds a harness project with another folder.
    write_registry([
      %{id: "harness", name: "Impostor", folder: "/elsewhere", harness?: true},
      %{id: "other", name: "Other", folder: "/x"}
    ])

    assert [first, %{id: "other"}] = Projects.list()
    assert first == harness
    assert Projects.get("harness") == harness
    refute Enum.any?(Projects.list(), &(&1.name == "Impostor"))
  end

  # PROJ-4
  test "list/0 returns Elia's project first, then the others by name" do
    {:ok, _} = Projects.create("zebra", Workspace.root())
    {:ok, _} = Projects.create("Apple", Workspace.root())
    {:ok, _} = Projects.create("banana", Workspace.root())

    assert [%{id: "harness"}, %{name: "Apple"}, %{name: "banana"}, %{name: "zebra"}] =
             Projects.list()
  end

  # PROJ-5
  test "get/1 finds a project by id and is nil otherwise" do
    {:ok, project} = Projects.create("P", Workspace.root())
    assert Projects.get(project.id) == project
    assert Projects.get("nope") == nil
    assert Projects.get("harness") == Projects.harness()
  end

  # PROJ-6
  test "create/2 rejects a blank name and a folder that isn't a directory" do
    assert {:error, :blank_name} = Projects.create("", Workspace.root())
    assert {:error, :blank_name} = Projects.create("   ", Workspace.root())
    assert {:error, :not_a_directory} = Projects.create("P", "/definitely/not/here")

    assert Projects.list() == [Projects.harness()]
  end

  # PROJ-7
  test "delete/1 removes a project, never Elia's own" do
    {:ok, project} = Projects.create("Gone", Workspace.root())

    assert :ok = Projects.delete(project.id)
    assert Projects.get(project.id) == nil
    # An unknown id is a no-op.
    assert :ok = Projects.delete("unknown")
    # Elia's own project can't be deleted.
    assert {:error, :harness_project} = Projects.delete("harness")
    assert Projects.get("harness") == Projects.harness()
  end

  # PROJ-8
  test "default/0 is the last stored project, else Elia's own" do
    assert Projects.default() == Projects.harness()

    {:ok, project} = Projects.create("Home", Workspace.root())
    assert :ok = Projects.set_default(project.id)
    assert Projects.default() == project
    assert Settings.get(@default_key) == project.id

    # An unknown id leaves the default alone.
    assert :ok = Projects.set_default("unknown")
    assert Projects.default() == project

    assert :ok = Projects.set_default("harness")
    assert Projects.default() == Projects.harness()
  end

  # PROJ-27: a project whose folder is gone stays in the registry and is listed,
  # so a chat of its own keeps its project_id.
  test "a project whose folder is gone stays listed" do
    folder = Path.join(Workspace.root(), "projects_test_gone")
    File.rm_rf!(folder)
    File.mkdir_p!(folder)
    {:ok, project} = Projects.create("Gone", folder)
    File.rm_rf!(folder)

    on_exit(fn -> File.rm_rf!(folder) end)

    assert project in Projects.list()
    assert Projects.get(project.id) == project
  end

  # PROJ-31: the chats of a project are the listed chats whose project_id is
  # its own — and Elia's own takes the ones with no project and the ones whose
  # project the registry no longer holds (PROJ-7, PROJ-9).
  test "chats_of/1 keeps one project's chats" do
    {:ok, project} = Projects.create("Widgets", Workspace.root())
    gone = "goneproject1"
    theirs = chat_in(project.id)
    mine = chat_in(nil)
    orphan = chat_in(gone)

    on_exit(fn -> Enum.each([theirs, mine, orphan], &Elia.Store.delete/1) end)

    wanted = fn filter -> Elia.Store.list(1000, where: filter) |> Enum.map(& &1.id) end

    assert theirs in wanted.(Projects.chats_of(project))
    refute mine in wanted.(Projects.chats_of(project))
    refute orphan in wanted.(Projects.chats_of(project))

    assert mine in wanted.(Projects.chats_of(Projects.harness()))
    assert orphan in wanted.(Projects.chats_of(Projects.harness()))
    refute theirs in wanted.(Projects.chats_of(Projects.harness()))

    # A chat's project is its own while the registry holds it, else Elia's own.
    ids = Enum.map(Projects.list(), & &1.id)
    assert Projects.chat_project_id(%{project_id: project.id}, ids) == project.id
    assert Projects.chat_project_id(%{project_id: gone}, ids) == "harness"
    assert Projects.chat_project_id(%{}, ids) == "harness"
  end

  # PROJ-32, PROJ-33: the projects root is a setting — so it survives a restart
  # and is never committed — and `~/elia-projects` until it is set.
  test "the projects root is stored, and refused when blank" do
    assert Projects.root() == Path.expand("~/elia-projects")

    dir = tmp_dir("root")
    assert :ok = Projects.set_root(dir)
    assert Projects.root() == Path.expand(dir)
    assert Settings.get(@root_key) == Path.expand(dir)

    # Trimmed, and `~` and a relative path resolve to a folder.
    assert :ok = Projects.set_root("  " <> dir <> "  ")
    assert Projects.root() == Path.expand(dir)

    assert {:error, :blank_root} = Projects.set_root("   ")
    assert {:error, :blank_root} = Projects.set_root(nil)
    assert Projects.root() == Path.expand(dir)
  end

  # PROJ-34: a name alone, made a folder of its own under the projects root.
  test "create/1 makes a project in a folder of its own" do
    root = tmp_dir("create")
    :ok = Projects.set_root(root)

    assert {:ok, project} = Projects.create("My App")
    assert project.name == "My App"
    assert project.folder == Path.join(Path.expand(root), "my-app")
    assert File.dir?(project.folder)
    assert Projects.get(project.id) == project
    refute project.harness?

    # Nothing is saved for a name that leaves no folder name.
    before = length(Projects.list())
    assert {:error, :blank_name} = Projects.create("   ")
    assert {:error, :blank_name} = Projects.create("!!!")
    assert {:error, :blank_name} = Projects.create("")
    assert length(Projects.list()) == before
  end

  # PROJ-34: the folder is the name, lowercased and kept to letters and digits.
  test "the folder a name makes is its lowercased letters and digits" do
    root = Path.expand(tmp_dir("folder"))
    :ok = Projects.set_root(root)

    assert Projects.folder_for("My  App!") == Path.join(root, "my-app")
    assert Projects.folder_for("Café Olé") == Path.join(root, "café-olé")
    assert Projects.folder_for("  --2 Fast 2 Furious-- ") == Path.join(root, "2-fast-2-furious")
    assert Projects.folder_for("!!!") == nil
    assert Projects.folder_for(nil) == nil
  end

  # PROJ-35: the folder is made with its parents, a folder that is there and
  # holds anything is never written into, and one that can't be made is an error
  # that saves nothing.
  test "create/1 makes the folder, never writing into one that is taken" do
    root = tmp_dir("exists")
    nested = Path.join([root, "deep", "deeper"])
    :ok = Projects.set_root(nested)

    # The projects root itself is made, parents and all.
    assert {:ok, project} = Projects.create("Fresh")
    assert project.folder == Path.join(nested, "fresh")

    # A folder that already holds something.
    taken = Path.join(nested, "taken")
    File.mkdir_p!(taken)
    File.write!(Path.join(taken, "note.txt"), "mine")
    assert {:error, :folder_exists} = Projects.create("Taken")
    refute Enum.any?(Projects.list(), &(&1.name == "Taken"))
    assert File.read!(Path.join(taken, "note.txt")) == "mine"

    # One that holds nothing is used, so a failed attempt can be repeated.
    empty = Path.join(nested, "empty")
    File.mkdir_p!(empty)
    assert {:ok, project} = Projects.create("Empty")
    assert project.folder == empty

    # A root that can't be made: its parent is a file.
    file = Path.join(root, "file")
    File.write!(file, "not a folder")
    :ok = Projects.set_root(Path.join(file, "under"))
    assert {:error, :folder_failed} = Projects.create("Nope")
    refute Enum.any?(Projects.list(), &(&1.name == "Nope"))
  end

  # PROJ-36: the new folder is a git repository with one commit, holding the
  # README and AGENTS starters.
  test "create/1 leaves the folder a repository with one commit" do
    root = tmp_dir("repo")
    :ok = Projects.set_root(root)

    assert {:ok, project} = Projects.create("Repo")
    assert File.dir?(Path.join(project.folder, ".git"))
    assert File.read!(Path.join(project.folder, "README.md")) =~ "# Repo"
    assert File.read!(Path.join(project.folder, "AGENTS.md")) =~ "# Repo"

    assert [commit] = commits(project.folder)
    assert commit.message == "Initial commit"
    assert Enum.sort(commit.files) == ["AGENTS.md", "README.md"]
  end

  # PROJ-37: git with no identity configured still gets the initial commit.
  test "the initial commit is made where git has no identity" do
    root = tmp_dir("identity")
    :ok = Projects.set_root(root)

    # A git configuration with nothing in it: no `user.email`, no `user.name`.
    config = Path.join(root, "empty-gitconfig")
    File.write!(config, "")
    System.put_env("GIT_CONFIG_GLOBAL", config)
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")

    on_exit(fn ->
      System.delete_env("GIT_CONFIG_GLOBAL")
      System.delete_env("GIT_CONFIG_NOSYSTEM")
    end)

    assert {:ok, project} = Projects.create("Anonymous")
    assert [%{message: "Initial commit"}] = commits(project.folder)
  end

  # PROJ-38: whatever stops the folder becoming a repository does not fail the
  # creation — the folder, its files and the project are still made.
  test "a git that is not there leaves the project made, without a repository" do
    root = tmp_dir("nogit")
    :ok = Projects.set_root(root)
    bin = Path.join(root, "empty-bin")
    File.mkdir_p!(bin)
    without_git(bin)

    assert {:ok, project, :no_repository} = Projects.create("No Git")
    assert File.dir?(project.folder)
    assert File.read!(Path.join(project.folder, "README.md")) =~ "# No Git"
    assert File.read!(Path.join(project.folder, "AGENTS.md")) =~ "# No Git"
    refute File.exists?(Path.join(project.folder, ".git"))
    assert Projects.get(project.id) == project
  end

  test "a git that refuses leaves the project made, without a repository" do
    root = tmp_dir("badgit")
    :ok = Projects.set_root(root)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    stub_git(bin)
    without_git(bin)

    assert {:ok, project, :no_repository} = Projects.create("Bad Git")
    assert File.dir?(project.folder)
    assert Projects.get(project.id) == project
  end

  # PROJ-42: the palette is fixed — each entry a lowercase name and the hex the
  # interface paints it in.
  test "palette/0 is the colours a project can be" do
    palette = Projects.palette()

    assert palette == Projects.palette()
    assert length(palette) > 1
    assert Enum.uniq_by(palette, & &1.name) == palette

    assert Enum.all?(palette, fn
             %{name: name, hex: hex} ->
               name == String.downcase(name) and hex =~ ~r/^#[0-9a-f]{6}$/

             _other ->
               false
           end)
  end

  # PROJ-43: a project's colour is the palette entry it stores, else the one its
  # name derives — the same name always deriving the same one.
  test "color/1 resolves a project's colour, deriving one from its name" do
    {:ok, project} = Projects.create("Widgets", Workspace.root())

    # A new project stores none, and the one its name derives is a palette
    # entry.
    assert project.color == nil
    assert Projects.color(project) == Projects.auto_color(project)
    assert Projects.color(project) in Projects.palette()

    # What it stores is what it wears.
    assert {:ok, stored} = Projects.set_color(project, "rose")
    assert Projects.color(stored).name == "rose"
    assert Projects.color(stored) == Enum.find(Projects.palette(), &(&1.name == "rose"))

    # The same name derives the same colour, whatever the project's id, and a
    # project without a colour at all still has one.
    assert Projects.auto_color(%{project | id: "anotherid12"}) == Projects.auto_color(project)
    assert Projects.color(Map.delete(project, :color)) == Projects.auto_color(project)

    # A stored name the palette does not hold falls back to the derived one.
    assert Projects.color(%{project | color: "chartreuse"}) == Projects.auto_color(project)

    # Elia's own project has one like any other.
    assert Projects.color(Projects.harness()) in Projects.palette()
  end

  # PROJ-44: set_color/2 stores a palette colour, `nil` clears it, and a name the
  # palette does not hold stores nothing. Elia's own project takes one too, and
  # the registry never holds it (PROJ-3).
  test "set_color/2 stores a colour, clears it with nil" do
    {:ok, project} = Projects.create("Widgets", Workspace.root())

    assert {:ok, updated} = Projects.set_color(project, "teal")
    assert updated.color == "teal"
    assert Projects.get(project.id).color == "teal"
    refute Projects.get(project.id) == project

    assert {:ok, cleared} = Projects.set_color(Projects.get(project.id), nil)
    assert cleared.color == nil
    assert Projects.get(project.id).color == nil
    assert Projects.color(Projects.get(project.id)) == Projects.auto_color(project)

    assert {:error, :unknown_color} = Projects.set_color(Projects.get(project.id), "chartreuse")
    assert {:error, :unknown_color} = Projects.set_color(Projects.get(project.id), 42)
    assert Projects.get(project.id).color == nil

    # Elia's own project is not in the registry, so its colour is kept where its
    # other state is (PROJ-8).
    assert {:ok, harness} = Projects.set_color(Projects.harness(), "violet")
    assert harness.color == "violet"
    assert Projects.harness().color == "violet"
    assert Projects.get("harness").color == "violet"

    assert {:ok, _cleared} = Projects.set_color(Projects.harness(), nil)
    assert Projects.harness().color == nil
  end

  # PROJ-2, PROJ-43: a registry written before the field existed — and one naming
  # a colour the palette does not hold — reads as a project with no colour, which
  # is the one its name derives. Nothing to migrate.
  test "a project written without a colour reads as the one its name derives" do
    write_registry([%{id: "oldproject1", name: "Old", folder: "/x"}])

    assert [%{id: "harness"}, project] = Projects.list()
    assert project.color == nil
    assert Projects.color(project) == Projects.auto_color(project)
    assert Projects.color(project) in Projects.palette()

    write_registry([%{id: "oldproject1", name: "Old", folder: "/x", color: "chartreuse"}])

    assert [%{id: "harness"}, project] = Projects.list()
    assert project.color == nil
  end

  # A saved chat in a project, `nil` for Elia's own (PROJ-9).
  defp chat_in(project) do
    id = Elia.Agent.new_id()
    :ok = Elia.Store.save(id, [Elia.LLM.Message.user("hi")], project: project)
    id
  end

  # A folder of its own for a test, removed afterwards.
  defp tmp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "elia-projects-#{name}-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # The commits of a folder's repository, newest first: each one's subject and
  # the files it touched.
  defp commits(folder) do
    folder
    |> git(["log", "--format=@@%s", "--name-only"])
    |> String.split("@@", trim: true)
    |> Enum.map(fn entry ->
      [message | files] = entry |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
      %{message: message, files: files}
    end)
  end

  defp git(folder, args) do
    {output, 0} =
      System.cmd(System.find_executable("git"), args, cd: folder, stderr_to_stdout: true)

    output
  end

  # A PATH holding only `bin`: no git to find. Restored afterwards.
  defp without_git(bin) do
    path = System.get_env("PATH")
    System.put_env("PATH", bin)
    on_exit(fn -> System.put_env("PATH", path) end)
  end

  # A `git` that fails, first on the PATH.
  defp stub_git(bin) do
    stub = Path.join(bin, "git")
    File.write!(stub, "#!/bin/sh\nexit 1\n")
    File.chmod!(stub, 0o755)
  end
end
