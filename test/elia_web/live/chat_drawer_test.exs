defmodule EliaWeb.ChatDrawerTest do
  @moduledoc """
  The chat list's drawer (UI-32, UI-36, UI-91 - UI-93 in specs/chat-ui.md): the
  header's "Chats" button on the pages that keep no chat list of their own, the
  list it opens, and what a row and its delete button do there.

  The chat page keeps its own sidebar instead (UI-4, UI-35), which is
  `chat_live_test.exs`, `chat_list_test.exs` and `task_ui_test.exs`.
  """
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Projects, Store, Workspace}
  alias Elia.LLM.Message

  # UI-91: the pages that keep no chat list of their own. A chat's own settings
  # and terminal pages are ones too, and are the tests below.
  @pages ~w(/ /projects /files /sessions /system /logs /settings)

  # UI-32, UI-36, UI-91: on every page without a chat list of its own the
  # header's Chats control is the drawer's button, at every width, and it shows
  # the list rather than leaving the page.
  test "the header's Chats button opens the drawer on every page without a chat list",
       %{conn: conn} do
    with_empty_store(fn ->
      for page <- @pages do
        {:ok, view, _html} = live(conn, page)

        assert has_element?(
                 view,
                 "header #chats-toggle[aria-controls='chats-drawer'][aria-expanded='false']"
               ),
               "#{page} has no Chats button"

        # UI-32: it is a button, not a link — nothing in the header goes to
        # `/chats` any more.
        refute has_element?(view, "header #chats-link")

        # UI-36: the drawer starts closed, and no backdrop is there until it is
        # open.
        assert has_element?(view, "#chats-drawer.hidden")
        refute has_element?(view, "#chats-backdrop")

        view |> element("#chats-toggle") |> render_click()

        assert has_element?(view, "#chats-toggle[aria-expanded='true']")
        refute has_element?(view, "#chats-drawer.hidden")
        assert has_element?(view, "#chats-backdrop")

        # UI-92: the drawer is the chat list — the New chat button and the list
        # itself, which says so when there is no chat yet.
        assert has_element?(view, "#chats-drawer #drawer-new-chat")
        assert has_element?(view, "#chats-drawer #drawer-chat-list", "No chats yet")

        # UI-32, UI-91: opening it loaded no other page.
        refute_redirected(view, "/chats")
      end
    end)
  end

  # UI-91, UI-92: a chat's own settings and terminal pages keep no list either,
  # so their header's Chats button opens the drawer — with that chat marked the
  # active one (UI-4) and "New chat" starting in its project (UI-31).
  test "a chat's own pages open the drawer with that chat marked", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, project} = Projects.create("Widgets", Workspace.root())
      id = saved_chat("the chat these pages are about", project)
      other = saved_chat("another chat in the same project", project)

      for page <- [~p"/c/#{id}/settings", ~p"/c/#{id}/terminal"] do
        {:ok, view, _html} = live(conn, page)

        view |> element("#chats-toggle") |> render_click()

        assert has_element?(view, "#chats-drawer #drawer-chat-link-#{id}.bg-base-300"),
               "#{page} did not mark the chat it is about"

        refute has_element?(view, "#chats-drawer #drawer-chat-link-#{other}.bg-base-300")
        assert has_element?(view, "#chats-drawer #drawer-new-chat[href='/p/#{project.id}/new']")
        assert has_element?(view, "#chats-drawer #drawer-project-header-#{project.id}", "Widgets")
      end
    end)
  end

  # UI-36: a backdrop or the Escape key closes the drawer, and the button says
  # whether it is open (UI-32).
  test "the backdrop and Escape close the drawer", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, _html} = live(conn, ~p"/settings")

      view |> element("#chats-toggle") |> render_click()
      view |> element("#chats-backdrop") |> render_click()

      refute has_element?(view, "#chats-backdrop")
      assert has_element?(view, "#chats-drawer.hidden")
      assert has_element?(view, "#chats-toggle[aria-expanded='false']")

      view |> element("#chats-toggle") |> render_click()
      render_keydown(view, "close_chats", %{"key" => "Escape"})

      refute has_element?(view, "#chats-backdrop")
      assert has_element?(view, "#chats-drawer.hidden")
    end)
  end

  # UI-92: the drawer lists the chats as the sidebar does — grouped by project,
  # with the status indicator each one has (UI-45 to UI-47).
  test "the drawer lists the chats, grouped, with their statuses", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, project} = Projects.create("Widgets", Workspace.root())
      mine = saved_chat("in Elia's own project", nil)
      theirs = saved_chat("in Widgets", project)

      publish_status(theirs, :awaiting_approval)

      {:ok, view, _html} = live(conn, ~p"/files")
      view |> element("#chats-toggle") |> render_click()

      assert has_element?(view, "#chats-drawer #drawer-project-header-harness", "Elia")
      assert has_element?(view, "#chats-drawer #drawer-project-header-#{project.id}", "Widgets")

      assert has_element?(
               view,
               "#chats-drawer #drawer-chat-link-#{mine}",
               "in Elia's own project"
             )

      # UI-47: the status the registry has for the chat, read as the drawer
      # opens.
      assert has_element?(
               view,
               "#chats-drawer #drawer-chat-status-#{theirs}[data-status='awaiting_approval']" <>
                 "[title='Needs approval']"
             )
    end)
  end

  # UI-92, UI-84: "Load more chats" pages the list in the drawer too (UI-4), and
  # the drawer stays open while it does.
  test "Load more chats pages the list in the drawer", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(31)
      oldest = hd(ids)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/system")
      view |> element("#chats-toggle") |> render_click()

      refute has_element?(view, "#chats-drawer #drawer-chat-link-#{oldest}")
      assert has_element?(view, "#chats-drawer #drawer-load-more-chats")

      view |> element("#chats-drawer #drawer-load-more-chats") |> render_click()

      refute has_element?(view, "#chats-drawer.hidden")
      assert has_element?(view, "#chats-drawer #drawer-chat-link-#{oldest}")
      assert has_element?(view, "#chats-drawer #drawer-chat-link-#{newest}")
    end)
  end

  # UI-93: a row in the drawer opens that chat (UI-2).
  test "a chat row in the drawer opens that chat", %{conn: conn} do
    with_empty_store(fn ->
      id = saved_chat("open me")

      {:ok, view, _html} = live(conn, ~p"/system")
      view |> element("#chats-toggle") |> render_click()

      view |> element("#chats-drawer #drawer-chat-link-#{id}") |> render_click()
      assert_redirect(view, "/c/#{id}")
    end)
  end

  # UI-93: deleting another chat from the drawer removes its row and flashes,
  # while the page the user is on stays where it is.
  test "deleting a chat from the drawer leaves the page where it is", %{conn: conn} do
    with_empty_store(fn ->
      kept = saved_chat("kept")
      deleted = saved_chat("delete me")

      {:ok, view, _html} = live(conn, ~p"/files")
      view |> element("#chats-toggle") |> render_click()

      view |> element("#chats-drawer #drawer-delete-chat-#{deleted}") |> render_click()

      refute has_element?(view, "#chats-drawer #drawer-chat-link-#{deleted}")
      refute has_element?(view, "#chats-drawer #drawer-delete-chat-#{deleted}")
      assert has_element?(view, "#chats-drawer #drawer-chat-link-#{kept}")
      assert render(view) =~ "Chat deleted."
      assert Store.load(deleted) == []
      # UI-93: the page stayed where it was — no navigation, and the page's own
      # content is still there.
      refute_redirected(view)
      assert has_element?(view, "#file-viewer")
    end)
  end

  # UI-93: deleting the chat a chat's own page is about leaves for `/chats`, as
  # deleting the open chat does (UI-65, UI-77).
  test "deleting the chat a page is about leaves for /chats", %{conn: conn} do
    with_empty_store(fn ->
      id = saved_chat("the chat this page is about")

      {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")
      view |> element("#chats-toggle") |> render_click()

      view |> element("#chats-drawer #drawer-delete-chat-#{id}") |> render_click()

      assert_redirect(view, "/chats")
      assert Store.load(id) == []
    end)
  end

  ## Helpers

  # A saved chat with one message, so it has a title (STORE-7), in `project` or
  # in Elia's own project when there is none (PROJ-9).
  defp saved_chat(text, project \\ nil) do
    id = Agent.new_id()
    :ok = Store.save(id, [Message.user(text)], project: project && project.id)
    id
  end

  # N chats, oldest first, so the list's pages can be named (STORE-12 order).
  defp save_chats(n) do
    for _ <- 1..n, do: saved_chat("where I left off")
  end

  # What a session reports (SESS-19): the registry value, which is what a page
  # that has not opened the list yet reads.
  defp publish_status(id, status) do
    case Registry.register(Elia.Agent.Registry, id, status) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _pid}} ->
        Registry.update_value(Elia.Agent.Registry, id, fn _ -> status end)
    end
  end

  # A store of its own, so the drawer's list is the only thing in it. The same
  # helper as `chat_list_test.exs`, which keeps its own.
  defp with_empty_store(fun) do
    root = Path.join(Workspace.root(), "chat-drawer-#{Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm_rf!(root)
      Elia.Settings.delete(:default_project)
    end
  end
end
