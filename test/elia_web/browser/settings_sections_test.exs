defmodule EliaWeb.SettingsSectionsBrowserTest do
  @moduledoc """
  The settings page's collapsible sections in a real headless Chromium
  (BROWSER-8): each one is the browser's own `<details>`, and a patch the user
  did not ask for used to snap an open one shut — a DOM patch removes an
  attribute the server's render does not have. `Phoenix.LiveViewTest` runs no
  JavaScript and sees none of it.

  The state of a section is read out of the DOM (`open`), not asserted on
  screen, because a Playwright assertion only sees what is on screen — and a
  collapsed section is exactly what is being told apart from an open one.

  A browser run needs built assets and the user-wide Playwright CLI (BROWSER-2,
  BROWSER-6), and is excluded from a plain `mix test` (BROWSER-5):

      mix assets.build
      ELIA_BROWSER_TESTS=1 mix test --only real_browser
  """

  use EliaWeb.BrowserCase

  alias Elia.LLM.LlamaServer

  # CONF-25: the four sections, in the order the page shows them.
  @sections ~w(appearance providers deployment push-section)

  # CONF-25: each is collapsed until its own header is clicked, with no round
  # trip — so the browser's `<details>` is the whole mechanism.
  test "every section is collapsed on load, and its header works it", %{conn: conn} do
    conn = visit(conn, "/settings")

    for id <- @sections do
      assert_has(conn, "##{id} summary")
      assert value(conn, collapsed?(id)), "#{id} was open on load"
    end

    conn
    |> click("#providers summary")
    |> assert_has("#providers[open]")
    |> click("#providers summary")
    |> refute_has("#providers[open]")
  end

  # CONF-27: the local model server's own status (LOCAL-26) is broadcast to this
  # page, so the section it is rendered in can be re-rendered under the user's
  # hands with no click and no reload — and an open one stays open.
  test "an open section stays open when the page is pushed a re-render", %{conn: conn} do
    conn = conn |> visit("/settings") |> open_section("providers")

    broadcast_status("http://patched.invalid:9/")

    # The re-render arrived — the section shows the url it was handed...
    assert await?(conn, shows_url?("http://patched.invalid:9/"))

    # ...and the section it landed in is still the one the user opened.
    assert value(conn, open?("providers"))
  end

  # CONF-27: a control that is a round trip (LOCAL-25) re-renders the section it
  # sits in (CONF-26) the same way.
  test "an open section stays open across a round trip one of its controls makes", %{conn: conn} do
    conn = conn |> visit("/settings") |> open_section("providers")

    conn = click(conn, "#reset-local-server")

    # The round trip's own answer is rendered into the section...
    assert await?(conn, "!!document.querySelector('#local-server-result')")

    # ...and the section is still open.
    assert value(conn, open?("providers"))
  end

  # CONF-27: a reconnect hands the page the server's render again to patch over
  # it (CONN-1), rather than loading it, so what the user opened is still open.
  test "an open section stays open across a reconnect", %{conn: conn} do
    conn = conn |> visit("/settings") |> open_section("providers")

    conn = reconnect(conn)

    # A patch after the reconnect, so the section is checked once the page is
    # live again and has taken the server's render: the status the page is
    # subscribed to (LOCAL-26), with its url moved.
    broadcast_status("http://patched.invalid:8/")

    assert await?(conn, shows_url?("http://patched.invalid:8/"))
    assert value(conn, open?("providers"))
  end

  # CONF-25: a section opens by its own header alone.
  defp open_section(conn, id) do
    conn
    |> click("##{id} summary")
    |> assert_has("##{id}[open]")
  end

  defp open?(id), do: "document.querySelector('##{id}').hasAttribute('open')"
  defp collapsed?(id), do: "!document.querySelector('##{id}').hasAttribute('open')"

  # LOCAL-26: the status the page is subscribed to, with the field the section
  # renders (its url) moved, so the re-render it causes is a change the page can
  # be seen to take.
  defp shows_url?(url) do
    "document.querySelector('#local-server-status').textContent.includes(#{inspect(url)})"
  end

  defp broadcast_status(url) do
    status = LlamaServer.status()

    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      LlamaServer.topic(),
      {:llama_server, %{status | url: url}}
    )
  end

  # CONN-1: what the page itself does when its socket has died — connect again
  # without waiting out the backoff.
  defp reconnect(conn) do
    conn = evaluate(conn, "window.liveSocket.disconnect(() => window.liveSocket.connect())")
    assert await?(conn, "window.liveSocket.isConnected()")
    conn
  end

  # A reading that has to be given time to change, since what is being waited
  # for arrives over the socket.
  defp await?(conn, expression, tries \\ 100) do
    cond do
      value(conn, expression) -> true
      tries == 0 -> false
      true -> Process.sleep(50) && await?(conn, expression, tries - 1)
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
