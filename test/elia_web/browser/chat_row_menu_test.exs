defmodule EliaWeb.ChatRowMenuBrowserTest do
  @moduledoc """
  A chat row's own menu in a real browser (UI-103 in `specs/chat-ui.md`, UI-104
  for what it opens). Which event a gesture sends, whether the browser's own
  context menu follows it, what a press that turns into a scroll does, whether
  Escape reaches the row's link and where a `position: fixed` panel lands are
  all questions only a browser answers (BROWSER-1, BROWSER-7), and
  `Phoenix.LiveViewTest` never presses anything — it calls events by name.

  A browser test, so it runs with `ELIA_BROWSER_TESTS=1` (BROWSER-5):

      mix assets.build
      ELIA_BROWSER_TESTS=1 mix test --only real_browser test/elia_web/browser/chat_row_menu_test.exs
  """
  use EliaWeb.BrowserCase

  alias Elia.{Agent, Store}
  alias Elia.LLM.Message

  # UI-103: half a second is a long press. Well past it, and well short of it,
  # so neither side of the line is a race.
  @long_press 900
  @short_press 40
  # A press that travels this far is a scroll, not a press held on the row.
  @travel 60

  setup do
    open = Agent.new_id()
    other = Agent.new_id()
    :ok = Store.save(open, [Message.user("the chat the page shows")])
    :ok = Store.save(other, [Message.user("the chat a press is about")])
    on_exit(fn -> Enum.each([open, other], &Store.delete/1) end)

    %{open: open, other: other}
  end

  # The list's own hook has run and the page is connected, so the menu's hook is
  # live (UI-103).
  defp open_page(conn, path) do
    conn = visit(conn, path)

    Enum.reduce_while(1..50, conn, fn _, conn ->
      if js(conn, "!!document.querySelector('.phx-connected')") do
        {:halt, conn}
      else
        Process.sleep(200)
        {:cont, conn}
      end
    end)
  end

  defp js(conn, expression) do
    evaluate(conn, expression, &Process.put(:row_menu_js, &1))
    Process.get(:row_menu_js)
  end

  defp centre(conn, selector) do
    js(conn, """
    (() => {
      const el = document.querySelector(#{inspect(selector)})
      if (!el) return null
      const box = el.getBoundingClientRect()
      return {x: Math.round(box.left + box.width / 2), y: Math.round(box.top + box.height / 2)}
    })()
    """)
  end

  # UI-103: a press, as a browser makes one — the pointer down on the point,
  # held for `hold` milliseconds, and up again. `travel` is how far the pointer
  # moves while it is down, which is what a scroll or a drag does.
  defp press_hold(conn, selector, hold, travel \\ 0) do
    at = centre(conn, selector)
    x = at["x"] + travel

    conn =
      unwrap(conn, fn %{page_id: page} ->
        {:ok, _} = PlaywrightEx.Page.mouse_move(page, x: at["x"], y: at["y"], timeout: 5_000)
        {:ok, _} = PlaywrightEx.Page.mouse_down(page, timeout: 5_000)

        if travel != 0 do
          {:ok, _} = PlaywrightEx.Page.mouse_move(page, x: x, y: at["y"], timeout: 5_000)
        end

        :ok
      end)

    Process.sleep(hold)

    unwrap(conn, fn %{page_id: page} ->
      {:ok, _} = PlaywrightEx.Page.mouse_up(page, timeout: 5_000)
    end)
  end

  defp open?(conn, id) do
    js(conn, "document.querySelector('#chat-row-menu-#{id}').style.display !== 'none'")
  end

  # A key, pressed with an element focused (the library's own `press`, which
  # focuses the selector and then sends the key to it).
  defp key(conn, selector, key) do
    press(conn, selector, key)
  end

  # Focus without pressing: a press on the row's link would open the chat (UI-2).
  defp focus(conn, selector) do
    js(conn, "document.querySelector(#{inspect(selector)}).focus(); true")
    conn
  end

  defp path(conn), do: js(conn, "window.location.pathname")

  defp await_path(conn, path) do
    Enum.reduce_while(1..50, conn, fn _, conn ->
      cond do
        js(conn, "window.location.pathname") == path -> {:halt, conn}
        true -> Process.sleep(100) && {:cont, conn}
      end
    end)
  end

  # UI-103: a press held on a row opens that row's menu — and the press does not
  # open the chat as well, since the menu that appeared is what it was for.
  test "a press held on a row opens its menu and not the chat", %{
    conn: conn,
    open: open,
    other: other
  } do
    conn = open_page(conn, "/c/#{open}")
    refute open?(conn, other)

    conn = press_hold(conn, "#chat-link-#{other}", @long_press)

    assert open?(conn, other), "a press held on the row did not open its menu (UI-103)"
    assert path(conn) == "/c/#{open}", "the long press opened the chat as well (UI-103)"

    # UI-103: the menu is drawn, not merely un-hidden, above the list and within
    # the screen — so a row at the list's edge shows all of it (UI-78).
    assert %{
             "width" => width,
             "left" => left,
             "top" => top,
             "right" => right,
             "bottom" => bottom,
             "screen" => screen
           } =
             js(conn, """
             (() => {
               const box = document.querySelector('#chat-row-menu-#{other}').getBoundingClientRect()
               return {width: Math.round(box.width), left: Math.round(box.left), top: Math.round(box.top),
                       right: Math.round(box.right), bottom: Math.round(box.bottom), screen: window.innerHeight}
             })()
             """)

    assert width > 0, "the menu is open but has no width (UI-103)"
    assert left >= 0 and right <= 10_000, "the menu is off the screen: #{left}..#{right} (UI-103)"
    assert top >= 0 and bottom <= screen, "the menu is off the screen: #{top}..#{bottom} (UI-103)"

    # UI-103: "Rename" and the delete entry, in that order (UI-64).
    conn
    |> assert_has("#chat-row-menu-#{other} #rename-chat-#{other}", text: "Rename")
    |> assert_has("#chat-row-menu-#{other} #delete-chat-#{other}", text: "Delete")
  end

  # UI-103: a press let go at once is a press on the chat, not a long press on
  # its row — the row's link opens the chat and no menu is drawn.
  test "a press let go at once opens the chat and no menu", %{
    conn: conn,
    open: open,
    other: other
  } do
    conn = open_page(conn, "/c/#{open}")
    refute open?(conn, other)

    conn = press_hold(conn, "#chat-link-#{other}", @short_press)
    conn = await_path(conn, "/c/#{other}")

    assert path(conn) == "/c/#{other}", "a press let go at once did not open the chat (UI-103)"
    refute open?(conn, other)
  end

  # UI-103: a press that becomes a scroll — the pointer travelling while it is
  # down — opens no menu.
  test "a press that becomes a scroll opens no menu", %{conn: conn, open: open, other: other} do
    conn = open_page(conn, "/c/#{open}")

    conn = press_hold(conn, "#chat-link-#{other}", @long_press, @travel)

    refute open?(conn, other), "a press that travelled opened the menu (UI-103)"
    assert path(conn) == "/c/#{open}"
  end

  # UI-103: a right-click opens the row's menu, and the browser's own menu never
  # follows it — the row's `contextmenu` is claimed rather than left to the
  # browser (which is what Chrome's own menu on Android would be).
  test "a right-click opens the menu and claims the browser's own", %{
    conn: conn,
    open: open,
    other: other
  } do
    conn = open_page(conn, "/c/#{open}")
    refute open?(conn, other)

    # A real right-click first: the pointer's right button, where it goes down
    # and up again.
    at = centre(conn, "#chat-link-#{other}")

    conn =
      unwrap(conn, fn %{page_id: page} ->
        {:ok, _} = PlaywrightEx.Page.mouse_move(page, x: at["x"], y: at["y"], timeout: 5_000)
        {:ok, _} = PlaywrightEx.Page.mouse_down(page, button: :right, timeout: 5_000)
        {:ok, _} = PlaywrightEx.Page.mouse_up(page, button: :right, timeout: 5_000)
        :ok
      end)

    assert open?(conn, other), "a right-click did not open the row's menu (UI-103)"

    # And the claim itself: a `contextmenu` event the row is sent is cancelled,
    # so the browser's own menu would not be shown for it.
    assert js(conn, """
           (() => {
             const link = document.querySelector('#chat-link-#{other}')
             const event = new MouseEvent('contextmenu', {bubbles: true, cancelable: true})
             link.dispatchEvent(event)
             return event.defaultPrevented
           })()
           """),
           "the row's contextmenu was left to the browser (UI-103)"
  end

  # UI-103: from the keyboard, the context-menu key (or Shift+F10) opens the
  # row's menu while the row's link has focus.
  test "the context-menu key opens the menu from the row's link", %{
    conn: conn,
    open: open,
    other: other
  } do
    conn = open_page(conn, "/c/#{open}")
    refute open?(conn, other)

    conn = focus(conn, "#chat-link-#{other}")

    conn = key(conn, "#chat-link-#{other}", "Shift+F10")
    assert open?(conn, other), "Shift+F10 on the row's link did not open its menu (UI-103)"

    conn = key(conn, "#chat-link-#{other}", "Escape")
    refute open?(conn, other)

    conn = key(conn, "#chat-link-#{other}", "ContextMenu")
    assert open?(conn, other), "the context-menu key did not open the row's menu (UI-103)"
  end

  # UI-103: one menu is open at a time — opening another row's shuts the first.
  test "one row's menu is open at a time", %{conn: conn, open: open, other: other} do
    conn = open_page(conn, "/c/#{open}")

    conn = press_hold(conn, "#chat-link-#{open}", @long_press)
    assert open?(conn, open), "the first row's menu did not open (UI-103)"

    conn = press_hold(conn, "#chat-link-#{other}", @long_press)
    assert open?(conn, other), "the second row's menu did not open (UI-103)"
    refute open?(conn, open), "two menus were open at once (UI-103)"
  end

  # UI-103: Escape shuts the menu and puts focus back on the row's link, and the
  # event does not carry on to the pane's own Escape (the drawer's).
  test "Escape shuts the menu and puts focus back on the row", %{conn: conn, open: open} do
    conn = press_hold(open_page(conn, "/c/#{open}"), "#chat-link-#{open}", @long_press)
    assert open?(conn, open)

    conn = key(conn, "#chat-link-#{open}", "Escape")

    refute open?(conn, open), "Escape did not shut the menu (UI-103)"

    assert js(conn, "document.activeElement.id") == "chat-link-#{open}",
           "Escape did not put focus back on the row's link (UI-103)"
  end

  # UI-103: a press outside the menu shuts it, without choosing anything. Then
  # UI-104: "Rename" from the menu puts the row's input in the link's place,
  # holding the chat's title, focused with all of it selected, so it can be
  # typed over at once — and the row's link is not rendered while it is there.
  test "a press outside shuts the menu, and Rename puts the row's input in place",
       %{conn: conn, open: open} do
    conn = press_hold(open_page(conn, "/c/#{open}"), "#chat-link-#{open}", @long_press)
    assert open?(conn, open)

    conn = press_hold(conn, "#transcript-scroll", @short_press)
    refute open?(conn, open), "a press outside did not shut the menu (UI-103)"

    conn =
      conn
      |> press_hold("#chat-link-#{open}", @long_press)
      |> click("#rename-chat-#{open}")

    refute open?(conn, open), "choosing an entry left the menu open (UI-103)"
    refute_has(conn, "#chat-link-#{open}")

    conn = assert_has(conn, "#chat-rename-#{open}[value='the chat the page shows']")

    assert js(conn, "document.activeElement.id") == "chat-rename-#{open}",
           "the rename input did not take the focus (UI-104)"

    assert js(conn, """
           (() => {
             const el = document.activeElement
             return el.selectionStart === 0 && el.selectionEnd === el.value.length
           })()
           """),
           "the chat's title was not selected in the rename input (UI-104)"
  end
end
