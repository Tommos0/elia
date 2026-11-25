defmodule EliaWeb.ProjectLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Deploy, LiveTree, Projects}
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

  # PROJ-51: an id that names no project goes home, to the dashboard (DASH-1).
  test "an id that names no project goes to the dashboard", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/p/no-such-project")
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
  # page with nothing to show, so it goes home, to the dashboard (PROJ-23).
  test "deletes a project after confirmation", %{conn: conn} do
    {:ok, project} = Projects.create("Gone", make_dir("delete"))

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert has_element?(view, "#delete-project-#{project.id}[data-confirm]")

    assert {:error, {:live_redirect, %{to: "/"}}} =
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

  # PROJ-56, DEPLOY-41, DEPLOY-44: a project's folder is a repository of its own
  # (PROJ-36), and its page offers one push of the trunk per remote that folder
  # has configured, each with the standing of `master` against that remote
  # beside it — and a push sends the trunk, not the branch checked out.
  test "offers one push per remote the folder has, and pushes it", %{conn: conn} do
    folder = repo()
    {:ok, project} = Projects.create("Widgets", folder)
    origin = remote(folder, "origin")
    remote(folder, "backup")

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    assert has_element?(view, "#project-push-#{project.id}-origin", "Push master")
    assert has_element?(view, "#project-push-#{project.id}-backup", "Push master")

    # PROJ-56: each row says which remote it is for.
    assert has_element?(view, "#project-push-remote-#{project.id}-origin", "origin")
    assert has_element?(view, "#project-push-remote-#{project.id}-backup", "backup")

    assert has_element?(
             view,
             "#project-push-status-#{project.id}-origin",
             "has not been pushed to this remote"
           )

    refute has_element?(view, "#project-push-missing-#{project.id}")

    # PROJ-56: the folder is on `live` — the trunk is what a button sends.
    assert LiveTree.branch(folder) == "live"

    view |> element("#project-push-#{project.id}-origin") |> render_click()
    render_async(view)

    assert has_element?(
             view,
             "#project-push-result-#{project.id}-origin",
             "Pushed master to origin"
           )

    assert has_element?(view, "#project-push-status-#{project.id}-origin", "everything on master")
    assert LiveTree.sha(origin, "master") == LiveTree.sha(folder, "master")

    # PROJ-56: the other remote's control and standing are as they were.
    assert has_element?(
             view,
             "#project-push-status-#{project.id}-backup",
             "has not been pushed to this remote"
           )

    assert Deploy.pending(folder, "backup") == {:ok, %{pending: nil}}
    refute has_element?(view, "#project-push-result-#{project.id}-backup")
  end

  # PROJ-57, DEPLOY-44: a folder with no remote to push to gets no button, and
  # the page says what is missing instead — that it has no remote, with the
  # command that would give it one, or git's own reason for a folder that is no
  # repository at all.
  test "says what is missing where the folder has no remote (PROJ-57)", %{conn: conn} do
    {:ok, project} = Projects.create("Bare", repo())

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    refute has_element?(view, "#project-push-#{project.id}-origin")
    assert has_element?(view, "#project-push-missing-#{project.id}", "has no remote to push to")
    assert has_element?(view, "#project-push-missing-#{project.id}", "git remote add origin")

    {:ok, plain} = Projects.create("Plain", make_dir("plain"))

    {:ok, other, _html} = live(conn, ~p"/p/#{plain.id}")

    refute has_element?(other, "#project-push-#{plain.id}-origin")
    assert has_element?(other, "#project-push-missing-#{plain.id}", "not a git repository")
  end

  # PROJ-58, DEPLOY-41, DEPLOY-44: a push runs off the page's own process, so
  # the page stays responsive: while one runs every remote's button is disabled,
  # a click while one runs changes nothing, and only the remote it was for gets
  # a result — reported in a line of its own, and nothing of a deploy's.
  test "a push runs in the background and is reported in its own line (PROJ-58)", %{
    conn: conn
  } do
    folder = repo()
    {:ok, project} = Projects.create("Widgets", folder)
    remote(folder, "origin")
    remote(folder, "backup")

    {:ok, view, _html} = live(conn, ~p"/p/#{project.id}")

    view |> element("#project-push-#{project.id}-origin") |> render_click()

    assert has_element?(view, "#project-push-#{project.id}-origin[disabled]")
    assert has_element?(view, "#project-push-#{project.id}-backup[disabled]")

    # A click while one runs changes nothing: the other remote is not pushed and
    # gets no result of its own.
    render_click(view, "push_master", %{"remote" => "backup"})
    refute has_element?(view, "#project-push-result-#{project.id}-backup")

    render_async(view)

    assert has_element?(view, "#project-push-result-#{project.id}-origin", "Pushed master")
    refute has_element?(view, "#project-push-#{project.id}-origin[disabled]")
    assert Deploy.pending(folder, "backup") == {:ok, %{pending: nil}}

    # PROJ-56, PROJ-58: a remote the folder does not have is not one to push to,
    # so a stale or forged click leaves the page as it is.
    render_click(view, "push_master", %{"remote" => "nope"})
    refute has_element?(view, "#project-push-result-#{project.id}-nope")
    assert Deploy.pending(folder, "origin") == {:ok, %{pending: 0}}
  end

  # PROJ-56: a project's folder is a git repository of its own (PROJ-36), with
  # the branches a tree has: `master` for its trunk, and `live` checked out.
  defp repo do
    dir = LiveTree.create()
    on_exit(fn -> LiveTree.remove(dir) end)
    dir
  end

  # A bare repository outside the folder, the way a remote is (DEPLOY-44).
  defp remote(folder, name) do
    path = Path.join(System.tmp_dir!(), "elia-#{name}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    LiveTree.origin(folder, path, name)
  end
end
