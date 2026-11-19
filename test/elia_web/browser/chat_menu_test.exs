defmodule EliaWeb.ChatMenuBrowserTest do
  @moduledoc """
  The composer toolbar's chat menu in a real browser (UI-97): the drop-up's
  own bindings — a second press on its trigger, a click outside it and Escape —
  which `Phoenix.LiveViewTest` never exercises, since it calls events by name
  rather than by clicking.

  A browser test, so it runs with `ELIA_BROWSER_TESTS=1` (BROWSER-5).
  """
  use EliaWeb.BrowserCase

  alias Elia.{Agent, FakeLLM}

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  defp js(conn, expression) do
    evaluate(conn, expression, &Process.put(:menu_js, &1))
    Process.get(:menu_js)
  end

  defp connected(conn) do
    Enum.reduce_while(1..40, conn, fn _, conn ->
      if js(conn, "!!document.querySelector('.phx-connected')") do
        {:halt, conn}
      else
        Process.sleep(200)
        {:cont, conn}
      end
    end)
  end

  defp menu_open?(conn), do: js(conn, "!!document.querySelector('#chat-menu')")

  defp chat(conn) do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    conn |> visit("/c/#{id}") |> connected()
  end

  # UI-97: the trigger opens the panel, and the panel it opens sits above it —
  # the toolbar is at the bottom of the screen, so it has nowhere else to go.
  test "the trigger opens the panel above itself", %{conn: conn} do
    conn = chat(conn)
    refute menu_open?(conn)

    conn = click(conn, "#chat-menu-button")
    assert menu_open?(conn)

    [menu, button] =
      js(conn, """
      (() => { const m = document.querySelector('#chat-menu').getBoundingClientRect();
        const b = document.querySelector('#chat-menu-button').getBoundingClientRect();
        return [Math.round(m.bottom), Math.round(b.top)]; })()
      """)

    assert menu <= button, "the panel is not above the trigger (UI-97): #{menu} > #{button}"
  end

  # UI-97: a second press shuts it — the trigger is not "outside" its own panel.
  test "a second press shuts the panel", %{conn: conn} do
    conn = chat(conn) |> click("#chat-menu-button")
    assert menu_open?(conn)

    conn = click(conn, "#chat-menu-button")
    refute menu_open?(conn)
  end

  # UI-97: a click anywhere outside it, and Escape, shut it too.
  test "a click outside the panel and Escape shut it", %{conn: conn} do
    conn = chat(conn) |> click("#chat-menu-button")
    assert menu_open?(conn)

    conn = click(conn, "#transcript-scroll")
    refute menu_open?(conn)

    conn = conn |> click("#chat-menu-button")
    assert menu_open?(conn)

    conn = press(conn, "#chat-menu-button", "Escape")
    refute menu_open?(conn)
  end
end
