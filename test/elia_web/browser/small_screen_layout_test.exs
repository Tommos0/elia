defmodule EliaWeb.SmallScreenLayoutTest do
  @moduledoc """
  The Home, System and Logs pages at a phone width (DASH-12 in
  specs/dashboard.md, SYS-12 in specs/system-dashboard.md, LOG-11 in
  specs/log-viewer.md). How wide a page comes out is a question about geometry,
  so it is asked of a real headless Chromium (BROWSER-1, BROWSER-7) — and it is
  the page's own scroll area, not the document, that scrolls sideways when a
  card grows to fit its contents.

  DASH-12 is a title's: a chat title is one unbreakable line (`truncate`,
  TITLE-2's 60 characters), and the cards' column has to be able to shrink
  below it. SYS-12 is a state check rather than a regression guard: `/system`
  reads the machine's real `/proc` (SYS-1), so a test cannot hand it a value
  wide enough to trip the layout. LOG-11 is a row's: a log entry's message must
  get a line of its own, not a column a character wide. UI-83 is a question
  card's: its question and the answer it got wrap, where every other card's text
  is a command or a diff read by its columns (UI-15, UI-20).
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, Logs, Store}
  alias Elia.LLM.Message

  require Logger

  # DASH-12, SYS-12: the viewport applies to the browser context, which the
  # case creates per test (as the chat layout tests do, UI-78).
  @phone [viewport: %{width: 390, height: 900}]

  # HOT-8: `grid-template-columns: none` is the layout a bundle without the new
  # grid rule gives, and it reports how many elements it touched, so the test
  # can tell "the fix held" from "there was nothing to neutralise".
  @without_new_grid_rule """
  () => {
    const els = [...document.querySelectorAll('.grid-cols-1')];
    els.forEach((el) => { el.style.gridTemplateColumns = 'none'; });
    return els.length;
  }
  """

  @tag browser_context_opts: @phone
  test "a long chat title doesn't scroll Home sideways (DASH-12)", %{conn: conn} do
    id = "layout-long-title"
    # The chat's title is longer than the screen, so a card that grew to fit it
    # would take the page with it (TITLE-2 cuts it to 60 characters).
    :ok = Store.save(id, [], title: String.duplicate("a-long-chat-title-", 4))
    on_exit(fn -> Store.delete(id) end)

    conn
    |> visit("/")
    |> assert_has("#recent-chats", text: "a-long-chat-title-")
    |> refute_sideways_scroll("#home-scroll")
  end

  @tag browser_context_opts: @phone
  test "the System page doesn't scroll sideways (SYS-12)", %{conn: conn} do
    conn |> visit("/system") |> refute_sideways_scroll("#system-scroll")
  end

  # HOT-8, DASH-12: a page keeps the stylesheet it loaded — the browser fetches a
  # new one only on a full page load, and the bundle the running app serves may
  # itself be older than the markup. So a fit must not need a rule that
  # stylesheet may not have yet: `grid-template-columns: none` is the layout a
  # bundle without the new class gives, and the cards still fit, because the
  # columns carry `min-w-0` (in use since the app's first commit).
  @tag browser_context_opts: @phone
  test "a long chat title fits with the stylesheet the page already has (HOT-8)", %{conn: conn} do
    id = "layout-old-css"
    :ok = Store.save(id, [], title: String.duplicate("b-long-chat-title-", 4))
    on_exit(fn -> Store.delete(id) end)

    conn
    |> visit("/")
    |> assert_has("#recent-chats", text: "b-long-chat-title-")
    |> evaluate(@without_new_grid_rule, [is_function: true], fn neutralised ->
      assert neutralised > 0, "no element carried the page's new grid rule to neutralise"
    end)
    |> refute_sideways_scroll("#home-scroll")
  end

  @sideways_scroll """
  sel => {
    const el = document.querySelector(sel);
    return [window.innerWidth, el.scrollWidth - el.clientWidth];
  }
  """

  # LOG-11: the row's own content width is the yardstick, and the message is the
  # innermost element that carries the text.
  @log_message "logs-phone: a log message long enough to need more than one line on a phone"

  @entry_geometry """
  text => {
    const li = [...document.querySelectorAll('#log-entries li')].find((el) =>
      el.textContent.includes(text)
    );
    if (!li) return null;

    const message = [...li.querySelectorAll('*')].find(
      (el) => el.children.length === 0 && el.textContent.includes(text)
    );
    if (!message) return null;

    const style = getComputedStyle(li);
    const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
    const source = [...li.querySelectorAll('*')].find(
      (el) => el.children.length === 0 && el.textContent.includes('SmallScreenLayoutTest')
    );

    return {
      // What the message may use: the row without its own padding.
      content: li.clientWidth - padding,
      message: message.clientWidth,
      // The message starts below the time and level, not beside them.
      stacked: message.getBoundingClientRect().top >=
        li.querySelector('time').getBoundingClientRect().bottom - 1,
      // LOG-9: on a wide screen the source is the row's last item, after the
      // message — the wrapper is `contents` there, so the order is the markup's.
      source_last: source != null &&
        source.getBoundingClientRect().left >= message.getBoundingClientRect().left,
      // Nothing in the row may push it wider: a long source is cut off.
      overflow: li.scrollWidth - li.clientWidth,
    };
  }
  """

  # UI-83: a question card reads as prose — the question and the answer it got
  # wrap, however long they are. The card's own `<pre>` is the yardstick: the
  # page fits either way, because such an element scrolls its own text.
  @question "Which of the two jails should this chat use for its tests? " <>
              String.duplicate("jail-option-", 14)
  @answer ~s(The user answered: "Neither: use the sandbox jail, ) <>
            String.duplicate("sandbox-", 16) <> ~s(.")

  @question_geometry """
  () => {
    const measure = (selector) => {
      const el = document.querySelector(selector);
      if (!el) return null;
      const style = getComputedStyle(el);
      return {
        overflow: el.scrollWidth - el.clientWidth,
        lines: el.clientHeight / parseFloat(style.lineHeight),
        wrapping: style.whiteSpace,
      };
    };
    return {
      question: measure("#items-call-q1 pre"),
      answer: measure("#output-q1 pre"),
    };
  }
  """

  @tag browser_context_opts: @phone
  test "a question and the answer it got wrap on a phone (UI-83)", %{conn: conn} do
    id = Agent.new_id()

    :ok =
      Store.save(id, [
        Message.user("set it up"),
        %Message{
          role: :assistant,
          content: [
            %{type: :tool_call, id: "q1", name: "ask_user", input: %{"question" => @question}},
            %{type: :tool_call, id: "s1", name: "shell", input: %{"command" => "mix test"}}
          ]
        },
        %Message{
          role: :tool,
          content: [
            Message.tool_result("q1", @answer),
            Message.tool_result("s1", "ok")
          ]
        }
      ])

    on_exit(fn -> Store.delete(id) end)

    conn
    |> visit("/c/#{id}")
    |> assert_has("#items-call-q1")
    |> evaluate(@question_geometry, [is_function: true], fn geometry ->
      for {key, part, text} <- [
            {"question", "the question", @question},
            {"answer", "the answer it got", @answer}
          ] do
        measured = geometry[key]

        assert measured, "#{part} is not on the page"

        # UI-83: the text wraps rather than running off the card sideways. Both
        # carry a word longer than a phone's line, so a missing break-rule shows
        # up here as overflow.
        assert measured["overflow"] <= 0,
               "#{part} runs #{measured["overflow"]}px past the card's edge: #{text}"

        assert measured["lines"] > 1.5,
               "#{part} takes #{measured["lines"]} lines: it did not wrap"

        assert measured["wrapping"] == "pre-wrap",
               "#{part} is laid out with white-space: #{measured["wrapping"]}"
      end
    end)
  end

  @tag browser_context_opts: @phone
  test "a log entry's message gets a line of its own on a phone (LOG-11)", %{conn: conn} do
    Logs.clear()

    conn
    |> visit("/logs")
    # LOG-6: the entry arrives over the socket, so the page has to bring it in.
    |> tap(fn _ -> Logger.warning(@log_message) end)
    # The row is what the assertion waits for: on the layout this fixes, the
    # message is a box with no width of its own.
    |> assert_has("#log-entries li[data-level]", timeout: 2000)
    |> evaluate(@entry_geometry, [is_function: true, arg: @log_message], fn entry ->
      assert entry, "the entry for the logged line never appeared on the page"

      # LOG-11: the message is the row's width — this module's mfa and a pid are
      # a long source for the line above it.
      assert entry["message"] >= entry["content"] * 0.95,
             "the message is #{entry["message"]}px of the row's #{entry["content"]}px"

      assert entry["stacked"],
             "the message is drawn beside the time and level, not below them"

      # The parts that don't shrink may not push the row wider, so the source is
      # cut off rather than spilling out of it.
      assert entry["overflow"] <= 0,
             "the entry's row overflows sideways by #{entry["overflow"]}px"
    end)
  end

  # LOG-11: from `sm` up an entry is the single row of LOG-9 again — the
  # wrapper's `contents` puts the message back among the row's own items and the
  # source's `order-last` after it.
  @tag browser_context_opts: [viewport: %{width: 1280, height: 900}]
  test "a log entry is one row on a wide screen (LOG-11)", %{conn: conn} do
    Logs.clear()

    conn
    |> visit("/logs")
    |> tap(fn _ -> Logger.warning(@log_message) end)
    |> assert_has("#log-entries li[data-level]", timeout: 2000)
    |> evaluate(@entry_geometry, [is_function: true, arg: @log_message], fn entry ->
      assert entry, "the entry for the logged line never appeared on the page"

      refute entry["stacked"], "the message is on a line of its own on a wide screen"
      assert entry["source_last"], "the source is not the last thing in the row"

      assert entry["overflow"] <= 0,
             "the entry's row overflows sideways by #{entry["overflow"]}px"
    end)
  end

  defp refute_sideways_scroll(conn, selector) do
    evaluate(conn, @sideways_scroll, [is_function: true, arg: selector], fn [window, overflow] ->
      # DASH-12, SYS-12: the width the measurement is taken at, so a viewport
      # that never applied can't pass the test from a desktop layout.
      assert window == 390, "the window is #{window}px wide, not the phone's 390px"

      assert overflow <= 0,
             "#{selector} scrolls sideways by #{overflow}px in a 390px window"
    end)
  end
end
