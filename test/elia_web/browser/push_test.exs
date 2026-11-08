defmodule EliaWeb.PushBrowserTest do
  @moduledoc """
  The push JavaScript in a real headless Chromium (BROWSER-8): the settings
  section's own hook (PUSH-2, PUSH-5), what it says about a service worker that
  never started (PUSH-19), how it settles again once the server has rendered it
  again and how it reports a reading that failed (PUSH-20, PUSH-21), what a
  reason leaves in place (PUSH-23) and the chat page's visibility reporting
  (PUSH-14), none of which `Phoenix.LiveViewTest` runs.

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

    # The hook ran: the marker the server renders for "nothing has been read
    # yet" is gone (PUSH-20, PUSH-22).
    assert await_settled(conn)

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

    # PUSH-23: the reason takes the switch's place, and nothing else. The test
    # notification and "remove all" are about the server, so a browser that
    # cannot push — or cannot be read — can still try a send and clear a device
    # that is gone.
    conn
    |> assert_has("#push-send-test")
    |> assert_has("#push-count")

    # A worker that does turn up later is read again by the section itself, so
    # the stale failure stops being the answer without a reload.
    conn
    |> allow_worker()
    |> evaluate("navigator.serviceWorker.register('/sw.js')")
    |> refute_has("#push-reason", text: "has not started")
  end

  # PUSH-20: the section's answer lives in its own markup, so a section the
  # server renders again — which is what a reconnect after the app has been in
  # the background leaves behind — gets the server's own words back, and has to
  # read the browser again rather than sit at "Checking this browser…" for ever.
  test "the section reads the browser again when the server renders it again", %{conn: conn} do
    conn = visit(conn, "/settings")
    # The hook has answered once: the marker the server renders is gone.
    assert await_settled(conn)

    # The server's render, put back by hand: the answer this hook put there is
    # not part of it, so the section is back to saying that it is checking.
    conn = server_render(conn)

    assert value(
             conn,
             "document.querySelector('#push-reason').classList.contains('push-checking')"
           )

    # …and it settles again by itself, without a reload.
    assert await_settled(conn)

    case value(conn, "Notification.permission") do
      "denied" ->
        assert_has(conn, "#push-reason", text: "Notifications are blocked for this site")

      _possible ->
        assert_has(conn, "#push-toggle", text: "Turn on")
    end
  end

  # PUSH-20: a reading that fails is an answer too, and the only one a phone can
  # show — it has no console.
  test "the section says when the browser cannot be read at all", %{conn: conn} do
    conn = visit(conn, "/settings")
    assert await_settled(conn)

    # The browser's own API, failing the way a browser that will not answer
    # does. The section reads it again because the server's words are back
    # (PUSH-20), and this time the reading throws.
    conn =
      conn
      |> evaluate("""
      (() => {
        Object.defineProperty(navigator.serviceWorker, "ready", {
          get() { throw new Error("nope") },
          configurable: true
        })
        return null
      })()
      """)
      |> server_render()

    assert await_settled(conn)
    assert_has(conn, "#push-reason", text: "could not be read")
    assert_has(conn, "#push-reason", text: "nope")
  end

  # PUSH-21: a page that comes back in front of the user reads the browser
  # again, so an answer that changed while it was away — permission withdrawn,
  # a subscription made or dropped — does not stay stale on screen.
  test "the section reads the browser again when the page comes back", %{conn: conn} do
    conn = visit(conn, "/settings")
    assert await_settled(conn)

    # What the browser answers from now on, so that a second reading can be told
    # from the first: this device holds a subscription.
    conn =
      evaluate(conn, """
      (() => {
        Object.defineProperty(Notification, "permission", {get: () => "granted", configurable: true})
        navigator.serviceWorker.ready.then(registration => {
          registration.pushManager.getSubscription = async () => ({endpoint: "https://push.example.net/sub/1"})
        })
        return null
      })()
      """)

    conn
    |> evaluate("document.dispatchEvent(new Event('visibilitychange'))")
    |> assert_has("#push-toggle", text: "Turn off", timeout: to_timeout(second: 5))
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

  # PUSH-20: the marker the server renders is what the section says before
  # anything has been read, and the hook takes it away with its first answer —
  # whatever that answer is.
  defp await_settled(conn, tries \\ 60) do
    settled? =
      value(conn, "!document.querySelector('#push-reason').classList.contains('push-checking')")

    cond do
      settled? -> true
      tries == 0 -> false
      true -> Process.sleep(100) && await_settled(conn, tries - 1)
    end
  end

  # PUSH-20: the section as the server renders it, which is all a re-render of
  # the page leaves behind — the words it says before anything has been read.
  defp server_render(conn) do
    evaluate(conn, """
    (() => {
      const reason = document.querySelector("#push-reason")
      reason.textContent = "Checking this browser…"
      reason.classList.add("push-checking")
      reason.classList.remove("hidden")
      const row = document.querySelector("#push-switch-row")
      row.classList.add("hidden")
      row.classList.remove("flex")
    })()
    """)
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
