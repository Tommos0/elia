defmodule EliaWeb.Browser.TerminalTest do
  @moduledoc """
  The terminal page in a real browser (TERM-12, TERM-13, TERM-14, TERM-21).

  What it is made of is a hook drawing xterm.js and a channel carrying bytes —
  neither of which a LiveView test can see (BROWSER-1, BROWSER-7). A server-side
  test passes with a terminal that never draws anything and a keyboard that
  never reaches the app, so this is the only place the path as a whole is asked
  for.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, Terminal}

  @moduletag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")

  setup do
    id = Agent.new_id()
    # TERM-3: deleting the chat stops its terminal, so a browser test leaves no
    # process tree behind.
    on_exit(fn -> Agent.delete(id) end)
    %{id: id}
  end

  # TERM-12, TERM-14, TERM-21: starting one draws a terminal in the pane, at the
  # page's own width and height, and the screen the session sends is written
  # into it.
  test "starting a terminal draws it and shows what the app wrote", %{conn: conn, id: id} do
    conn =
      conn
      |> visit("/c/#{id}/terminal")
      |> fill_in("Command to run", with: "printf 'hello from tmux\\n'; sleep 30")
      |> click_button("Start")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    wait_until(
      conn,
      "document.querySelector('#terminal .xterm-rows').innerText.includes('hello from tmux')",
      "the screen the session sent never reached the terminal (TERM-14)"
    )

    # TERM-21: the terminal fills what is left of the page rather than sitting
    # in the chat's column.
    evaluate(
      conn,
      """
      (() => {
        const term = document.querySelector('#terminal')
        const pane = document.querySelector('#terminal-pane')
        return {
          termHeight: term.querySelector('.xterm-screen').clientHeight,
          paneHeight: pane.clientHeight,
          viewportHeight: window.innerHeight
        }
      })()
      """,
      fn sizes ->
        assert js_get(sizes, "termHeight") > js_get(sizes, "viewportHeight") * 0.5,
               "the terminal is not filling the page: #{inspect(sizes)}"

        assert js_get(sizes, "termHeight") <= js_get(sizes, "paneHeight")
      end
    )
  end

  # TERM-13: what is typed reaches the app, and the app's answer comes back and
  # is drawn — the whole path, in a browser. The command's own output is what is
  # asked for, not its echo: the pty echoes a line whether or not anything runs
  # it.
  test "what is typed reaches the shell, and its answer is drawn", %{conn: conn, id: id} do
    # No command: the chat's own shell, which is reading what is typed into it.
    conn = conn |> visit("/c/#{id}/terminal") |> click_button("Start")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    conn =
      conn
      |> type("#terminal .xterm-helper-textarea", "printf 'BT-%s\\n' $((6*7))")
      |> press("#terminal .xterm-helper-textarea", "Enter")

    wait_until(
      conn,
      "document.querySelector('#terminal .xterm-rows').innerText.includes('BT-42')",
      "what was typed never reached the shell (TERM-13)"
    )
  end

  # TERM-15: the pty is the size of the box the browser draws, so a full-screen
  # app is the size of the page rather than of a guess.
  test "the shell's size is the terminal's size", %{conn: conn, id: id} do
    conn = conn |> visit("/c/#{id}/terminal") |> click_button("Start")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    conn =
      conn
      |> type("#terminal .xterm-helper-textarea", "stty size")
      |> press("#terminal .xterm-helper-textarea", "Enter")

    # `stty size` answers rows then columns, and the rows it answers are the rows
    # the browser drew: a pty left at the size the session guessed (TERM-15)
    # answers a number of its own instead.
    wait_until(
      conn,
      """
      (() => {
        const rows = Array.from(document.querySelectorAll('#terminal .xterm-rows > div'))
        const size = rows.map(r => r.innerText.trim()).find(t => /^\\d+\\s+\\d+$/.test(t))
        return !!size && Number(size.split(/\\s+/)[0]) === rows.length
      })()
      """,
      "the shell's size is not the terminal's own (TERM-15)"
    )
  end

  # What Playwright hands back is a map with string keys.
  defp js_get(map, key) when is_map(map), do: Map.get(map, to_string(key))

  # A promise the page resolves: the expression is evaluated until it is truthy
  # or the deadline passes, so a test never races the socket (BROWSER).
  defp wait_until(conn, expression, message, timeout \\ 10_000) do
    evaluate(
      conn,
      """
      new Promise(resolve => {
        const until = Date.now() + #{timeout}
        const check = () => {
          try {
            if (#{expression}) return resolve(true)
          } catch (e) {}
          if (Date.now() > until) return resolve(false)
          setTimeout(check, 25)
        }
        check()
      })
      """,
      [timeout: timeout + 2_000],
      fn reached -> assert reached, "#{message} (within #{timeout}ms)" end
    )
  end
end
