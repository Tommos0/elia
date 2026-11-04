defmodule EliaWeb.SmallScreenLayoutTest do
  @moduledoc """
  The Home and System pages at a phone width (DASH-12 in specs/dashboard.md,
  SYS-12 in specs/system-dashboard.md). How wide a page comes out is a question
  about geometry, so it is asked of a real headless Chromium (BROWSER-1,
  BROWSER-7) — and it is the page's own scroll area, not the document, that
  scrolls sideways when a card grows to fit its contents.

  DASH-12 is a title's: a chat title is one unbreakable line (`truncate`,
  TITLE-2's 60 characters), and the cards' column has to be able to shrink
  below it. SYS-12 is a state check rather than a regression guard: `/system`
  reads the machine's real `/proc` (SYS-1), so a test cannot hand it a value
  wide enough to trip the layout.
  """

  use EliaWeb.BrowserCase

  alias Elia.Store

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
