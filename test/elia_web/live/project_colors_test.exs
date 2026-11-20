defmodule EliaWeb.ProjectColorsTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Projects, Workspace}
  alias Elia.LLM.Message

  # PROJ-46: the app's badge at the top left wears the open project's colour, on
  # every page, and follows the open project when a chat of another project
  # opens it (PROJ-28, PROJ-29).
  test "the app icon wears the open project's colour", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      mine = Projects.color(Projects.harness()).hex
      theirs = Projects.color(widgets).hex
      refute mine == theirs

      # Elia's own project is open to begin with (PROJ-8).
      {:ok, page, _html} = live(conn, ~p"/settings")
      assert has_element?(page, "#app-icon[style*='#{mine}']")

      # A chat page wears its own project's colour.
      {:ok, chat, _html} = live(conn, ~p"/c/#{saved_chat(widgets.id)}")
      assert has_element?(chat, "#app-icon[style*='#{theirs}']")
      refute has_element?(chat, "#app-icon[style*='#{mine}']")

      # Opening that chat made Widgets the open project (PROJ-28), so the
      # projects page wears its colour too.
      {:ok, projects, _html} = live(conn, ~p"/projects")
      assert has_element?(projects, "#app-icon[style*='#{theirs}']")
    end)
  end

  # PROJ-47: a project's colour stands beside its name in the switcher's menu,
  # each row in its own project's (PROJ-46).
  test "the switcher's rows carry each project's colour", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#project-switcher") |> render_click()

      mine = Projects.color(Projects.harness()).hex
      theirs = Projects.color(widgets).hex

      assert has_element?(view, "#project-swatch-harness[style*='#{mine}']")
      assert has_element?(view, "#project-swatch-#{widgets.id}[style*='#{theirs}']")
    end)
  end

  # PROJ-45: the projects page picks a project's colour — a swatch per palette
  # entry, painted in it (PROJ-42), and the automatic one — and the project's own
  # icon wears the choice (PROJ-47).
  test "the projects page picks a project's colour", %{conn: conn} do
    with_projects(fn %{widgets: widgets} ->
      {:ok, view, _html} = live(conn, ~p"/projects")

      for color <- Projects.palette() do
        assert has_element?(
                 view,
                 "#project-color-#{widgets.id}-#{color.name}[style*='#{color.hex}']"
               )
      end

      assert has_element?(view, "#project-color-#{widgets.id}-auto")

      # Nothing is stored yet, so the automatic one is the choice (PROJ-43).
      assert has_element?(view, "#project-color-#{widgets.id}-auto[data-selected='true']")
      refute has_element?(view, "#project-color-#{widgets.id}-rose[data-selected='true']")

      assert has_element?(
               view,
               "#project-icon-#{widgets.id}[style*='#{Projects.auto_color(widgets).hex}']"
             )

      # Pressing a swatch stores it (PROJ-44) and marks it.
      view |> element("#project-color-#{widgets.id}-rose") |> render_click()

      assert Projects.get(widgets.id).color == "rose"
      assert has_element?(view, "#project-color-#{widgets.id}-rose[data-selected='true']")
      refute has_element?(view, "#project-color-#{widgets.id}-auto[data-selected='true']")
      assert has_element?(view, "#project-icon-#{widgets.id}[style*='#{rose_hex()}']")

      # The automatic swatch clears the choice, so the project goes back to the
      # colour its name derives (PROJ-43).
      view |> element("#project-color-#{widgets.id}-auto") |> render_click()

      assert Projects.get(widgets.id).color == nil
      assert has_element?(view, "#project-color-#{widgets.id}-auto[data-selected='true']")

      assert has_element?(
               view,
               "#project-icon-#{widgets.id}[style*='#{Projects.auto_color(widgets).hex}']"
             )
    end)
  end

  defp rose_hex, do: Enum.find_value(Projects.palette(), &(&1.name == "rose" && &1.hex))

  # A store and a registry of its own — Elia's own project and "Widgets" — so
  # what the header wears is this test's alone.
  defp with_projects(fun) do
    root = Path.join(Workspace.root(), "project-colors-#{Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      File.rm(Projects.path())
      Elia.Settings.delete(:default_project)
      Elia.Settings.delete(:harness_project_color)
      {:ok, widgets} = Projects.create("Widgets", root)
      fun.(%{widgets: widgets})
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm(Projects.path())
      File.rm_rf!(root)
      Elia.Settings.delete(:default_project)
      Elia.Settings.delete(:harness_project_color)
    end
  end

  # One saved chat in a project — `nil` for Elia's own (PROJ-9).
  defp saved_chat(project) do
    id = Agent.new_id()
    :ok = Elia.Store.save(id, [Message.user("where I left off")], project: project)
    id
  end
end
