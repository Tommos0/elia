defmodule EliaWeb.ChatBrowserTest do
  @moduledoc """
  The chat page in a real headless Chromium (BROWSER-8): the websocket, the
  colocated JavaScript hooks and the DOM as a browser sees them, which
  `Phoenix.LiveViewTest` cannot cover.

  `Elia.FakeLLM` answers the model call, because the tests drive the test env
  server in this same node (BROWSER-7). The image viewer is covered here too
  (IMG-1 - IMG-5): it is JavaScript, a history entry and the back button.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, FakeLLM, Store, Workspace}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # BROWSER-8: `/` loads the dashboard (DASH-1) without starting a chat, and
  # `/chats` reaches a chat page. That redirect is a `push_navigate` from the
  # mounted LiveView, so a chat form being there means the socket connected and
  # the page's scripts ran. `/chats` resumes the latest chat (UI-77), and
  # starts one only when there is none (STORE-22).
  test "the home page and the chat list entry point load in the browser", %{conn: conn} do
    opened = session_ids()

    # DASH-1: the dashboard renders in place — a page of cards, no chat form.
    conn
    |> visit("/")
    |> assert_has("#continue")
    |> assert_has("#recent-chats")
    |> refute_has("#chat-form")

    # Nothing was started by looking at it.
    assert session_ids() == opened

    conn =
      conn
      |> visit("/chats")
      |> assert_has("#sidebar")
      |> assert_has("#chat-form")

    evaluate(conn, "window.location.pathname", fn path ->
      assert path =~ ~r{^/c/[\w-]+$}
    end)

    # Opening `/chats` made a chat: leave the workspace as we found it.
    on_exit(fn -> for id <- session_ids() -- opened, do: Store.delete(id) end)
  end

  # BROWSER-8, UI-21: a message typed in the browser is sent and answered. Enter
  # comes from the colocated `.SubmitOnEnter` hook, so this covers JavaScript that
  # the LiveView tests never run.
  test "Enter in the message box sends the message and shows the answer", %{conn: conn} do
    id = Agent.new_id()
    :ok = Store.save(id, [], project: "harness")
    on_exit(fn -> Store.delete(id) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Answer from the fake model.")]))

    conn
    |> visit("/c/#{id}")
    |> assert_has("#chat-form")
    |> type("#chat-input", "hello from a real browser")
    |> press("#chat-input", "Enter")
    |> assert_has("#transcript", text: "hello from a real browser")
    |> assert_has("#transcript", text: "Answer from the fake model.")
  end

  # CITE-5, CITE-7 - CITE-9 (specs/spec-citations.md): a citation carries the
  # requirement's own text in its `title` — and a touch screen never sees one,
  # since no browser shows a `title` on a tap, which is why tapping one did
  # nothing. So a tap shows the text in the popover instead, beside the
  # citation, and this layer is where that lives: the popover is the browser's
  # own DOM, filled and placed by the `.SpecTip` hook (CITE-9).
  test "a tap shows a citation's requirement, and what closes it", %{conn: conn} do
    id = citation_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()

    # CITE-9: the server renders it hidden, and empty — nothing of the text is
    # on the page until a tap puts it there.
    refute_has(conn, "#spec-tip")
    assert_tip_text(conn, "")

    # CITE-9: LiveView never patches it, so a patch cannot empty it out from
    # under an open popover (IMG-8 covers that mechanism for the image viewer).
    evaluate(conn, "document.querySelector('#spec-tip').getAttribute('phx-update')", fn value ->
      assert value == "ignore", "the popover is LiveView's to patch"
    end)

    # CITE-5: the citation is no control — it goes nowhere and has nothing for
    # the keyboard to act on.
    refute_has(conn, "a.spec-cite")
    refute_has(conn, "button.spec-cite")

    # CITE-5, CITE-7: a tap on it shows the requirement's own text.
    conn =
      conn
      |> click("#transcript .spec-cite")
      |> assert_has("#spec-tip", text: "A requirement a tap can read.")

    # CITE-5: and it is still not a navigation: the chat is still the page.
    assert_path(conn, "/c/#{id}")

    # CITE-7: beside the citation that was tapped, inside the screen.
    assert_beside_the_citation(conn)

    # CITE-8: a second tap on the same citation closes it, and so does a tap
    # that lands on the text beside the marked span — which is not the citation.
    conn = conn |> click("#transcript .spec-cite") |> refute_has("#spec-tip")

    # CITE-8: a tap anywhere else closes it too.
    conn =
      conn
      |> click("#transcript .spec-cite")
      |> assert_has("#spec-tip", text: "A requirement a tap can read.")
      |> click("#chat-input")
      |> refute_has("#spec-tip")

    # CITE-8: so does Escape.
    conn =
      conn
      |> click("#transcript .spec-cite")
      |> assert_has("#spec-tip", text: "A requirement a tap can read.")
      |> press("#chat-input", "Escape")
      |> refute_has("#spec-tip")

    # CITE-8: so does a scroll of the transcript — the popover would otherwise
    # sit over content it no longer belongs to.
    conn =
      conn
      |> click("#transcript .spec-cite")
      |> assert_has("#spec-tip", text: "A requirement a tap can read.")
      |> scroll_transcript_up()
      |> refute_has("#spec-tip")

    # CITE-8: and so does the citation leaving the page, which is what a message
    # re-rendered without it does (UI-10 — a streaming draft when the reply
    # lands). This is the last thing this test does to the citation. The
    # transcript goes back to its end first: a scroll is one of the ways the
    # popover closes, and Playwright scrolls a citation into view before it taps
    # it, so a citation left off the screen would be closed by its own tap.
    conn =
      conn
      |> scroll_transcript_to_end()
      |> click("#transcript .spec-cite")
      |> assert_has("#spec-tip", text: "A requirement a tap can read.")
      |> remove_citation()
      |> refute_has("#spec-tip")

    assert_path(conn, "/c/#{id}")
  end

  # IMG-1 - IMG-4 (specs/image-viewer.md): an image in the transcript opens in the
  # viewer over the chat — never in a new tab — and the back button closes it,
  # rather than leaving the page and, in an installed app, leaving Android's back
  # button closing the whole app.
  test "an image opens in the viewer, and the back button closes it", %{conn: conn} do
    id = image_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()
      # IMG-2: the viewer is not on the page until an image is clicked. This is a
      # visibility assertion, so it covers the hidden state of IMG-6 too.
      |> refute_has("#image-lightbox")
      |> click("#transcript .markdown img")
      |> assert_has("#image-lightbox")
      |> assert_has("#image-lightbox-image[src='/images/icon-192.png'][alt='shot']")

    # IMG-1: opening it is not a navigation away.
    assert_path(conn, "/c/#{id}")

    # IMG-4: the back button — Android's, in the browser's terms — closes the
    # viewer, and the chat behind it is where it was.
    conn =
      conn
      |> evaluate("history.back()")
      |> refute_has("#image-lightbox")
      |> assert_has("#transcript .markdown img")

    assert_path(conn, "/c/#{id}")
  end

  # IMG-3, IMG-5: the viewer's own close button, the backdrop and Escape all close
  # it — and IMG-4: closing it that way goes back over the entry opening it
  # pushed, so the back button afterwards does what it did before.
  test "the close button, the backdrop and Escape close the viewer", %{conn: conn} do
    id = image_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()

    # IMG-5: opening it puts focus on the close button, so Escape (or Enter) needs
    # no tap.
    conn =
      conn
      |> click("#transcript .markdown img")
      |> assert_has("#image-lightbox")
      |> evaluate("document.activeElement.id", fn id ->
        assert id == "image-lightbox-close", "the viewer did not take focus"
      end)
      # IMG-3: the close button is the viewer's own, so closing never depends on
      # the browser's or the phone's back control.
      |> click("#image-lightbox-close")
      |> refute_has("#image-lightbox")
      |> history_clean()

    conn =
      conn
      |> click("#transcript .markdown img")
      |> assert_has("#image-lightbox")
      |> press("#image-lightbox-close", "Escape")
      |> refute_has("#image-lightbox")
      |> history_clean()

    # IMG-3: a click on the picture itself keeps the viewer open; one on the
    # backdrop closes it.
    conn =
      conn
      |> click("#transcript .markdown img")
      |> assert_has("#image-lightbox")
      |> click("#image-lightbox-image")
      |> assert_has("#image-lightbox")
      |> click_backdrop()
      |> refute_has("#image-lightbox")
      |> history_clean()

    assert_path(conn, "/c/#{id}")
  end

  # IMG-7 (specs/image-viewer.md): the closed viewer is not on the page whatever
  # stylesheet the page has. A page can render this markup while its stylesheet
  # is the one from before the change — a deploy hot-reloads code into a running
  # app (DEPLOY-6) and a browser fetches a new stylesheet only on a full page
  # load (HOT-8), and a deploy never rebuilds the built assets at all — so a
  # full-screen overlay kept hidden by a *new* rule would swallow every tap of
  # a page that never loaded that rule.
  test "the closed viewer is not visible without the app's stylesheet", %{conn: conn} do
    id = image_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()
      # The stylesheet a page has when it has not been reloaded since the change.
      |> evaluate(
        "document.querySelectorAll('link[rel=stylesheet]').forEach(el => el.disabled = true)"
      )

    # Untouchable: nothing of it takes a tap (this is a visibility assertion).
    refute_has(conn, "#image-lightbox")

    # IMG-2, IMG-7: the dark backdrop is its own markup's too, so what it shows
    # is still a viewer once the hook opens it.
    evaluate(
      conn,
      "getComputedStyle(document.querySelector('#image-lightbox')).backgroundColor",
      fn colour ->
        assert colour =~ ~r/rgba?\(0, 0, 0, 0\.85\)/,
               "the viewer has no backdrop of its own: #{colour}"
      end
    )
  end

  # IMG-8 (specs/image-viewer.md): whether the viewer is open is the DOM's own
  # state, so a hook that has just mounted closes a viewer an earlier instance
  # opened — on its close button, on the backdrop and on Escape alike (IMG-3).
  #
  # That instance is LiveView's own: it mounts the hook on an element it sees
  # added, so each round takes the viewer out of the page and lets the next
  # patch put it back. What the test writes to it then is exactly what opening
  # it writes — the picture, its alt text, the element's own `style` and the
  # history entry (IMG-4) — because the server renders the viewer closed
  # (IMG-7), so nothing else can put an open viewer under an instance that never
  # opened one.
  test "a hook that has just mounted closes a viewer an earlier instance opened", %{conn: conn} do
    id = image_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()

    # IMG-3: the viewer's own close button.
    conn =
      conn
      |> viewer_open_beside_a_fresh_hook()
      |> click("#image-lightbox-close")
      |> refute_has("#image-lightbox")
      |> history_clean()

    # IMG-3: the backdrop, never the picture itself.
    conn =
      conn
      |> viewer_open_beside_a_fresh_hook()
      |> click_backdrop()
      |> refute_has("#image-lightbox")
      |> history_clean()

    # IMG-3: Escape.
    conn
    |> viewer_open_beside_a_fresh_hook()
    |> press("#image-lightbox-close", "Escape")
    |> refute_has("#image-lightbox")
    |> history_clean()
  end

  # UI-87 (specs/chat-ui.md): the jump-to-the-end button at the top of the chat
  # brings a reader who scrolled up back to the last message — and the follow
  # state of UI-14 comes back with it, so the content arriving afterwards is
  # followed again. It is a `JS.dispatch` rather than an event, so the server
  # never sees the press: only a browser does.
  test "the jump-to-the-end button scrolls back to the last message (UI-87)", %{conn: conn} do
    id = long_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()
      # UI-14: scrolled up, the way the reader this button is for left it.
      |> evaluate("document.querySelector('#transcript-scroll').scrollTop = 0")
      |> assert_scrolled_up()

    # UI-87: it is there beside the context indicator (CTX-1).
    assert_has(conn, "#jump-to-end")

    # UI-87: pressing it puts the transcript's end back on screen — no round
    # trip, so nothing has to come back from the server first.
    conn = conn |> click("#jump-to-end") |> assert_scrolled_to_end()

    # UI-87, UI-14: and the follow state came back with it, so a reply that
    # arrives afterwards leaves the list at its end rather than where it was.
    FakeLLM.push(FakeLLM.assistant([Message.text(long_reply())]))

    conn
    |> type("#chat-input", "one more")
    |> press("#chat-input", "Enter")
    |> assert_has("#transcript", text: "Answer from the fake model.")
    |> assert_scrolled_to_end()
  end

  # UI-94 (specs/chat-ui.md): the reader's own move up stops the following at the
  # moment they make it, whatever they make it with — and not a frame later,
  # when the browser reports the scroll position, which is where content still
  # arriving in that frame used to pull the view back down.
  test "the reader's own move up stops the transcript following (UI-94)", %{conn: conn} do
    for {what, move} <- scroll_up_moves() do
      id = long_chat()

      conn =
        conn
        |> visit("/c/#{id}")
        |> connected()
        |> assert_scrolled_to_end()

      # UI-94: the move, and content landing before the browser has reported it.
      # The move scrolls nothing of itself, so the input event is the only thing
      # that can stop the following, and the appended element stands in for the
      # message that arrives in that frame.
      conn =
        evaluate(conn, """
        (() => {
          const transcript = document.querySelector("#transcript-scroll")
          #{move}
          const arriving = document.createElement("div")
          arriving.style.height = "600px"
          transcript.appendChild(arriving)
        })()
        """)

      evaluate(conn, scroll_gap(), fn gap ->
        assert gap > 80,
               "the transcript followed content arriving after #{what} (only #{gap}px away)"
      end)
    end
  end

  # UI-94: and it is the reader's move that keeps a reply arriving afterwards
  # from pulling the view down — the case with plenty of output in the
  # transcript, where a scroll up would not hold.
  test "a reply arriving after a move up is not followed (UI-94)", %{conn: conn} do
    id = long_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()
      |> assert_scrolled_to_end()
      |> scroll_up_by_wheel()

    FakeLLM.push(FakeLLM.assistant([Message.text(long_reply())]))

    conn =
      conn
      |> type("#chat-input", "one more")
      |> press("#chat-input", "Enter")
      |> assert_has("#transcript", text: "Answer from the fake model.")

    assert_scrolled_up(conn)
  end

  # UI-87: the button is on any chat, and on one with nothing in it pressing it
  # scrolls nothing — and it is on screen on a phone, beside the context
  # indicator (CTX-1) rather than pushed off the edge by it. What a chat with
  # nothing to scroll asserts is that nothing went wrong: a hook that threw
  # there would fail this test through the case's logger (BROWSER-8).
  @tag browser_context_opts: [viewport: %{width: 390, height: 660}]
  test "the jump-to-the-end button is on screen on a phone, on an empty chat (UI-87)", %{
    conn: conn
  } do
    id = empty_chat()

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()
      |> assert_has("#jump-to-end")
      |> click("#jump-to-end")
      |> assert_has("#jump-to-end")

    assert_button_on_screen(conn)
  end

  # UI-89 (specs/chat-ui.md): what was typed in the message box outlives the
  # page. The draft is the browser's own — `localStorage`, one key per chat — so
  # only a real browser can see it, and each step here is the navigation the
  # page itself does: a reload, and the sidebar's live one, which reuses the
  # page's DOM rather than loading it again.
  test "a draft in the message box comes back when the chat is reopened (UI-89)", %{conn: conn} do
    first = empty_chat()
    second = empty_chat()
    draft_key = "elia:draft:#{first}"

    conn =
      conn
      |> visit("/c/#{first}")
      |> connected()
      |> type("#chat-input", "half a thought")
      |> wait_for_input("half a thought")

    # UI-89: the draft is kept under the key the requirement names, so it is
    # still there to be found when the chat is opened again.
    assert draft(conn, draft_key) == "half a thought"

    # UI-89: another chat has a draft of its own — the one written here is this
    # chat's, and the first chat's is left where it was.
    conn =
      conn
      |> visit("/c/#{second}")
      |> connected()
      |> type("#chat-input", "another thought")
      |> wait_for_input("another thought")

    assert draft(conn, "elia:draft:#{second}") == "another thought"
    assert draft(conn, draft_key) == "half a thought"

    # UI-89: the sidebar's live navigation, so the page is patched rather than
    # reloaded, and the box belongs to the chat it now shows — this chat's
    # draft, not the one that was in it a moment ago.
    conn =
      conn
      |> click("#chat-link-#{first}")
      |> wait_for_input("half a thought")
      |> assert_path("/c/#{first}")

    # UI-23, UI-89: sending the draft is what drops it — the box clears, and the
    # chat opened again comes back to an empty one.
    FakeLLM.push(FakeLLM.assistant([Message.text("Answer from the fake model.")]))

    conn =
      conn
      |> press("#chat-input", "Enter")
      |> assert_has("#transcript", text: "half a thought")
      |> wait_for_input("")

    assert draft(conn, draft_key) == nil
    assert draft(conn, "elia:draft:#{second}") == "another thought"

    conn
    |> visit("/c/#{first}")
    |> connected()
    |> wait_for_input("")
  end

  # UI-89: the message box reads what it is given, once the hook that keeps the
  # draft has put it there. The server renders the box empty (the draft is the
  # browser's), so waiting for a draft is what waits for that hook.
  defp wait_for_input(conn, text) do
    wait_until(
      conn,
      "document.querySelector('#chat-input').value === #{inspect(text)}",
      "the message box to read #{inspect(text)}"
    )
  end

  # UI-89: what the browser kept for a chat's draft, as `localStorage` holds it.
  # `evaluate/3` hands the value to a function instead of returning it, so it is
  # parked in the test process (where that function runs) and read back.
  defp draft(conn, key) do
    evaluate(conn, "localStorage.getItem(#{inspect(key)})", &Process.put(:elia_draft, &1))
    Process.get(:elia_draft)
  end

  # UI-87: a chat far longer than any screen shows at once, so the transcript
  # has an end to be away from and to jump back to.
  defp long_chat do
    id = Agent.new_id()

    messages =
      for n <- 1..40 do
        Message.user("Message #{n}: " <> String.duplicate("a long line of text. ", 6))
      end

    :ok = Store.save(id, messages, project: "harness")
    on_exit(fn -> Store.delete(id) end)
    id
  end

  defp empty_chat do
    id = Agent.new_id()
    :ok = Store.save(id, [], project: "harness")
    on_exit(fn -> Store.delete(id) end)
    id
  end

  # Long enough that a list which stopped following the end would be plainly
  # more than the hook's 80px away from it (UI-14, UI-87).
  defp long_reply, do: "Answer from the fake model. " <> String.duplicate("a long line. ", 20)

  # UI-94: each of the reader's own ways up, as the page hears it — a wheel up, a
  # finger dragging the content down, an upward key, and a press on the
  # transcript's own scrollbar, which is the element itself. Each is the body of
  # a function the test wraps around it, with `transcript` in its scope.
  defp scroll_up_moves do
    [
      {"a wheel up",
       ~s|transcript.dispatchEvent(new WheelEvent("wheel", {deltaY: -120, bubbles: true}))|},
      {"a finger dragging the content down",
       """
       const down = new Event("touchstart")
       down.touches = [{clientY: 100}]
       transcript.dispatchEvent(down)
       const drag = new Event("touchmove")
       drag.touches = [{clientY: 200}]
       transcript.dispatchEvent(drag)
       """},
      {"an upward key",
       ~s|transcript.dispatchEvent(new KeyboardEvent("keydown", {key: "ArrowUp", bubbles: true}))|},
      {"a press on the scrollbar",
       ~s|transcript.dispatchEvent(new MouseEvent("mousedown", {bubbles: true}))|}
    ]
  end

  # UI-94: the reader moving up with the wheel, and nothing else: what the
  # transcript's position does afterwards is the hook's own doing.
  defp scroll_up_by_wheel(conn) do
    evaluate(conn, """
    (() => {
      const transcript = document.querySelector("#transcript-scroll")
      transcript.dispatchEvent(new WheelEvent("wheel", {deltaY: -120, bubbles: true}))
    })()
    """)
  end

  # How far the transcript is from its end, by the hook's own measure (UI-14).
  defp scroll_gap do
    """
    (() => {
      const transcript = document.querySelector("#transcript-scroll")
      return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight
    })()
    """
  end

  defp assert_scrolled_up(conn) do
    evaluate(conn, scroll_gap(), fn gap ->
      assert gap > 80, "the transcript is only #{gap}px from its end, not scrolled up"
    end)
  end

  # UI-87: within the hook's own tolerance of the end, which a patch
  # reaches a moment after the click or after the reply streams in.
  defp assert_scrolled_to_end(conn) do
    wait_until(conn, "(#{scroll_gap()}) < 80", "the transcript never reached its end")
  end

  # UI-87: the whole button inside the viewport — a row that let the context
  # indicator push it off the edge would leave a control nobody can press.
  defp assert_button_on_screen(conn) do
    evaluate(
      conn,
      """
      (() => {
        const box = document.querySelector("#jump-to-end").getBoundingClientRect()
        return {
          left: Math.round(box.left),
          right: Math.round(box.right),
          top: Math.round(box.top),
          bottom: Math.round(box.bottom),
          width: window.innerWidth,
          height: window.innerHeight
        }
      })()
      """,
      fn box ->
        assert box["left"] >= 0 and box["right"] <= box["width"],
               "the jump-to-the-end button is off the side of the screen: #{inspect(box)}"

        assert box["top"] >= 0 and box["bottom"] <= box["height"],
               "the jump-to-the-end button is off the top or bottom: #{inspect(box)}"
      end
    )
  end

  # IMG-1: a chat with a picture in an assistant message. It is one of the app's
  # own static files, so the test needs nothing else served.
  defp image_chat do
    id = Agent.new_id()

    :ok =
      Store.save(id, [
        Message.user("show me"),
        %Message{
          role: :assistant,
          content: [Message.text("Here it is: ![shot](/images/icon-192.png)")]
        }
      ])

    on_exit(fn -> Store.delete(id) end)
    id
  end

  # CITE-4, CITE-7: a chat whose reply cites a requirement its own workspace's
  # corpus defines — `specs/*.md` of the folder the chat works in (CITE-4,
  # PROJ-12) — and long enough for the transcript to have somewhere to scroll
  # (CITE-8).
  defp citation_chat do
    specs = Path.join(Workspace.root(), "specs")
    File.mkdir_p!(specs)
    fixture = Path.join(specs, "browser_cite_fixture.md")

    File.write!(
      fixture,
      "# Fixture\n\n## Requirements\n\n- **TAPPY-1** A requirement a tap can read.\n"
    )

    on_exit(fn ->
      File.rm(fixture)
      if File.ls(specs) == {:ok, []}, do: File.rmdir(specs)
    end)

    id = Agent.new_id()

    before =
      for n <- 1..12 do
        Message.user("Message #{n}: " <> String.duplicate("a long line of text. ", 6))
      end

    reply = %Message{
      role: :assistant,
      content: [Message.text("See `TAPPY-1` for it.")]
    }

    :ok = Store.save(id, before ++ [reply])
    on_exit(fn -> Store.delete(id) end)
    id
  end

  # CITE-9: what the popover holds — the browser put it there, since the server
  # renders the element with no text of its own (its markup's own indentation is
  # all it has, so a whitespace-only reading is the empty one).
  defp assert_tip_text(conn, text) do
    evaluate(conn, "document.querySelector('#spec-tip').textContent", fn held ->
      assert String.trim(held) == String.trim(text), "the popover reads #{inspect(held)}"
    end)
  end

  # CITE-7: the popover is beside the citation it belongs to — over that
  # citation's own column on screen, and either just above it or just below it —
  # while staying inside the screen on both counts, so a citation at the top of
  # the transcript reads as well as one at the bottom.
  defp assert_beside_the_citation(conn) do
    evaluate(
      conn,
      """
      (() => {
        const cite = document.querySelector("#transcript .spec-cite").getBoundingClientRect()
        const tip = document.querySelector("#spec-tip").getBoundingClientRect()
        return {
          overlap: Math.round(Math.min(cite.right, tip.right) - Math.max(cite.left, tip.left)),
          gap: Math.round(Math.min(Math.abs(tip.bottom - cite.top), Math.abs(tip.top - cite.bottom))),
          box: {left: tip.left, right: tip.right, top: tip.top, bottom: tip.bottom},
          width: window.innerWidth,
          height: window.innerHeight
        }
      })()
      """,
      fn seen ->
        box = seen["box"]

        assert seen["overlap"] > 0,
               "the popover is not over the citation's own column: #{inspect(seen)}"

        assert seen["gap"] <= 12,
               "the popover is #{seen["gap"]}px away from the citation: #{inspect(seen)}"

        assert box["left"] >= 0 and box["right"] <= seen["width"],
               "the popover is off the side of the screen: #{inspect(seen)}"

        assert box["top"] >= 0 and box["bottom"] <= seen["height"],
               "the popover is off the top or bottom of the screen: #{inspect(seen)}"
      end
    )
  end

  # CITE-8: the reader scrolling the transcript, which is nothing to do with the
  # popover and closes it all the same.
  defp scroll_transcript_up(conn),
    do: evaluate(conn, "document.querySelector('#transcript-scroll').scrollTop = 0")

  # Back to the transcript's end, which is where a reader who taps the last
  # message's citation is (and where Playwright finds it without scrolling).
  defp scroll_transcript_to_end(conn) do
    evaluate(conn, """
    (() => {
      const transcript = document.querySelector("#transcript-scroll")
      transcript.scrollTop = transcript.scrollHeight
    })()
    """)
  end

  # CITE-8: the citation leaving the page, which is what a message re-rendered
  # without it does (UI-10).
  defp remove_citation(conn),
    do: evaluate(conn, "document.querySelector('#transcript .spec-cite').remove()")

  # The page is only interactive once the LiveView socket connected and its hooks
  # mounted; LiveView puts `phx-connected` on its own container then.
  defp connected(conn),
    do:
      wait_until(conn, "document.querySelector('.phx-connected')", "the LiveView never connected")

  # IMG-8: the page with a hook LiveView has just mounted on its viewer, and the
  # viewer open in the DOM and in the history, which that instance never opened.
  # LiveView mounts a hook on an element it sees added, so the viewer goes out of
  # the page and the next patch of the chat puts it back — as a fresh mount.
  defp viewer_open_beside_a_fresh_hook(conn) do
    conn
    |> evaluate("""
    (() => {
      document.querySelector("#image-lightbox").remove()
      document.querySelector("#view-toggle").click()
    })()
    """)
    |> wait_until(
      "!!document.querySelector('#image-lightbox')",
      "LiveView never put the viewer back"
    )
    # Exactly what opening the viewer writes (IMG-2, IMG-4).
    |> evaluate("""
    (() => {
      const viewer = document.querySelector("#image-lightbox")
      const image = viewer.querySelector("#image-lightbox-image")
      image.src = "/images/icon-192.png"
      image.alt = "shot"
      viewer.style.display = "flex"
      history.pushState({eliaImageViewer: true}, "", window.location.href)
    })()
    """)
    |> assert_has("#image-lightbox")
  end

  # IMG-3: Playwright clicks an element's centre, which on the viewer is where the
  # picture is, so the backdrop gets a click at a point in its own corner instead.
  defp click_backdrop(conn) do
    unwrap(conn, fn %{page_id: page_id} ->
      mouse = [timeout: 5_000]
      {:ok, _} = PlaywrightEx.Page.mouse_move(page_id, Keyword.merge(mouse, x: 8, y: 8))
      {:ok, _} = PlaywrightEx.Page.mouse_down(page_id, mouse)
      {:ok, _} = PlaywrightEx.Page.mouse_up(page_id, mouse)
    end)
  end

  # IMG-4: with the entry gone, the back button does what it did before the
  # viewer was ever opened. `history.back()` is a task of its own, hence the wait.
  defp history_clean(conn) do
    wait_until(
      conn,
      "!(window.history.state && window.history.state.eliaImageViewer)",
      "the viewer left its history entry behind"
    )
  end

  # Waits for the page's own JavaScript: the expression is evaluated until it is
  # truthy or the deadline passes, so a test never races the socket or a history
  # change. Playwright awaits the promise an `evaluate/4` returns.
  defp wait_until(conn, expression, message, timeout \\ 5_000) do
    evaluate(
      conn,
      """
      new Promise(resolve => {
        const until = Date.now() + #{timeout}
        const check = () => {
          if (#{expression}) return resolve(true)
          if (Date.now() > until) return resolve(false)
          setTimeout(check, 25)
        }
        check()
      })
      """,
      [timeout: timeout + 1_000],
      fn reached -> assert reached, "#{message} (within #{timeout}ms)" end
    )
  end

  defp session_ids, do: Store.list(100) |> Enum.map(& &1.id)
end
