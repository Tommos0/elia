defmodule EliaWeb.UiScaleBrowserTest do
  @moduledoc """
  The UI scale in a real headless Chromium (BROWSER-8): a slider over the page's
  root font size, kept in the browser (CONF-30 - CONF-35). The scale is the
  browser's own — no request carries it to the server (CONF-32) — so what
  applies it before the page is painted, what the slider does to the page and
  what a load keeps are only visible here, and `Phoenix.LiveViewTest`, which
  runs no JavaScript, sees none of it.

  A browser run needs built assets and the user-wide Playwright CLI (BROWSER-2,
  BROWSER-6), and is excluded from a plain `mix test` (BROWSER-5):

      mix assets.build
      ELIA_BROWSER_TESTS=1 mix test --only real_browser
  """

  use EliaWeb.BrowserCase

  alias Elia.LLM.LlamaServer

  # CONF-33: the page head applies the stored scale while the page is being
  # parsed — before the deferred bundle runs and so before anything is painted —
  # rather than a load of the page being drawn at 100% and jumping.
  test "a stored scale is in force before the bundle runs", %{conn: conn} do
    conn = conn |> visit("/settings") |> store("125") |> visit("/settings")

    assert value(conn, "document.documentElement.style.fontSize") == "125%"
    assert value(conn, head_applies_it?())
  end

  # CONF-30, CONF-31, CONF-34: the slider scales the page as it is moved, the
  # readout follows it, and the reset puts both back.
  test "the slider scales the page and the reset puts it back", %{conn: conn} do
    conn = conn |> visit("/settings") |> open_scale()

    heading = value(conn, heading_size())

    # Five steps of 5% from the default are 125% (CONF-30), driven the way the
    # control takes a keyboard — a real `input` event on the range.
    conn = Enum.reduce(1..5, conn, fn _, conn -> press(conn, "#ui-scale-range", "ArrowRight") end)

    # CONF-31: 125% is the root font size, so what the page sizes in rem — its
    # own text, not only the control's readout — is a quarter larger.
    assert value(conn, "document.documentElement.style.fontSize") == "125%"
    assert value(conn, readout()) == "125%"
    assert value(conn, heading_size()) == heading * 1.25

    # CONF-32: under the browser's own key...
    assert value(conn, "localStorage.getItem('elia:ui-scale')") == "125"

    # ...and the server knows nothing of it, so a re-render it hands the page
    # leaves the scale and the control as the user left them.
    broadcast_status("http://patched.invalid:7/")
    assert await?(conn, on_screen?("http://patched.invalid:7/"))
    assert value(conn, "document.documentElement.style.fontSize") == "125%"
    assert value(conn, readout()) == "125%"

    conn = click(conn, "#ui-scale-reset")

    assert value(conn, "document.documentElement.style.fontSize") == "100%"
    assert value(conn, readout()) == "100%"
    assert value(conn, heading_size()) == heading
  end

  # CONF-33: a reload and a move to another page of the app are both scaled, and
  # the settings page comes back showing the scale it was left at (CONF-34).
  test "the scale outlives the page it was set on", %{conn: conn} do
    conn = conn |> visit("/settings") |> open_scale()

    conn = Enum.reduce(1..3, conn, fn _, conn -> press(conn, "#ui-scale-range", "ArrowRight") end)
    assert value(conn, "document.documentElement.style.fontSize") == "115%"

    conn = conn |> visit("/settings") |> open_scale()

    assert value(conn, "document.documentElement.style.fontSize") == "115%"
    assert value(conn, readout()) == "115%"

    conn = visit(conn, "/")

    assert value(conn, "document.documentElement.style.fontSize") == "115%"
  end

  # CONF-35: a stored scale that is missing, is not a number or is outside the
  # range the control offers is 100%.
  test "a stored scale that cannot be read is 100%", %{conn: conn} do
    for stored <- ["nonsense", "400", "0", ""] do
      conn = conn |> visit("/settings") |> store(stored) |> visit("/settings") |> open_scale()

      assert value(conn, "document.documentElement.style.fontSize") == "100%",
             "a stored value of #{inspect(stored)} was applied"

      assert value(conn, readout()) == "100%"
    end
  end

  # CONF-30: the section holds the control, collapsed until its header is
  # clicked (CONF-25).
  defp open_scale(conn) do
    conn
    |> click("#appearance summary")
    |> assert_has("#appearance[open]")
  end

  # CONF-32: the scale in the browser's own store, put there before the page
  # that reads it is loaded.
  defp store(conn, value),
    do: evaluate(conn, "localStorage.setItem('elia:ui-scale', #{inspect(value)})")

  defp readout, do: "document.querySelector('#ui-scale-value').textContent.trim()"

  # CONF-31: a size in rem — the page's own heading.
  defp heading_size, do: "parseFloat(getComputedStyle(document.querySelector('h1')).fontSize)"

  # CONF-33: what applies the scale is the head's own inline script, which runs
  # as the page is parsed, rather than the bundle the page defers, which runs
  # only once the page has been parsed and a hook of it later still. That is
  # what leaves no page drawn at one scale and jumping to another.
  defp head_applies_it? do
    """
    (() => {
      const scripts = Array.from(document.head.querySelectorAll('script'))
      const scale = scripts.find(s => !s.src && s.textContent.includes('elia:ui-scale'))
      const bundle = scripts.find(s => s.src && s.src.includes('/assets/js/app.js'))
      return !!scale && !!bundle && bundle.defer
    })()
    """
  end

  # LOCAL-26: the status this page is subscribed to, with the field the section
  # renders moved, so the re-render it causes is a change the page can be seen
  # to take.
  defp on_screen?(url) do
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
