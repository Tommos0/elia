defmodule EliaWeb.ProjectLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Projects}
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
        "elia-project-live-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  # One saved chat in a project (STORE-6), removed when the test ends.
  defp save_chat(project, opts) do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, [Message.user("hi")], Keyword.merge([project: project], opts))
    id
  end

  # PROJ-51, PROJ-52: the project the id names — its name, its folder and its
  # icon in its colour — the chats that belong to it, each with the status it
  # shows in the chat list, and the control that starts a chat in it.
  test "shows the project it names and the chats that belong to it", %{conn: conn} do
    dir = make_dir("show")
    {:ok, project} = Projects.create("Widgets", dir)
    {:ok, other} = Projects.create("Other", make_dir("show-other"))

    open = save_chat(project.id, title: "Where I left off")
    finished = save_chat(project.id, title: "Finished", done: true)
    theirs = save_chat(other.id, title: "Not here")

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert page_title(view) == "Elia - Widgets"
    assert has_element?(view, "#project-name-#{project.id}", "Widgets")
    assert has_element?(view, "#project-folder-#{project.id}", project.folder)

    assert has_element?(
             view,
             "#project-icon-#{project.id}[style*='#{Projects.color(project).hex}']"
           )

    # PROJ-52: its own chats, each a row linking to the chat (UI-2), and never
    # another project's.
    assert has_element?(view, "#project-chat-#{open} a[href='/c/#{open}']", "Where I left off")
    assert has_element?(view, "#project-chat-#{finished}", "Finished")
    refute has_element?(view, "#project-chat-#{theirs}")
    refute has_element?(view, "#project-no-chats")
    refute has_element?(view, "#project-load-more")

    # PROJ-52: the status a chat shows in the chat list (UI-59, DONE-2).
    assert has_element?(view, "#project-chat-status-#{open}[data-status='idle']")
    assert has_element?(view, "#project-chat-status-#{finished}[data-status='done']")

    # PROJ-51: the control that starts a chat in this project (PROJ-26), and
    # that opening the page opened the project (PROJ-8, PROJ-28).
    assert has_element?(view, "#project-new-chat[href='/p/#{project.id}/new']")
    assert Projects.default().id == project.id
  end

  # PROJ-52: the first page is the chat list's own (UI-4), and "Load more
  # chats" lists the next one.
  test "lists more chats on Load more", %{conn: conn} do
    {:ok, project} = Projects.create("Many", make_dir("paging"))

    for n <- 1..31, do: save_chat(project.id, title: "Chat #{n}")

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert has_element?(view, "#project-load-more")
    assert length(Regex.scan(~r/<li id="project-chat-/, render(view))) == 30

    view |> element("#project-load-more") |> render_click()

    refute has_element?(view, "#project-load-more")
    assert length(Regex.scan(~r/<li id="project-chat-/, render(view))) == 31
  end

  # PROJ-52, STORE-17: a sub-task chat is not listed on its own — it is reached
  # from the chat that spawned it (UI-45).
  test "a sub-task chat is not listed on its own", %{conn: conn} do
    {:ok, project} = Projects.create("Tasks", make_dir("tasks"))
    parent = save_chat(project.id, title: "The parent")

    child = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(child) end)

    :ok =
      Elia.Store.save(child, [Message.user("go")],
        project: project.id,
        task: %{parent_id: parent},
        title: "A task"
      )

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert has_element?(view, "#project-chat-#{parent}")
    refute has_element?(view, "#project-chat-#{child}")
  end

  # PROJ-51: an id that names no project goes to the projects page (PROJ-23).
  test "an id that names no project goes to the projects page", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/projects"}}} = live(conn, ~p"/p/no-such-project")
  end

  # PROJ-54, PROJ-7: Elia's own project has its page too, but nothing that
  # browses its files or deletes it.
  test "Elia's own project has no Files or Delete", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/p/harness")

    assert has_element?(view, "#project-name-harness", "Elia")
    assert has_element?(view, "#project-new-chat")
    assert has_element?(view, "#project-allowlist-harness")

    refute has_element?(view, "#project-files-harness")
    refute has_element?(view, "#delete-project-harness")
  end

  # PROJ-48, PROJ-54: the Files button makes the project the open one (PROJ-8,
  # PROJ-28) and opens the Files page, which browses it (EXPL-15).
  test "the Files button opens the project's files", %{conn: conn} do
    dir = make_dir("files")
    {:ok, project} = Projects.create("Browsable", dir)
    File.write!(Path.join(dir, "note.txt"), "hello\n")
    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert {:error, {:live_redirect, %{to: "/files"}}} =
             view |> element("#project-files-#{project.id}") |> render_click()

    assert Projects.default().id == project.id

    {:ok, files, _html} = live(conn, ~p"/files")
    assert has_element?(files, "#project-name", "Browsable")
    assert has_element?(files, "[data-entry='note.txt']")
  end

  # PROJ-54: deleting asks for confirmation, removes the project and leaves the
  # page with nothing to show, so it goes back to the projects page (PROJ-23).
  test "deletes a project after confirmation", %{conn: conn} do
    {:ok, project} = Projects.create("Gone", make_dir("delete"))

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert has_element?(view, "#delete-project-#{project.id}[data-confirm]")

    assert {:error, {:live_redirect, %{to: "/projects"}}} =
             view |> element("#delete-project-#{project.id}") |> render_click()

    assert Projects.get(project.id) == nil
  end

  # PROJ-50, NET-11, NET-28: a project's allowlist is a field on its own page
  # showing its entries, one per line, saved when its Save is pressed — and a
  # list holding an entry that isn't one of NET-7's forms changes nothing and is
  # named.
  test "shows and saves a project's allowlist", %{conn: conn} do
    {:ok, project} = Projects.create("Widgets", make_dir("allowlist"))
    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert has_element?(view, "#project-allowlist-#{project.id}")
    assert has_element?(view, "#save-project-allowlist-#{project.id}")

    view
    |> form("#project-allowlist-form-#{project.id}", %{
      allowlist: "API.example.com\n*.example.org\n"
    })
    |> render_submit()

    assert Projects.allowlist(project) == ["api.example.com", "*.example.org"]
    assert has_element?(view, "#project-allowlist-#{project.id}", "api.example.com")
    refute has_element?(view, "#project-allowlist-error-#{project.id}")

    # A list holding an entry that isn't one of NET-7's forms saves nothing and
    # names the entry (NET-11).
    view
    |> form("#project-allowlist-form-#{project.id}", %{allowlist: "api.example.com\nnot a host"})
    |> render_submit()

    assert has_element?(view, "#project-allowlist-error-#{project.id}", "not a host")
    assert Projects.allowlist(project) == ["api.example.com", "*.example.org"]

    # Saving a good list again clears the message.
    view
    |> form("#project-allowlist-form-#{project.id}", %{allowlist: "cdn.example.net\n"})
    |> render_submit()

    refute has_element?(view, "#project-allowlist-error-#{project.id}")
    assert Projects.allowlist(project) == ["cdn.example.net"]
  end
end
