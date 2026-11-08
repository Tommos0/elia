defmodule EliaWeb.PushBrowserTest do
  @moduledoc """
  The push JavaScript in a real headless Chromium (BROWSER-8): the settings
  section's own hook (PUSH-2, PUSH-5), what it says about a service worker that
  never started (PUSH-19) and the chat page's visibility reporting (PUSH-14),
  none of which `Phoenix.LiveViewTest` runs.

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
  alias PlaywrightEx.{BrowserContext, Route}

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

  # PUSH-19: the section never sits at "Checking this browser…". An auth proxy
  # answering /sw.js with its login page is what a worker that never starts
  # looks like: the registration (PWA-5) fails, so nothing can subscribe.
  test "the section says when the app's service worker never started", %{conn: conn} do
    # The browser reports the failed registration itself, and BROWSER-8 fails a
    # test whose page logged errors: this test expects that one, and takes it
    # off the record before the case looks.
    on_exit(fn ->
      errors = EliaWeb.BrowserJsLogger.take()

      assert Enum.all?(errors, &(&1 =~ "unsupported MIME type")),
             "unexpected JavaScript errors: #{inspect(errors)}"
    end)

    conn =
      conn
      |> block_worker()
      |> visit("/settings")
      |> assert_has("#push-reason", text: "service worker")
      |> assert_has("#push-reason", text: "/sw.js")
      |> refute_has("#push-toggle")

    # A worker that does turn up later is read again by the section itself, so
    # the stale failure stops being the answer without a reload.
    conn
    |> allow_worker()
    |> evaluate("navigator.serviceWorker.register('/sw.js')")
    |> refute_has("#push-reason", text: "has not started")
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

  # PUSH-19: /sw.js answered by a login page instead of the worker script, which
  # is what an auth proxy in front of Elia does to a browser.
  defp block_worker(conn) do
    unwrap(conn, fn %{context_id: context_id} ->
      {:ok, _} =
        BrowserContext.route(
          context_id,
          "**/sw.js",
          fn route, _request ->
            Route.fulfill(route,
              status: 200,
              content_type: "text/html",
              body: "<!DOCTYPE html><title>Sign in</title>"
            )
          end,
          timeout: timeout()
        )
    end)
  end

  defp allow_worker(conn) do
    unwrap(conn, fn %{context_id: context_id} ->
      {:ok, _} = BrowserContext.unroute(context_id, "**/sw.js", timeout: timeout())
    end)
  end
end
