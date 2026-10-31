defmodule Elia.ProjectsTest do
  use ExUnit.Case, async: false

  alias Elia.{Projects, Settings, Workspace}

  # Same key Elia.Projects stores the default under (PROJ-8).
  @default_key :default_project

  setup do
    on_exit(fn ->
      File.rm(Projects.path())
      Settings.delete(@default_key)
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
end
