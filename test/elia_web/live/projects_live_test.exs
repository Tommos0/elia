defmodule EliaWeb.ProjectsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.Projects
  alias Elia.LLM.Message

  setup do
    on_exit(fn ->
      File.rm(Projects.path())
      Elia.Settings.delete(:default_project)
      # The projects root a test set (PROJ-32).
      Elia.Settings.delete(:projects_root)
    end)

    :ok
  end

  defp make_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "elia-projects-live-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # PROJ-23: every project with its name, folder and number of chats.
  test "lists every project with its folder and chats", %{conn: conn} do
    dir = make_dir("list")
    {:ok, project} = Projects.create("My App", dir)

    chat = Elia.Agent.new_id()
    on_exit(fn -> Elia.Store.delete(chat) end)
    :ok = Elia.Store.save(chat, [Message.user("hi")], project: project.id)

    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#project-switcher", "Elia")
    assert has_element?(view, "#project-harness")
    assert has_element?(view, "#project-#{project.id}")
    assert has_element?(view, "#project-name-#{project.id}", "My App")
    assert has_element?(view, "#project-folder-#{project.id}", project.folder)
    assert has_element?(view, "#project-chats-#{project.id}", "1 chat")
    # Elia's own project can't be deleted; the other can.
    refute has_element?(view, "#delete-project-harness")
    assert has_element?(view, "#project-#{project.id} #delete-project-#{project.id}")
  end

  # PROJ-23, PROJ-39: the form takes a name; the folder is made under the
  # projects root, as a repository (PROJ-34 - PROJ-36).
  test "creates a project from a name", %{conn: conn} do
    root = make_dir("create")
    :ok = Projects.set_root(root)
    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#projects-root-path", Path.expand(root))

    view
    |> form("#new-project", project: %{name: "Fresh"})
    |> render_submit()

    project = Enum.find(Projects.list(), &(&1.name == "Fresh"))
    assert project
    assert project.folder == Path.join(Path.expand(root), "fresh")
    assert File.dir?(Path.join(project.folder, ".git"))
    assert has_element?(view, "#project-#{project.id}", "Fresh")
    assert has_element?(view, "#flash-info", "Created Fresh.")
    refute has_element?(view, "#project-error")
  end

  # PROJ-39: a folder that is already there holds something, so nothing is made
  # and the error is shown.
  test "creating with a folder already there shows an error and adds nothing", %{conn: conn} do
    root = make_dir("taken")
    :ok = Projects.set_root(root)
    File.mkdir_p!(Path.join(root, "fresh"))
    File.write!(Path.join([root, "fresh", "note.txt"]), "mine")
    before = length(Projects.list())
    {:ok, view, _html} = live(conn, ~p"/projects")

    view
    |> form("#new-project", project: %{name: "Fresh"})
    |> render_submit()

    assert has_element?(view, "#project-error")
    assert has_element?(view, "#new-project #project-error")
    assert length(Projects.list()) == before
    assert File.read!(Path.join([root, "fresh", "note.txt"])) == "mine"
  end

  # PROJ-39: a blank name is rejected too.
  test "creating with a blank name shows an error and adds nothing", %{conn: conn} do
    :ok = Projects.set_root(make_dir("blank"))
    before = length(Projects.list())
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> form("#new-project", project: %{name: "  "}) |> render_submit()

    assert has_element?(view, "#project-error")
    assert length(Projects.list()) == before
  end

  # PROJ-40: the page shows the projects root and sets it, and a blank one is
  # refused and leaves the stored root alone.
  test "shows and sets the projects root", %{conn: conn} do
    dir = make_dir("root")
    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#projects-root-path", Path.expand("~/elia-projects"))

    view |> form("#projects-root-form", root: %{folder: dir}) |> render_submit()

    assert Projects.root() == Path.expand(dir)
    assert has_element?(view, "#projects-root-path", Path.expand(dir))
    assert has_element?(view, "#flash-info", "Projects root saved.")
    refute has_element?(view, "#projects-root-error")

    view |> form("#projects-root-form", root: %{folder: "  "}) |> render_submit()

    assert has_element?(view, "#projects-root-error")
    assert has_element?(view, "#projects-root-form #projects-root-error")
    assert Projects.root() == Path.expand(dir)
  end

  # PROJ-41: a creation whose repository was not set up names the project and
  # says so, rather than reporting a plain success (PROJ-38).
  test "a creation without a repository says so", %{conn: conn} do
    root = make_dir("norepo")
    :ok = Projects.set_root(root)

    # A `git` that fails, first on the PATH.
    bin = make_dir("norepo-bin")
    File.write!(Path.join(bin, "git"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "git"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    {:ok, view, _html} = live(conn, ~p"/projects")

    view
    |> form("#new-project", project: %{name: "No Repo"})
    |> render_submit()

    project = Enum.find(Projects.list(), &(&1.name == "No Repo"))
    assert project
    assert has_element?(view, "#project-#{project.id}", "No Repo")
    # The message names the project and says the repository is not there (the
    # apostrophe is escaped in the markup, so this reads the element's text).
    assert has_element?(view, "#flash-error", "No Repo")
    assert has_element?(view, "#flash-error", "git repository")
  end

  # PROJ-23: deleting asks for confirmation and removes the project.
  test "deletes a project", %{conn: conn} do
    dir = make_dir("delete")
    {:ok, project} = Projects.create("Gone", dir)
    {:ok, view, _html} = live(conn, ~p"/projects")

    assert has_element?(view, "#delete-project-#{project.id}[data-confirm]")

    view |> element("#delete-project-#{project.id}") |> render_click()

    refute has_element?(view, "#delete-project-#{project.id}")
    assert Projects.get(project.id) == nil
  end
end
