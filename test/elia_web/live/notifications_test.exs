defmodule EliaWeb.NotificationsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Elia.LLMCase

  alias Elia.{Agent, Notifications, Store}

  # The notification bell in the header (`specs/notifications.md`, NOTIF-5 to
  # NOTIF-11): the count of what is unread, the menu behind it, and what reading
  # an entry does. The list lives in the settings database, so these tests are
  # not async.

  setup do
    reset_settings()
    :ok
  end

  # NOTIF-5, NOTIF-11: the bell is on a page that keeps no chat list of its own,
  # with no count while nothing is unread, and the menu it opens says the list is
  # empty.
  test "the header carries the bell, and the menu says the list is empty", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    assert has_element?(view, "#notifications-toggle")
    assert has_element?(view, "#notifications-toggle[aria-expanded='false']")
    refute has_element?(view, "#notifications-count")
    refute has_element?(view, "#notifications-menu")

    view |> element("#notifications-toggle") |> render_click()

    assert has_element?(view, "#notifications-menu")
    assert has_element?(view, "#notifications-empty")
    assert has_element?(view, "#notifications-toggle[aria-expanded='true']")
  end

  # NOTIF-5, NOTIF-6: the count of what is unread, and the menu's entries newest
  # first, each with its chat, what it needs and when — the unread ones marked
  # as unread.
  test "the count of unread, and the entries in the menu", %{conn: conn} do
    id = start_chat("Deploy the fix")

    broadcast(id, :running)
    broadcast(id, :idle)
    broadcast(id, :awaiting_approval)
    entries = await_entries(2)

    {:ok, view, _html} = live(conn, ~p"/sessions")
    assert has_element?(view, "#notifications-count", "2")

    view |> element("#notifications-toggle") |> render_click()

    assert has_element?(view, "#notifications-menu", "Deploy the fix")
    assert has_element?(view, "#notifications-menu", "Needs your approval.")
    assert has_element?(view, "#notifications-menu", "Finished.")

    # Newest first, and both of them unread.
    assert before?(render(view), "Needs your approval.", "Finished.")

    for entry <- entries do
      assert has_element?(view, "#notification-#{entry.id}[data-unread='true']")
    end
  end

  # NOTIF-6: the bell opens and closes the menu and never navigates, and a
  # backdrop or the Escape key closes it (UI-36).
  test "the bell toggles the menu, and a backdrop or Escape closes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sessions")

    view |> element("#notifications-toggle") |> render_click()
    assert has_element?(view, "#notifications-menu")

    # Opening it again closes it, and the page is still the page it was.
    view |> element("#notifications-toggle") |> render_click()
    refute has_element?(view, "#notifications-menu")
    assert has_element?(view, "#session-count")
    refute_redirected(view)

    view |> element("#notifications-toggle") |> render_click()
    view |> element("#notifications-backdrop") |> render_click()
    refute has_element?(view, "#notifications-menu")
    refute has_element?(view, "#notifications-backdrop")

    view |> element("#notifications-toggle") |> render_click()
    assert has_element?(view, "#notifications-menu[phx-key='Escape'][phx-window-keydown]")
    render_keydown(view, "close_notifications", %{"key" => "Escape"})
    refute has_element?(view, "#notifications-menu")
  end

  # NOTIF-7: an entry is a link to the page of the chat it is about, and
  # following it is arriving at that chat, which reads it (NOTIF-8).
  test "an entry follows to its chat and is read", %{conn: conn} do
    id = start_chat("Deploy the fix")
    broadcast(id, :awaiting_approval)
    [entry] = await_entries(1)

    {:ok, view, _html} = live(conn, ~p"/sessions")
    view |> element("#notifications-toggle") |> render_click()

    assert has_element?(view, "#notification-#{entry.id}[href='/c/#{id}']")

    view |> element("#notification-#{entry.id}") |> render_click()

    assert_redirect(view, "/c/#{id}")

    # What the browser does next: the chat's own page opens, and opening it is
    # what reads the entry (NOTIF-8).
    {:ok, _chat_view, _html} = live(conn, ~p"/c/#{id}")

    assert Notifications.unread_count() == 0
    assert Enum.find(Notifications.list(), &(&1.id == entry.id)).read == true
  end

  # NOTIF-8: opening a chat's page is what reads its entries — the user is
  # there, whether they came from the menu, the chat list or a URL.
  test "opening a chat's page marks that chat's entries read", %{conn: conn} do
    read = start_chat("Read this one")
    other = start_chat("Leave this one alone")

    broadcast(read, :awaiting_approval)
    broadcast(other, :awaiting_approval)
    await_entries(2)

    {:ok, _view, _html} = live(conn, ~p"/c/#{read}")

    assert Notifications.unread_count() == 1
    assert Enum.filter(Notifications.list(), &(&1.chat_id == read)) |> Enum.all?(& &1.read)

    assert Enum.filter(Notifications.list(), &(&1.chat_id == other))
           |> Enum.all?(&(&1.read == false))
  end

  # NOTIF-9: the menu's own controls — everything read, then the list emptied.
  test "the menu marks everything read, and clears the list", %{conn: conn} do
    id = start_chat("Deploy the fix")
    broadcast(id, :awaiting_approval)
    [entry] = await_entries(1)

    {:ok, view, _html} = live(conn, ~p"/sessions")
    view |> element("#notifications-toggle") |> render_click()

    view |> element("#notifications-mark-read") |> render_click()

    refute has_element?(view, "#notifications-count")
    assert has_element?(view, "#notification-#{entry.id}[data-unread='false']")
    assert Notifications.unread_count() == 0
    # NOTIF-9: nothing is unread, so there is nothing left to mark.
    refute has_element?(view, "#notifications-mark-read")

    view |> element("#notifications-clear") |> render_click()

    assert Notifications.list() == []
    assert has_element?(view, "#notifications-empty")
    refute has_element?(view, "#notifications-clear")
  end

  # NOTIF-10: a notification recorded while a page is open raises the count and
  # appears at the top of the menu without a reload, and a change made elsewhere
  # lowers it.
  test "the count and the menu follow the store while the page is open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sessions")
    view |> element("#notifications-toggle") |> render_click()
    assert has_element?(view, "#notifications-empty")

    id = start_chat("Recorded while you were here")
    broadcast(id, :awaiting_approval)

    assert await_element(view, "#notifications-count")
    assert has_element?(view, "#notifications-count", "1")
    assert await_element(view, "#notifications-menu", "Recorded while you were here")

    # A change from anywhere else — another page, or another device.
    Notifications.mark_all_read()

    assert await_count_gone(view)
    assert has_element?(view, "#notifications-menu", "Recorded while you were here")
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp start_chat(title) do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [], title: title)
    id
  end

  defp broadcast(id, status),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})

  # The recorder follows the activity topic in its own process, so an entry it
  # has recorded lands a moment after the broadcast that caused it.
  defp await_entries(count, tries \\ 200)

  defp await_entries(count, 0),
    do: flunk("only #{length(Notifications.list())} of #{count} entries")

  defp await_entries(count, tries) do
    case Notifications.list() do
      entries when length(entries) >= count ->
        entries

      _entries ->
        Process.sleep(10)
        await_entries(count, tries - 1)
    end
  end

  # The page follows the list on the topic (NOTIF-10), so what it shows lands a
  # moment after the change: rendering it again is what drains the event.
  defp await_element(view, selector, text \\ nil, tries \\ 200)

  defp await_element(_view, selector, text, 0),
    do: flunk("#{selector} never showed #{inspect(text)}")

  defp await_element(view, selector, text, tries) do
    if has_element?(view, selector, text) do
      true
    else
      Process.sleep(10)
      await_element(view, selector, text, tries - 1)
    end
  end

  defp await_count_gone(view, tries \\ 200)

  defp await_count_gone(_view, 0), do: flunk("#notifications-count never went away")

  defp await_count_gone(view, tries) do
    if has_element?(view, "#notifications-count") do
      Process.sleep(10)
      await_count_gone(view, tries - 1)
    else
      true
    end
  end

  # True when `first` appears before `second` in `html`.
  defp before?(html, first, second) do
    [left | _rest] = String.split(html, second)
    left =~ first
  end
end
