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

  # TERM-42, TERM-43, TERM-44, TERM-49: a tap on the bar's key reaches the app;
  # an armed Ctrl changes a character typed on the soft keyboard into that key
  # and is spent by it; a bar key is sent plain and leaves the arming alone; and
  # both arrive in the order they were made — a tap between two keystrokes is
  # between them in the app as well.
  test "the bar's keys reach the app, and an armed Ctrl changes what is typed",
       %{conn: conn, id: id} do
    dir = start_reading(id)
    conn = visit(conn, "/c/#{id}/terminal")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    # TERM-48: this browser has a fine pointer, where the bar is hidden until the
    # page's own toggle shows it.
    conn = click(conn, "#terminal-keys-toggle")

    # TERM-44: Ctrl is armed by a tap...
    conn = click(conn, "#terminal-key-ctrl")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "armed")

    # ...and a bar key is sent plain: it neither takes the armed modifier — tmux
    # would type the letters `C-Escape` into the app — nor spends it, so Ctrl is
    # still armed for the next character typed.
    conn = click(conn, "#terminal-key-esc")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "armed")

    # TERM-42, TERM-49: that character is the next key, and the tap on the bar is
    # between the two of them in the app as well.
    conn = type(conn, "#terminal .xterm-helper-textarea", "c")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "off")

    assert read_typed(dir, "\x1b\x03") == "\x1b\x03"
    _ = conn
  end

  # TERM-46: holding an arrow repeats it, the way a held key on a keyboard does,
  # and letting go stops it.
  test "holding an arrow repeats it", %{conn: conn, id: id} do
    dir = start_reading(id)
    conn = visit(conn, "/c/#{id}/terminal")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    # TERM-48: shown first, as the toggle test above does, since this browser is
    # a fine pointer.
    conn = click(conn, "#terminal-keys-toggle")

    # A finger on the button and off it again, with no `click`: this is the press
    # that repeats, not the tap.
    evaluate(
      conn,
      """
      (() => {
        const button = document.querySelector('#terminal-key-up')
        button.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}))
        setTimeout(() => window.dispatchEvent(new PointerEvent('pointerup', {bubbles: true})), 800)
        return true
      })()
      """
    )

    # TERM-43: an arrow is a name tmux expands, which the app has set no mode
    # for, so one press is the three bytes a keyboard would send — sent more
    # than once, because the press was held.
    assert read_typed(dir, "\e[A\e[A") == "\e[A\e[A"
    _ = conn
  end

  # TERM-45: a second tap locks a modifier, and every key after it goes with it
  # until it is tapped once more. That is what makes Ctrl-R, Ctrl-Z or Ctrl-A
  # reachable from a phone's own keyboard, which has no Ctrl at all.
  test "a locked modifier stays on for the keys after it", %{conn: conn, id: id} do
    dir = start_reading(id)
    conn = visit(conn, "/c/#{id}/terminal")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    conn = click(conn, "#terminal-keys-toggle")

    # TERM-44: armed for one key; TERM-45: tapped again, locked for every key —
    # which the page shows, so the user can see which state it is in.
    conn = click(conn, "#terminal-key-ctrl")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "armed")

    conn = click(conn, "#terminal-key-ctrl")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "locked")
    assert_attribute(conn, "#terminal-key-ctrl", "aria-pressed", "true")

    # Two characters typed on the soft keyboard both go with it, one as Ctrl-C
    # and the next as Ctrl-D.
    conn =
      conn
      |> type("#terminal .xterm-helper-textarea", "c")
      |> type("#terminal .xterm-helper-textarea", "d")

    # A bar key is sent as its own name whatever is armed, so the Escape goes as
    # it is and the lock is still on for what is typed next.
    conn = click(conn, "#terminal-key-esc")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "locked")

    # The tap that turns it off again.
    conn = click(conn, "#terminal-key-ctrl")
    assert_attribute(conn, "#terminal-key-ctrl", "data-state", "off")

    assert read_typed(dir, "\x03\x04\x1b") == "\x03\x04\x1b"
    _ = conn
  end

  # TERM-48: the bar is hidden where the pointer is fine — this browser — and
  # the page's toggle overrides that, which is how a desktop with a touch screen
  # gets it, and how a phone that wants the rows back turns it off.
  test "the toggle overrides where the bar is shown", %{conn: conn, id: id} do
    {:ok, _pid} =
      Terminal.start(id, command: "sleep 60", workspace: keys_dir(id), jail: false)

    conn = visit(conn, "/c/#{id}/terminal")

    wait_until(
      conn,
      "!!document.querySelector('#terminal .xterm-rows')",
      "xterm.js never drew the terminal (TERM-12)"
    )

    # The choice is the browser's, so a choice left by an earlier page is cleared
    # before the default is asked for.
    evaluate(conn, "localStorage.removeItem('elia:terminal-keys')")
    conn = visit(conn, "/c/#{id}/terminal")

    # TERM-48: hidden, because this browser's pointer is fine.
    assert_style(conn, "#terminal-keys", "display", "none")

    conn = click(conn, "#terminal-keys-toggle")
    assert_style(conn, "#terminal-keys", "display", "flex")
    assert_attribute(conn, "#terminal-keys-toggle", "aria-pressed", "true")

    # TERM-47: the bar is a row of its own with room of its own, so showing it
    # takes its height from the page rather than covering the terminal's last
    # rows.
    conn =
      evaluate(conn, "document.querySelector('#terminal-keys').clientHeight > 0", fn shown ->
        assert shown, "the bar took no room of its own (TERM-47)"
      end)

    conn = click(conn, "#terminal-keys-toggle")
    assert_style(conn, "#terminal-keys", "display", "none")
    assert_attribute(conn, "#terminal-keys-toggle", "aria-pressed", "false")

    # The choice is this browser's: a test leaves none behind for the next one.
    evaluate(conn, "localStorage.removeItem('elia:terminal-keys')")
  end

  # A directory of the test's own: the app it starts writes what it is sent
  # there and the test reads it. Not the chat's workspace, where a `ready` file
  # left by an earlier test would be one this test finds at once.
  defp keys_dir(id) do
    dir = Path.join(System.tmp_dir!(), "elia-terminal-keys-#{id}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # The app of a key-bar test: it puts its pty in raw mode — so a control
  # character arrives as a byte rather than as a signal — says it is ready, and
  # then writes every byte it is sent into `typed`, where a test reads it.
  defp start_reading(id) do
    dir = keys_dir(id)

    {:ok, _pid} =
      Terminal.start(id,
        command: "stty raw -echo; : > ready; cat > typed",
        workspace: dir,
        jail: false
      )

    wait_for_file(Path.join(dir, "ready"))
    dir
  end

  defp wait_for_file(path, tries \\ 200)
  defp wait_for_file(path, 0), do: flunk("the app never wrote #{path}")

  defp wait_for_file(path, tries) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      wait_for_file(path, tries - 1)
    end
  end

  # TERM-49: the order the app received the bytes in, once they have arrived —
  # tmux is told before the app reads, so what is there when the wait runs out is
  # returned, and a failure shows what arrived instead.
  defp read_typed(dir, expected, tries \\ 300)
  defp read_typed(dir, _expected, 0), do: File.read!(Path.join(dir, "typed"))

  defp read_typed(dir, expected, tries) do
    path = Path.join(dir, "typed")

    if File.read(path) == {:ok, expected} do
      expected
    else
      Process.sleep(10)
      read_typed(dir, expected, tries - 1)
    end
  end

  # What the page computed for an element, asserted where the value comes back:
  # `evaluate` hands it to its function and returns the connection, so a test
  # that wants the value asserts inside it, and the message carries the value
  # that was there instead — which is what a failure needs to be read.
  defp assert_style(conn, selector, property, expected) do
    evaluate(
      conn,
      "getComputedStyle(document.querySelector('#{selector}')).#{property}",
      fn value ->
        assert value == expected,
               "#{selector}'s #{property} is #{inspect(value)}, not #{inspect(expected)}"
      end
    )
  end

  defp assert_attribute(conn, selector, name, expected) do
    evaluate(conn, "document.querySelector('#{selector}').getAttribute('#{name}')", fn value ->
      assert value == expected,
             "#{selector}'s #{name} is #{inspect(value)}, not #{inspect(expected)}"
    end)
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
