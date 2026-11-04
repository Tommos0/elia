defmodule EliaWeb.ChatLayoutTest do
  @moduledoc """
  The chat page fits the screen (UI-78 in specs/chat-ui.md), which is a question
  about geometry — what the browser lays out, not what the server renders — so it
  is asked of a real headless Chromium (BROWSER-1, BROWSER-7).

  The three viewports are a desktop, a phone and a short window; the phone ones
  are here for the width as much as the height. Chromium is not the engine the
  layout was reported broken in — a phone's URL bar or on-screen keyboard
  covering the page (UI-78, PWA-7) cannot be emulated here — so what these tests
  hold is the page's own end of the bargain: however tall the window is, the
  composer is on screen, the document never scrolls, and the message list is
  what scrolls.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, Store}
  alias Elia.LLM.Message

  # UI-78: the viewport applies to the browser context, which the case creates
  # per test, so each size is a test of its own.
  @tag browser_context_opts: [viewport: %{width: 1280, height: 800}]
  test "a desktop screen fits (UI-78)", %{conn: conn} do
    conn |> visit_chat(empty_chat()) |> assert_fits()
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 660}]
  test "a phone screen fits (UI-78)", %{conn: conn} do
    conn |> visit_chat(empty_chat()) |> assert_fits()
  end

  @tag browser_context_opts: [viewport: %{width: 320, height: 420}]
  test "a short screen fits, and the message list is what scrolls (UI-78)", %{conn: conn} do
    # UI-78: an empty transcript first — the case a layout that lets the content
    # size the page shows it, since the empty state is a tall block.
    geometry = conn |> visit_chat(empty_chat()) |> assert_fits()

    assert js_get(geometry, "transcriptScrollHeight") > 0,
           "the empty state is not laid out inside the message list"

    # UI-78: and a full transcript scrolls in the message list, leaving the page
    # as it was.
    geometry = conn |> visit_chat(full_chat()) |> assert_fits()

    assert js_get(geometry, "transcriptScrollHeight") >
             js_get(geometry, "transcriptClientHeight"),
           "the message list did not become the scroll area of a full transcript"
  end

  # UI-78: the page fits, measured in the browser: the header and the composer
  # are wholly on screen, the document itself does not scroll, the shell is one
  # visible viewport tall, and the message list — which may shrink to nothing —
  # is the page's scroll area.
  defp assert_fits(conn) do
    geometry = geometry(conn)
    height = js_get(geometry, "viewportHeight")
    composer = js_get(geometry, "composer")

    assert js_get(geometry, "documentScrollHeight") <= height,
           "the page itself scrolls: #{inspect(geometry)}"

    assert js_get(composer, "bottom") <= height and js_get(composer, "top") >= 0,
           "the composer is not wholly on screen: #{inspect(composer)}"

    assert js_get(js_get(geometry, "header"), "top") == 0,
           "the header scrolled off the top of the page: #{inspect(geometry)}"

    assert js_get(js_get(geometry, "shell"), "height") == height,
           "the shell is not one visible viewport tall: #{inspect(js_get(geometry, "shell"))}"

    # UI-78: the message list is the scroll area, and the composer comes after it.
    assert js_get(geometry, "transcriptOverflowY") == "auto"
    assert js_get(js_get(geometry, "transcript"), "bottom") <= js_get(composer, "top")

    # UI-78: explicitly allowed to shrink to nothing, rather than left at the
    # height its content asks for. An engine that keeps the flex child at its
    # content height (the automatic minimum size) pushes the composer off the
    # screen with a long transcript, which is what this pins down.
    assert js_get(geometry, "transcriptMinHeight") == "0px",
           "the message list is not allowed to shrink: #{js_get(geometry, "transcriptMinHeight")}"

    geometry
  end

  defp visit_chat(conn, id), do: conn |> visit("/c/#{id}") |> connected()

  defp empty_chat do
    id = Agent.new_id()
    :ok = Store.save(id, [], project: "harness")
    on_exit(fn -> Store.delete(id) end)
    id
  end

  # A transcript far longer than any screen shows at once.
  defp full_chat do
    id = Agent.new_id()

    messages =
      for n <- 1..40 do
        Message.user("Message #{n}: " <> String.duplicate("a long line of text. ", 6))
      end

    :ok = Store.save(id, messages, project: "harness")
    on_exit(fn -> Store.delete(id) end)
    id
  end

  # Everything the assertions read, in one evaluation.
  defp geometry(conn) do
    js(conn, """
    (() => {
      const rect = (selector) => {
        const box = document.querySelector(selector).getBoundingClientRect()
        return {top: Math.round(box.top), bottom: Math.round(box.bottom), height: Math.round(box.height)}
      }
      const transcript = document.querySelector("#transcript-scroll")
      return {
        viewportHeight: window.innerHeight,
        header: rect("body header"),
        shell: rect("#app-shell"),
        transcript: rect("#transcript-scroll"),
        composer: rect("#chat-form"),
        transcriptScrollHeight: transcript.scrollHeight,
        transcriptClientHeight: transcript.clientHeight,
        transcriptOverflowY: getComputedStyle(transcript).overflowY,
        transcriptMinHeight: getComputedStyle(transcript).minHeight,
        documentScrollHeight: document.documentElement.scrollHeight
      }
    })()
    """)
  end

  # The page is only laid out once the LiveView socket connected and its hooks
  # mounted; LiveView puts `phx-connected` on its own container then.
  defp connected(conn) do
    wait_until(conn, "document.querySelector('.phx-connected')", "the LiveView never connected")
  end

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

  # `evaluate/3` hands the value to a function instead of returning it, so the
  # value is parked in the test process (where that function runs) and read back.
  defp js(conn, expression) do
    evaluate(conn, expression, &Process.put(:elia_js_value, &1))
    Process.get(:elia_js_value)
  end

  # A JavaScript object arrives as JSON, so its keys are strings.
  defp js_get(map, key) when is_map(map), do: Map.get(map, to_string(key))
end
