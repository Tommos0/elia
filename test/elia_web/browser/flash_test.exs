defmodule EliaWeb.FlashBrowserTest do
  @moduledoc """
  How long a notice the page shows stays (FLASH-1 to FLASH-3 in
  `specs/flashes.md`), in a real headless Chromium (BROWSER-1, BROWSER-7): what
  takes a notice away is a timer in the browser, and what the connection's own
  notices answer to is the connection, so `Phoenix.LiveViewTest` sees neither.

  A browser test, so it runs with `ELIA_BROWSER_TESTS=1` (BROWSER-5):

      mix assets.build
      ELIA_BROWSER_TESTS=1 mix test --only real_browser test/elia_web/browser/flash_test.exs
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, Store}
  alias Elia.LLM.Message

  # FLASH-1: a notice outlives this. A timer that took it the moment it arrived
  # would fail here, and the wait is short enough that the second it is meant to
  # have has not passed.
  @settled 300
  # FLASH-1: and it is gone by this — the spec's own two seconds, with the round
  # trip's slack — whatever the machine is doing.
  @gone_by 2_500
  # FLASH-2: what a press of the notice's × is given. The notice's own second is
  # longer than this, so a × that did nothing would not pass here.
  @at_once 500
  # FLASH-3: how long the connection's notice is watched for. Longer than the
  # second FLASH-1 gives a notice, and far inside the ten CONN-4 reloads on.
  @connected_notice 1_500

  setup do
    open = Agent.new_id()
    other = Agent.new_id()
    :ok = Store.save(open, [Message.user("the chat the page shows")])
    :ok = Store.save(other, [Message.user("the chat a notice is raised by deleting")])
    on_exit(fn -> Enum.each([open, other], &Agent.delete/1) end)

    %{open: open, other: other}
  end

  # FLASH-1, FLASH-3
  test "a notice the flash put there times out, and the connection's is not on that timer", %{
    conn: conn,
    open: open,
    other: other
  } do
    conn = conn |> visit("/c/#{open}") |> connected()

    # FLASH-1: an ordinary notice — another chat deleted from the list's row menu
    # (UI-64), which leaves the page where it is (UI-65).
    conn =
      conn
      |> open_row_menu(other)
      |> click("#delete-chat-#{other}")
      |> assert_has("#flash-info", text: "Chat deleted.")

    # FLASH-1: still on screen a moment later, so it is not gone the instant it
    # came, and then gone by itself, with nothing pressed.
    Process.sleep(@settled)
    assert_has(conn, "#flash-info", text: "Chat deleted.")

    conn = refute_has(conn, "#flash-info", timeout: @gone_by)

    # FLASH-3: the connection's own notice is the one the connection draws, and
    # it is watched here on a page that really is disconnected. `disconnect/0` on
    # the socket is a clean close: nothing connects again by itself, so the page
    # stays as it is for as long as this looks at it.
    conn = evaluate(conn, "window.liveSocket.disconnect()")
    conn = assert_has(conn, "#client-error", text: "We can't find the internet")

    # FLASH-3: it is still there after the second FLASH-1 would have taken a
    # flash notice in — the notice is the connection's, not the timer's.
    Process.sleep(@connected_notice)
    conn = assert_has(conn, "#client-error", text: "We can't find the internet")

    # FLASH-3: and it goes when the connection is back, not on a timer.
    conn |> evaluate("window.liveSocket.connect()") |> refute_has("#client-error")
  end

  # FLASH-2
  test "a notice's × dismisses it without waiting for its second", %{
    conn: conn,
    open: open,
    other: other
  } do
    conn =
      conn
      |> visit("/c/#{open}")
      |> connected()
      |> open_row_menu(other)
      |> click("#delete-chat-#{other}")
      |> assert_has("#flash-info", text: "Chat deleted.")

    conn
    |> click("#flash-info button[aria-label='close']")
    |> refute_has("#flash-info", timeout: @at_once)
  end

  # UI-103: the row's menu from the keyboard, which is also how the list's delete
  # entry is reached without a long press (UI-64).
  defp open_row_menu(conn, id) do
    conn
    |> press("#chat-link-#{id}", "Shift+F10")
    |> assert_has("#delete-chat-#{id}")
  end

  # The page is only interactive once the LiveView socket connected and its hooks
  # mounted; LiveView puts `phx-connected` on its own container then.
  defp connected(conn) do
    wait_until(
      conn,
      "document.querySelector('.phx-connected')",
      "the LiveView never connected",
      8_000
    )
  end

  defp wait_until(conn, expression, message, timeout) do
    evaluate(
      conn,
      """
      new Promise(resolve => {
        const until = Date.now() + #{timeout}
        const check = () => {
          if (#{expression}) return resolve(true)
          if (Date.now() > until) return resolve(false)
          setTimeout(check, 50)
        }
        check()
      })
      """,
      fn ok -> assert ok, message end
    )

    conn
  end
end
