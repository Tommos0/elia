defmodule EliaWeb.ChatListTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Workspace}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # UI-4: the sidebar lists the 30 most recently started chats, and while those
  # are all the store holds there is nothing more to list, so no button (UI-84).
  test "the first page is the 30 most recent chats", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(30)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      assert has_element?(view, "#chat-link-#{newest}")
      assert has_element?(view, "#chat-link-#{hd(ids)}")
      refute has_element?(view, "#load-more-chats")
    end)
  end

  # UI-84: with more chats saved than the list shows, the button is there, below
  # the list — outside its scroll box, so it is visible without scrolling to the
  # end of the list — and pressing it is enough once, since that page is now all
  # of them.
  test "Load more chats lists the next page and goes when there is no more", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(31)
      oldest = hd(ids)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      assert has_element?(view, "#load-more-chats", "Load more chats")
      refute has_element?(view, "#chat-list #load-more-chats")
      refute has_element?(view, "#chat-link-#{oldest}")

      view |> element("#load-more-chats") |> render_click()

      assert has_element?(view, "#chat-link-#{oldest}")
      refute has_element?(view, "#load-more-chats")
    end)
  end

  # UI-84: a press lists 30 more — the same chats, one page longer (STORE-12
  # order) — and the button stays while further chats remain.
  test "each press adds a page of 30", %{conn: conn} do
    with_empty_store(fn ->
      # Oldest first, so `at(0)` is the last chat of the third page and `at(1)`
      # the first chat of the second.
      ids = save_chats(61)
      oldest = Enum.at(ids, 0)
      second_page = Enum.at(ids, 1)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")
      view |> element("#load-more-chats") |> render_click()

      assert has_element?(view, "#chat-link-#{second_page}")
      refute has_element?(view, "#chat-link-#{oldest}")
      assert has_element?(view, "#load-more-chats")

      view |> element("#load-more-chats") |> render_click()

      assert has_element?(view, "#chat-link-#{oldest}")
      refute has_element?(view, "#load-more-chats")
    end)
  end

  # UI-85: the pages the user loaded survive the refreshes the sidebar does
  # anyway — here a deletion from another chat's row (UI-65) — rather than the
  # list falling back to its first page and hiding a chat that was on screen.
  test "a refresh keeps the pages that were loaded", %{conn: conn} do
    with_empty_store(fn ->
      # 62 chats, oldest first: the first page is the newest 30, and a press
      # loads the next 30 (the chats at 2 onward), leaving the two oldest out.
      ids = save_chats(62)
      oldest = Enum.at(ids, 0)
      deleted = Enum.at(ids, 5)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")
      view |> element("#load-more-chats") |> render_click()

      # A chat from the loaded second page, deleted (UI-65).
      view |> element("#delete-chat-#{deleted}") |> render_click()

      refute has_element?(view, "#chat-link-#{deleted}")
      assert has_element?(view, "#chat-link-#{Enum.at(ids, 2)}")
      refute has_element?(view, "#chat-link-#{oldest}")
      assert has_element?(view, "#load-more-chats")
    end)
  end

  # UI-85: the size loaded lives in the browser. The server hands it over when
  # the button is pressed — the hook's job is to write it down — and a page that
  # mounts again, as opening another chat does (UI-2), takes it back from the
  # hook's event, so browsing between chats re-lists the same pages.
  test "the loaded size is handed to the browser and taken back on mount", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(61)
      oldest = Enum.at(ids, 0)
      second_page = Enum.at(ids, 1)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")
      view |> element("#load-more-chats") |> render_click()
      assert_push_event(view, "chat_page", %{limit: 60})

      # Another view of the chat, as opening another chat gives (UI-2): the first
      # page again, until the hook hands the remembered size back.
      {:ok, other, _html} = live(conn, ~p"/c/#{newest}")
      refute has_element?(other, "#chat-link-#{second_page}")

      render_hook(other, "chat_page", %{"limit" => 60})

      assert has_element?(other, "#chat-link-#{second_page}")
      refute has_element?(other, "#chat-link-#{oldest}")

      # UI-85: a value that isn't a number, and one below the first page, are
      # ignored rather than honoured, so the list never shrinks below UI-4's 30.
      render_hook(other, "chat_page", %{"limit" => "60"})
      render_hook(other, "chat_page", %{"limit" => 10})

      refute has_element?(other, "#chat-link-#{second_page}")
      assert has_element?(other, "#chat-link-#{newest}")
    end)
  end

  # UI-85: with nothing stored the list is the first page, as before.
  test "nothing stored lists the first page", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(31)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      refute has_element?(view, "#chat-link-#{hd(ids)}")
      assert has_element?(view, "#load-more-chats")
    end)
  end

  # N chats, oldest first, so the list's pages can be named (STORE-12 order).
  defp save_chats(n) do
    for _ <- 1..n do
      id = Agent.new_id()
      :ok = Elia.Store.save(id, [Message.user("where I left off")])
      id
    end
  end

  # A store of its own, so the sidebar's pages are the only chats in it. The
  # same helper as `chat_live_test.exs`, which keeps its own.
  defp with_empty_store(fun) do
    root = Path.join(Workspace.root(), "chat-list-#{Agent.new_id()}")
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
