defmodule EliaWeb.ProjectSwitcherTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Projects, Workspace}
  alias Elia.LLM.Message

  # PROJ-29: the header names the open project beside the logo, where it used to
  # show the app's own name, and the control it is opens a menu of every project
  # — the open one marked — with the new-project modal's entry at its end
  # (PROJ-30, PROJ-55).
  test "the header names the open project, and its menu lists them all", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      {:ok, view, _html} = live(conn, ~p"/settings")

      # PROJ-29: Elia's own project is open (PROJ-8), so the header reads "Elia"
      # — the name of the project, not a fixed app name — and the header's old
      # Projects link is gone (PROJ-25, PROJ-30).
      assert has_element?(view, "header #project-switcher[aria-expanded='false']", "Elia")
      refute has_element?(view, "header #projects-link")
      refute has_element?(view, "#project-menu")

      view |> element("#project-switcher") |> render_click()

      assert has_element?(view, "#project-switcher[aria-expanded='true']")
      assert has_element?(view, "#project-menu")
      assert has_element?(view, "#project-option-harness[data-open='true']", "Elia")
      assert has_element?(view, "#project-option-#{widgets.id}[data-open='false']", "Widgets")

      # PROJ-30, PROJ-55: and its last entry opens the new-project modal, which
      # is closed until it is chosen.
      assert has_element?(view, "#project-menu #new-project-link", "New project")
      refute has_element?(view, "#new-project-modal")

      # PROJ-29: Escape closes the menu without choosing, as a press outside it
      # does, and neither one navigates.
      render_keydown(view, "close_projects", %{"key" => "Escape"})
      refute has_element?(view, "#project-menu")

      view |> element("#project-switcher") |> render_click()
      assert has_element?(view, "#project-menu")

      render_click(view, "close_projects", %{})
      refute has_element?(view, "#project-menu")
      refute_redirected(view, "/p/#{widgets.id}")
    end)
  end

  # PROJ-28, PROJ-29: opening a chat opens that chat's project — the header names
  # it, and that is what the next new chat starts in (PROJ-11).
  test "opening a chat opens its project", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      theirs = saved_chat(widgets.id)

      # Elia's own project is the one that is open to begin with (PROJ-8).
      assert Projects.default().id == "harness"

      {:ok, view, _html} = live(conn, ~p"/c/#{theirs}")

      assert has_element?(view, "header #project-switcher", "Widgets")
      assert Projects.default().id == widgets.id

      # Its chat list is that project's: "New chat" starts in it (UI-31).
      assert has_element?(view, "#new-chat[href='/p/#{widgets.id}/new']")
    end)
  end

  # PROJ-29, PROJ-51, PROJ-53: choosing a project from the menu opens that
  # project's own page — not its chat list — and the page it opens is the one
  # that makes the project open (PROJ-8, PROJ-28). Its chats are on the page
  # itself (PROJ-52), so a chat in that project is resumed from there.
  test "choosing a project opens its own page", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      mine = saved_chat(nil)
      theirs = saved_chat(widgets.id)

      {:ok, view, _html} = live(conn, ~p"/settings")
      view |> element("#project-switcher") |> render_click()

      assert has_element?(view, "#project-option-#{widgets.id}[href='/p/#{widgets.id}']")

      # The page that link names is the project's own (PROJ-51): it opens the
      # project, and lists its chats and Elia's own project's nowhere.
      {:ok, page, _html} = live(conn, ~p"/p/#{widgets.id}")

      assert Projects.default().id == widgets.id
      assert has_element?(page, "#project-chat-#{theirs} a[href='/c/#{theirs}']")
      refute has_element?(page, "#project-chat-#{mine}")
    end)
  end

  # PROJ-30, PROJ-55: the menu's entry opens the new-project modal over the page
  # it was opened on — a dialog rather than a page of its own — and the menu
  # closes with it.
  test "the menu's entry opens the new-project modal", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      {:ok, view, _html} = live(conn, ~p"/c/#{saved_chat(widgets.id)}")
      view |> element("#project-switcher") |> render_click()

      assert has_element?(view, "#new-project-link", "New project")
      refute has_element?(view, "#new-project-modal")

      view |> element("#new-project-link") |> render_click()

      refute has_element?(view, "#project-menu")
      assert has_element?(view, "#new-project-modal[role='dialog']")
      assert has_element?(view, "#new-project-modal #new-project")
      # The page behind it is still the chat's own (PROJ-51).
      assert has_element?(view, "header #project-switcher", "Widgets")

      view |> element("#new-project-close") |> render_click()
      refute has_element?(view, "#new-project-modal")
    end)
  end

  # A store and a registry of its own — Elia's own project and "Widgets" — so
  # what the header names is this test's alone.
  defp with_projects(fun) do
    root = Path.join(Workspace.root(), "project-switcher-#{Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      File.rm(Projects.path())
      Elia.Settings.delete(:default_project)
      {:ok, widgets} = Projects.create("Widgets", root)
      fun.(%{widgets: widgets})
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm(Projects.path())
      File.rm_rf!(root)
      Elia.Settings.delete(:default_project)
    end
  end

  # One saved chat in a project — `nil` for Elia's own (PROJ-9).
  defp saved_chat(project) do
    id = Agent.new_id()
    :ok = Elia.Store.save(id, [Message.user("where I left off")], project: project)
    id
  end
end
