defmodule EliaWeb.ChatListBrowserTest do
  @moduledoc """
  The chat list's pages (UI-4, UI-84, UI-85 in specs/chat-ui.md). UI-85 says a
  page the tab has loaded is still the one listed when another chat is opened,
  which mounts the chat page again — that is the browser's own session storage
  and a live navigation, both JavaScript, so it is asked of a real headless
  Chromium (BROWSER-1, BROWSER-5, BROWSER-7). What does not need a browser — the
  pages themselves, the button and the refreshes the sidebar does anyway — is in
  `test/elia_web/live/chat_list_test.exs`.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, Store}
  alias Elia.LLM.Message

  # UI-84, UI-85: 31 chats — one more than the first page holds — so the oldest
  # of them is listed only once the button has loaded the next page, and check
  # that it is still listed after another chat is opened from the list.
  test "the loaded pages are listed again in another chat (UI-84, UI-85)", %{conn: conn} do
    ids = save_chats(31)
    oldest = hd(ids)
    newest = List.last(ids)

    conn = conn |> visit("/c/#{newest}") |> connected()

    # UI-4: the first page is the newest 30, so the oldest of these is not on it,
    # and the button is below the list (UI-84).
    refute listed?(conn, oldest)
    assert listed?(conn, newest)
    assert button?(conn)

    conn = conn |> click("#load-more-chats") |> listed(oldest)

    # UI-84, UI-85: opening another chat mounts the page again. It starts from
    # the first page (the assertion above, on the same 31 chats), so the oldest
    # being listed here is the size this tab remembered (UI-85).
    conn = conn |> click("#chat-link-#{oldest}") |> in_chat(oldest)

    assert listed?(conn, oldest), "the second page was not listed again"
    assert listed?(conn, newest)
  end

  # UI-84: the button is below the list's own scroll box rather than inside it,
  # so it is visible without scrolling the list to its end (the scrolling inside
  # the sidebar is the list's own, UI-78).
  test "the button is below the list's scroll box (UI-84)", %{conn: conn} do
    ids = save_chats(31)

    conn = conn |> visit("/c/#{List.last(ids)}") |> connected() |> button?

    assert js_get(js(conn, geometry()), "insideList") == false,
           "the button is inside #chat-list, which scrolls"
  end

  defp listed(conn, id), do: wait_for(conn, listed_js(id), "chat #{id} to be listed")

  defp listed_js(id), do: "window.document.querySelector('#chat-link-#{id}') !== null"

  defp listed?(conn, id), do: js(conn, listed_js(id)) == true

  # UI-84: the list is read again, and the button with it, before the next read.
  defp button?(conn), do: wait_for(conn, button_js(), "the Load more chats button")

  defp button_js, do: "window.document.querySelector('#load-more-chats') !== null"

  # UI-85: the chat page is the one that is mounted, and the page has listed what
  # it has, before anything about the list is read.
  defp in_chat(conn, id) do
    wait_for(
      conn,
      "window.document.querySelector('#chat-link-#{id}.bg-base-300') !== null",
      "chat #{id} to be the open one"
    )
  end

  # What the button is to the list: whether it sits inside the scrolling box.
  defp geometry do
    """
    (() => {
      const list = document.querySelector("#chat-list")
      const button = document.querySelector("#load-more-chats")
      return {insideList: list.contains(button)}
    })()
    """
  end

  defp save_chats(n) do
    for _ <- 1..n do
      id = Agent.new_id()
      :ok = Store.save(id, [Message.user("where I left off")], project: "harness")
      on_exit(fn -> Store.delete(id) end)
      id
    end
  end

  # The page is only laid out once the LiveView socket connected and its hooks
  # mounted; LiveView puts `phx-connected` on its own container then.
  defp connected(conn) do
    wait_for(conn, "window.document.querySelector('.phx-connected')", "the LiveView to connect")
  end

  defp wait_for(conn, expression, message, timeout \\ 5_000) do
    evaluate(
      conn,
      """
      new Promise(resolve => {
        const until = Date.now() + #{timeout}
        const check = () => {
          if (#{expression}) return resolve(true)
          if (Date.now() > until) return resolve(false)
          setTimeout(check, 25)
        }
        check()
      })
      """,
      [timeout: timeout + 1_000],
      fn reached -> assert reached, "#{message} (within #{timeout}ms)" end
    )
  end

  # `evaluate/3` hands the value to a function instead of returning it, so the
  # value is parked in the test process (where that function runs) and read back.
  defp js(conn, expression) do
    evaluate(conn, expression, &Process.put(:elia_js_value, &1))
    Process.get(:elia_js_value)
  end

  defp js_get(map, key) when is_map(map), do: Map.get(map, to_string(key))
end
