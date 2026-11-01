defmodule EliaWeb.ProjectsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.Projects
  alias Elia.LLM.Message

  setup do
    on_exit(fn ->
      File.rm(Projects.path())
      Elia.Settings.delete(:default_project)
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

    assert has_element?(view, "#projects-link")
    assert has_element?(view, "#project-harness")
    assert has_element?(view, "#project-#{project.id}")
    assert has_element?(view, "#project-name-#{project.id}", "My App")
    assert has_element?(view, "#project-folder-#{project.id}", project.folder)
    assert has_element?(view, "#project-chats-#{project.id}", "1 chat")
    # Elia's own project can't be deleted; the other can.
    refute has_element?(view, "#delete-project-harness")
    assert has_element?(view, "#project-#{project.id} #delete-project-#{project.id}")
  end

  # PROJ-23
  test "creates a project from a name and a folder", %{conn: conn} do
    dir = make_dir("create")
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> form("#new-project", project: %{name: "Fresh", folder: dir}) |> render_submit()

    project = Enum.find(Projects.list(), &(&1.name == "Fresh"))
    assert project
    assert project.folder == Path.expand(dir)
    assert has_element?(view, "#project-#{project.id}", "Fresh")
    refute has_element?(view, "#project-error")
  end

  # PROJ-23: a folder that isn't a directory shows the error and adds nothing.
  test "creating with a bad folder shows an error and adds nothing", %{conn: conn} do
    before = length(Projects.list())
    {:ok, view, _html} = live(conn, ~p"/projects")

    view
    |> form("#new-project", project: %{name: "Nope", folder: "/definitely/not/here"})
    |> render_submit()

    assert has_element?(view, "#project-error")
    assert has_element?(view, "#new-project #project-error")
    assert length(Projects.list()) == before
  end

  # PROJ-23: a blank name is rejected too.
  test "creating with a blank name shows an error and adds nothing", %{conn: conn} do
    dir = make_dir("blank")
    before = length(Projects.list())
    {:ok, view, _html} = live(conn, ~p"/projects")

    view |> form("#new-project", project: %{name: "  ", folder: dir}) |> render_submit()

    assert has_element?(view, "#project-error")
    assert length(Projects.list()) == before
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
