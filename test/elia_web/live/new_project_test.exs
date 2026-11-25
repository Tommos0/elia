defmodule EliaWeb.NewProjectTest do
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
        "elia-new-project-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # PROJ-30, PROJ-55: the switcher's entry opens the modal over the page it is
  # opened on, and its own control, Escape and a press outside it close it.
  test "the switcher's entry opens the modal, which closes again", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute has_element?(view, "#new-project-modal")

    open_modal(view)

    # PROJ-55: a dialog over the page, holding the form and the root control;
    # PROJ-30: the switcher's menu closes with it.
    assert has_element?(view, "#new-project-modal[role='dialog']")
    assert has_element?(view, "#new-project-modal #new-project")
    assert has_element?(view, "#new-project-modal #projects-root-form")
    refute has_element?(view, "#project-menu")
    # The page behind it is the one it was opened on.
    assert has_element?(view, "#project-switcher")

    # PROJ-55: its own control closes it.
    view |> element("#new-project-close") |> render_click()
    refute has_element?(view, "#new-project-modal")

    # Escape closes it.
    open_modal(view)
    render_keydown(view, "close_new_project", %{"key" => "Escape"})
    refute has_element?(view, "#new-project-modal")

    # A press outside it does too.
    open_modal(view)
    view |> element("#new-project-backdrop") |> render_click()
    refute has_element?(view, "#new-project-modal")
  end

  # PROJ-55: the modal stands wherever the header's switcher does, so a chat's
  # own page carries it as well.
  test "the modal is on a chat's own page too", %{conn: conn} do
    chat = Elia.Agent.new_id()
    on_exit(fn -> Elia.Store.delete(chat) end)
    :ok = Elia.Store.save(chat, [Message.user("hi")], project: nil)

    {:ok, view, _html} = live(conn, ~p"/c/#{chat}")

    refute has_element?(view, "#new-project-modal")

    open_modal(view)

    assert has_element?(view, "#new-project-modal #new-project")

    view |> element("#new-project-close") |> render_click()
    refute has_element?(view, "#new-project-modal")
  end

  # PROJ-39, PROJ-55: the form takes a name; the folder is made under the
  # projects root, as a repository (PROJ-34 - PROJ-36); the modal closes on the
  # creation and the flash names the project.
  test "creates a project from a name", %{conn: conn} do
    root = make_dir("create")
    :ok = Projects.set_root(root)

    {:ok, view, _html} = live(conn, ~p"/settings")
    open_modal(view)

    # PROJ-40: the root it is made under is shown beside the form.
    assert has_element?(view, "#projects-root-path", Path.expand(root))

    view
    |> form("#new-project", project: %{name: "Fresh"})
    |> render_submit()

    project = Enum.find(Projects.list(), &(&1.name == "Fresh"))
    assert project
    assert project.folder == Path.join(Path.expand(root), "fresh")
    assert File.dir?(Path.join(project.folder, ".git"))

    refute has_element?(view, "#new-project-modal")
    assert has_element?(view, "#flash-info", "Created Fresh.")
    refute has_element?(view, "#project-error")

    # PROJ-29, PROJ-55: and the switcher's menu holds it when it is opened
    # again.
    view |> element("#project-switcher") |> render_click()
    assert has_element?(view, "#project-option-#{project.id}", "Fresh")
  end

  # PROJ-39: a folder that is already there holds something, so nothing is made
  # and the error is shown in the modal, which stays open.
  test "creating with a folder already there shows an error and adds nothing", %{conn: conn} do
    root = make_dir("taken")
    :ok = Projects.set_root(root)
    File.mkdir_p!(Path.join(root, "fresh"))
    File.write!(Path.join([root, "fresh", "note.txt"]), "mine")
    before = length(Projects.list())

    {:ok, view, _html} = live(conn, ~p"/settings")
    open_modal(view)

    view
    |> form("#new-project", project: %{name: "Fresh"})
    |> render_submit()

    assert has_element?(view, "#new-project-modal")
    assert has_element?(view, "#project-error")
    assert has_element?(view, "#new-project #project-error")
    assert length(Projects.list()) == before
    assert File.read!(Path.join([root, "fresh", "note.txt"])) == "mine"
  end

  # PROJ-39: a blank name is rejected too.
  test "creating with a blank name shows an error and adds nothing", %{conn: conn} do
    :ok = Projects.set_root(make_dir("blank"))
    before = length(Projects.list())

    {:ok, view, _html} = live(conn, ~p"/settings")
    open_modal(view)
    view |> form("#new-project", project: %{name: "  "}) |> render_submit()

    assert has_element?(view, "#project-error")
    assert length(Projects.list()) == before
  end

  # PROJ-40: the modal shows the projects root and sets it, and a blank one is
  # refused and leaves the stored root alone.
  test "shows and sets the projects root", %{conn: conn} do
    dir = make_dir("root")

    {:ok, view, _html} = live(conn, ~p"/settings")
    open_modal(view)

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

    {:ok, view, _html} = live(conn, ~p"/settings")
    open_modal(view)

    view
    |> form("#new-project", project: %{name: "No Repo"})
    |> render_submit()

    project = Enum.find(Projects.list(), &(&1.name == "No Repo"))
    assert project
    # The message names the project and says the repository is not there (the
    # apostrophe is escaped in the markup, so this reads the element's text).
    assert has_element?(view, "#flash-error", "No Repo")
    assert has_element?(view, "#flash-error", "git repository")
  end

  # PROJ-30, PROJ-55: the switcher's entry is what opens the modal.
  defp open_modal(view) do
    view |> element("#project-switcher") |> render_click()
    view |> element("#new-project-link") |> render_click()
    view
  end
end
