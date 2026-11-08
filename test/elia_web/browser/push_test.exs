defmodule EliaWeb.PushBrowserTest do
  @moduledoc """
  The push JavaScript in a real headless Chromium (BROWSER-8): the settings
  section's own hook (PUSH-2, PUSH-5) and the chat page's visibility reporting
  (PUSH-14), neither of which `Phoenix.LiveViewTest` runs.

  A browser run needs built assets and `assets/node_modules` (BROWSER-2,
  BROWSER-6), and is excluded from a plain `mix test` (BROWSER-5):

      mix assets.build
      ELIA_BROWSER_TESTS=1 mix test --only real_browser

  Subscribing for real is not covered here: it needs this browser's own push
  service on the internet, so the subscribe and unsubscribe paths (PUSH-3,
  PUSH-4) are covered in `test/elia_web/live/settings_live_test.exs` and
  checked by hand, as PWA-5 is.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, Push, Store}

  setup do
    Push.Subscriptions.clear()
    on_exit(&Push.Subscriptions.clear/0)
    :ok
  end

  # PUSH-2, PUSH-5
  test "the section offers the switch only where this browser can notify", %{conn: conn} do
    key = Push.public_key()

    conn =
      conn
      |> visit("/settings")
      |> assert_has(~s(#push-section[data-vapid-public-key="#{key}"]))
      # The hook ran: the section stopped saying it is still checking.
      |> refute_has("#push-reason", text: "Checking this browser")

    # Which of the two the hook shows follows what the browser itself says about
    # notifications (PUSH-5): the switch where they are possible, and the reason
    # where they are not — as in headless Chromium, which has none and answers
    # "denied".
    case value(conn, "Notification.permission") do
      "denied" ->
        assert_has(conn, "#push-reason", text: "Notifications are blocked for this site")
        refute_has(conn, "#push-toggle", text: "Turn on")

      _possible ->
        assert_has(conn, "#push-toggle", text: "Turn on")
        refute_has(conn, "#push-reason", text: "blocked")
    end

    # Nothing is subscribed until the switch is turned on.
    assert Push.Subscriptions.count() == 0
  end

  # PUSH-13, PUSH-14
  test "a chat page tells the server it is visible", %{conn: conn} do
    id = Agent.new_id()
    :ok = Store.save(id, [])
    on_exit(fn -> Store.delete(id) end)

    conn |> visit("/c/#{id}") |> assert_has("#chat-form") |> assert_has("#chat-shell")

    # The event is a websocket message, so the server needs a moment to handle
    # it: there is nothing page-visible to wait for.
    assert await_visible?(id)
  end

  defp await_visible?(id, tries \\ 40) do
    cond do
      Push.Viewers.visible?(id) -> true
      tries == 0 -> false
      true -> Process.sleep(25) && await_visible?(id, tries - 1)
    end
  end

  # `PhoenixTest.Playwright.evaluate/3` returns the connection and hands the
  # value to a function, so the value comes back through this process.
  defp value(conn, expression) do
    test = self()
    evaluate(conn, expression, fn result -> send(test, {:value, result}) end)
    assert_receive {:value, result}
    result
  end
end
