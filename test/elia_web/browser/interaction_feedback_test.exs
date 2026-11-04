defmodule EliaWeb.InteractionFeedbackTest do
  @moduledoc """
  Interaction feedback (FEED-1 - FEED-7, FEED-9 in specs/interaction-feedback.md),
  in a real headless Chromium (BROWSER-1, BROWSER-7): a pressed control is a
  computed style, and a wait state is LiveView's own loading class arriving and
  leaving, neither of which `Phoenix.LiveViewTest` ever sees.

  Where a wait has to be watched for a moment rather than raced, the socket is
  slowed down with LiveView's own `liveSocket.enableLatencySim/1`, which holds
  the reply back until the class has been read.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # FEED-1, FEED-2, FEED-9: a control answers the pointer at once, on any page.
  # Held down, a button is pressed and a navigation link is tinted; and the press
  # is still there a moment after the pointer comes up, so a quick tap is seen
  # rather than flickering.
  test "a control presses as it is held, on any page", %{conn: conn} do
    id = chat()

    conn = conn |> visit("/c/#{id}") |> connected() |> hold("#view-toggle")

    assert pressed_scale(conn, "#view-toggle") < 1, "a held button is not pressed (FEED-1)"

    # FEED-2: sampled rather than read once, since what is checked is that the
    # press *lingers* after the pointer is up.
    assert smallest_scale_after_release(conn, "#view-toggle") < 1,
           "a button snapped back the moment the pointer came up (FEED-2)"

    # FEED-9: the other kind of control, and another page's header. A navigation
    # link is as wide as the list it sits in, so it tints instead of shrinking
    # (FEED-1) — and the tint has to be told apart from the hover it gets at the
    # same moment, since that is where "did my tap land?" is asked.
    conn = conn |> visit("/settings") |> connected()

    hovered = conn |> hover("#settings-link") |> background("#settings-link")
    pressed = conn |> hold("#settings-link") |> background("#settings-link")

    assert pressed != hovered,
           "a held link looks exactly like a hovered one (FEED-1): #{pressed}"

    release(conn)
  end

  # FEED-3, FEED-4: a click the server has not answered reads as working — but
  # only after a moment, so a reply that comes straight back never flashes one —
  # and a click that never reaches the server never reads as working at all.
  test "a click the server is still working on shows the control waiting", %{conn: conn} do
    id = chat()
    conn = conn |> visit("/c/#{id}") |> connected() |> slow_socket()

    # One click, watched from inside the browser, so the moment it is answered
    # and the moment it is not can be told apart (FEED-4).
    watched = watch_click(conn, "#view-toggle", 800)
    samples = js_get(watched, "samples")
    size = js_get(watched, "size")

    early = Enum.filter(samples, &(number(js_get(&1, "t")) < 120))
    waiting = Enum.filter(samples, &(number(js_get(&1, "t")) > 250))
    assert early != []

    # FEED-4: nothing to see yet. A control that dimmed here would flash on every
    # quick reply.
    assert Enum.all?(early, &(number(js_get(&1, "opacity")) == 1.0)),
           "the control dimmed before FEED-4's moment, so a quick reply would flash"

    # FEED-3: marked for the round trip, and it says so — pulsing, with the
    # progress cursor, and without changing size.
    assert Enum.all?(samples, &(js_get(&1, "loading") == true)),
           "the control the server is working for was not marked (FEED-3)"

    assert Enum.all?(samples, &(js_get(&1, "animation") == "elia-pending"))
    assert Enum.all?(samples, &(js_get(&1, "cursor") == "progress"))

    assert Enum.any?(waiting, &(number(js_get(&1, "opacity")) < 1)),
           "a control the server is still working on never dimmed (FEED-3)"

    assert Enum.uniq(Enum.map(samples, &{js_get(&1, "width"), js_get(&1, "height")})) ==
             [{js_get(size, "width"), js_get(size, "height")}],
           "the waiting control changed size, so the page moved under the user (FEED-3)"

    # ... and it stops the moment the reply lands.
    conn = wait_until(conn, "!#{loading_js("#view-toggle")}", "the wait state outlived the reply")
    assert field(conn, "#view-toggle", "animation") == "none"
    assert number(field(conn, "#view-toggle", "opacity")) == 1.0

    # FEED-3: a `phx-click` that only runs in the browser — the settings page's
    # theme buttons are a bare `JS.dispatch` — never reaches the server, so not
    # even a slow socket may make it look like waiting for one.
    conn =
      conn
      |> disable_latency_sim()
      |> visit("/settings")
      |> connected()

    watched = watch_click(conn, ~s(#theme-toggle button[data-phx-theme="dark"]), 300)

    refute Enum.any?(js_get(watched, "samples"), &js_get(&1, "loading")),
           "a click that never reaches the server looked like waiting for it (FEED-3)"
  end

  # FEED-5, FEED-6: a form being submitted waits on the button that sent it —
  # LiveView disables that button and marks it for the round trip — while the
  # form itself and the input beside it keep their look.
  test "a submitted form waits on its button, not on the whole form", %{conn: conn} do
    id = chat()
    FakeLLM.push(FakeLLM.assistant([Message.text("Answer from the fake model.")]))

    conn =
      conn
      |> visit("/c/#{id}")
      |> connected()
      |> type("#chat-input", "hello")
      |> slow_socket()

    # Submitting from the input (the composer's own Enter hook calls
    # `requestSubmit()`, with no submitter) is the case where LiveView marks the
    # whole form — the form, its buttons and its inputs — which is what FEED-5
    # is about: one control waits, the rest of the form keeps its look.
    conn = press(conn, "#chat-input", "Enter")

    # FEED-5: LiveView marked the input beside the button, and it is not dimmed
    # for it.
    assert field(conn, "#chat-input", "classes") =~ "phx-submit-loading",
           "LiveView did not mark the submitted form's input"

    assert field(conn, "#chat-input", "animation") == "none"
    assert number(field(conn, "#chat-input", "opacity")) == 1.0

    # FEED-5: the form element is marked as well, and keeps its look too.
    assert field(conn, "#chat-form", "classes") =~ "phx-submit-loading"
    assert field(conn, "#chat-form", "animation") == "none"
    assert number(field(conn, "#chat-form", "opacity")) == 1.0

    # FEED-3, FEED-6: the control that sent it is the one that waits — marked,
    # disabled by LiveView for the round trip, pulsing, saying so with its
    # cursor.
    assert field(conn, "#send-button", "classes") =~ "phx-submit-loading"

    assert field(conn, "#send-button", "disabled") == true,
           "LiveView did not disable the button it is submitting with"

    assert field(conn, "#send-button", "animation") == "elia-pending"
    assert field(conn, "#send-button", "cursor") == "progress"
  end

  # FEED-6, FEED-7: a disabled control keeps the look the app gives it, says so
  # under the pointer, and takes no press; and the keyboard can see where it is,
  # while the pointer leaves nothing behind.
  test "a disabled control is inert, and keyboard focus is visible", %{conn: conn} do
    id = chat()
    conn = conn |> visit("/c/#{id}") |> connected()

    # FEED-7: the browser's own tab order decides, and whatever the keyboard
    # reaches shows the ring — here a button of the composer's toolbar.
    conn = press(conn, "#chat-settings-link", "Tab")
    reached = state(conn, "#view-toggle")

    assert js_get(reached, "focused"),
           "tabbing on from the chat's settings link did not reach the Focus button: " <>
             "the keyboard is on " <>
             "#{js(conn, "document.activeElement.id || document.activeElement.tagName")}"

    assert_ring(reached, "a button the keyboard reached")

    # FEED-7: a pointer click leaves no ring behind, so the ring still means
    # "the keyboard is here". (The click has to reach a control the keyboard did
    # not already focus: a control that is focus-visible keeps it, since a click
    # on the element that already has focus fires no focus event at all.)
    conn = js_dismiss_keyboard_focus(conn)
    conn = click(conn, "#view-toggle")
    clicked = state(conn, "#view-toggle")

    assert js_get(clicked, "focused"), "the mouse click did not focus the control it hit"

    refute js_get(clicked, "focusVisible"),
           "a control the mouse clicked kept a keyboard focus ring (FEED-7)"

    # FEED-6: the app has no control that is disabled and idle — its own are
    # disabled only while a round trip of theirs is in flight — so the test adds
    # one, with the classes the app's own disabled controls carry.
    conn = add_disabled_control(conn)
    disabled = state(conn, "#feed-disabled")

    assert js_get(disabled, "cursor") == "not-allowed",
           "a disabled control does not say it is disabled (FEED-6)"

    assert number(js_get(disabled, "opacity")) == 0.5,
           "a disabled control lost the look the app itself gives it (FEED-6)"

    # FEED-6: and it takes no press. Its wait state is the other half of the
    # requirement, and it belongs to a button LiveView disabled *for* a round
    # trip, which the submit test above covers.
    before = js_get(disabled, "background")
    conn = hold(conn, "#feed-disabled")

    assert js_get(state(conn, "#feed-disabled"), "background") == before
    assert scale(conn, "#feed-disabled") == 1.0, "a disabled control took a press (FEED-6)"
    release(conn)

    # FEED-7, FEED-9: and on another page, where the header is a plain nav (a
    # chat's own header carries the chat-list toggle instead, UI-32), the same
    # holds for a navigation link.
    conn = conn |> visit("/settings") |> connected() |> press("#chats-link", "Tab")
    reached = state(conn, "#projects-link")

    assert js_get(reached, "focused"),
           "tabbing on from Chats did not reach Projects: the keyboard is on " <>
             "#{js(conn, "document.activeElement.id || document.activeElement.tagName")}"

    assert_ring(reached, "a navigation link the keyboard reached")
  end

  # A chat to open, cleaned up with the test.
  defp chat do
    id = Agent.new_id()
    :ok = Store.save(id, [], project: "harness")
    on_exit(fn -> Store.delete(id) end)
    id
  end

  # The page is only interactive once the LiveView socket connected and its hooks
  # mounted; LiveView puts `phx-connected` on its own container then.
  defp connected(conn) do
    wait_until(
      conn,
      "document.querySelector('.phx-connected')",
      "the LiveView never connected",
      8_000
    )
  end

  # FEED-3, FEED-4: a reply that is deliberately slow, so a wait can be watched
  # instead of raced. It lives in the browser session, so it goes with the page.
  defp slow_socket(conn) do
    js(conn, "window.liveSocket.enableLatencySim(1500)")
    conn
  end

  defp disable_latency_sim(conn) do
    js(conn, "window.liveSocket.disableLatencySim()")
    conn
  end

  # The pointer, held down on a control, which is the browser's own `:active` — a
  # few lines of Playwright, and not something `click/2` can do.
  defp hold(conn, selector) do
    {x, y} = centre(conn, selector)
    mouse(conn, :move, {x, y})
    mouse(conn, :down)
    conn
  end

  defp hover(conn, selector) do
    {x, y} = centre(conn, selector)
    mouse(conn, :move, {x, y})

    wait_until(
      conn,
      "#{background_js(selector)} !== 'rgba(0, 0, 0, 0)'",
      "the hover never showed"
    )
  end

  defp release(conn), do: mouse(conn, :up)

  # The keyboard put focus where it is; a pointer click on that same element
  # would keep the ring, since focusing an already focused element fires nothing.
  defp js_dismiss_keyboard_focus(conn) do
    js(conn, "document.activeElement.blur()")
    conn
  end

  defp mouse(conn, action), do: mouse(conn, action, nil)

  defp mouse(conn, action, coords) do
    unwrap(conn, fn %{page_id: page_id} ->
      if coords do
        {x, y} = coords
        {:ok, _} = PlaywrightEx.Page.mouse_move(page_id, timeout: 5_000, x: x, y: y)
      end

      case action do
        :move -> :ok
        :down -> {:ok, _} = PlaywrightEx.Page.mouse_down(page_id, timeout: 5_000)
        :up -> {:ok, _} = PlaywrightEx.Page.mouse_up(page_id, timeout: 5_000)
      end
    end)

    conn
  end

  defp centre(conn, selector) do
    conn
    |> js("""
    (() => {
      const box = document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect()
      return {x: Math.round(box.left + box.width / 2), y: Math.round(box.top + box.height / 2)}
    })()
    """)
    |> then(&{js_get(&1, "x"), js_get(&1, "y")})
  end

  # FEED-1: the press eases in over a few frames, so this waits for it and then
  # reads it: the assertion is on the state, not on the race.
  defp pressed_scale(conn, selector) do
    wait_until(conn, "#{scale_js(selector)} < 1", "#{selector} never showed a press (FEED-1)")
    scale(conn, selector)
  end

  defp scale(conn, selector), do: conn |> js(scale_js(selector)) |> number()

  # FEED-2: the smallest scale seen in the few moments after the pointer comes
  # up. A press that snapped back at once reads 1 here.
  defp smallest_scale_after_release(conn, selector) do
    release(conn)

    conn
    |> js("""
    new Promise(resolve => {
      const el = document.querySelector(#{Jason.encode!(selector)})
      const read = () => {
        if (el === null) return 1
        const scale = getComputedStyle(el).scale
        return scale === "none" ? 1 : parseFloat(scale)
      }
      let smallest = read()
      const until = performance.now() + 60
      const sample = () => {
        smallest = Math.min(smallest, read())
        if (performance.now() < until) requestAnimationFrame(sample)
        else resolve(smallest)
      }
      sample()
    })
    """)
    |> number()
  end

  defp background(conn, selector), do: js(conn, background_js(selector))

  defp background_js(selector),
    do: "getComputedStyle(document.querySelector(#{Jason.encode!(selector)})).backgroundColor"

  # The browser's computed press, with an element that declares none reading as
  # its natural size (the CSS `scale` property is `none` until a rule sets it).
  defp scale_js(selector) do
    """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)})
      if (el === null) return 1
      const scale = getComputedStyle(el).scale
      return scale === "none" ? 1 : parseFloat(scale)
    })()
    """
  end

  defp loading_js(selector),
    do:
      "document.querySelector(#{Jason.encode!(selector)}).classList.contains('phx-click-loading')"

  # Everything a control's look can be read from, in one evaluation: the classes
  # the browser put on it, and the values it computed from the stylesheet.
  defp state(conn, selector) do
    js(conn, """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)})
      const style = getComputedStyle(el)
      return {
        classes: el.className,
        disabled: !!el.disabled,
        opacity: style.opacity,
        animation: style.animationName,
        cursor: style.cursor,
        background: style.backgroundColor,
        outlineWidth: style.outlineWidth,
        outlineStyle: style.outlineStyle,
        focusVisible: el.matches(":focus-visible"),
        focused: document.activeElement === el
      }
    })()
    """)
  end

  defp field(conn, selector, key), do: conn |> state(selector) |> js_get(key)

  # FEED-7: the ring a control focused with the keyboard shows.
  defp assert_ring(reached, what) do
    assert js_get(reached, "focusVisible") and js_get(reached, "outlineWidth") == "2px" and
             js_get(reached, "outlineStyle") == "solid",
           "#{what} shows no ring (FEED-7): #{inspect(reached)}"
  end

  # One click, watched from inside the browser: each sample carries the moment it
  # was taken, so FEED-4's first 150ms can be told from what follows, and the
  # control's size before the click is kept to compare against.
  defp watch_click(conn, selector, for_ms) do
    js(conn, """
    new Promise(resolve => {
      const el = document.querySelector(#{Jason.encode!(selector)})
      const box = el.getBoundingClientRect()
      const size = {width: Math.round(box.width), height: Math.round(box.height)}
      const samples = []
      const t0 = performance.now()
      el.click()
      const sample = () => {
        const style = getComputedStyle(el)
        const rect = el.getBoundingClientRect()
        samples.push({
          t: Math.round(performance.now() - t0),
          loading: el.classList.contains("phx-click-loading"),
          opacity: style.opacity,
          animation: style.animationName,
          cursor: style.cursor,
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        })
        if (performance.now() - t0 < #{for_ms}) setTimeout(sample, 20)
        else resolve({size: size, samples: samples})
      }
      sample()
    })
    """)
  end

  # FEED-6: a control the app itself keeps disabled and idle. The app's own
  # disabled controls carry `disabled:opacity-50`; this one carries the same
  # classes, so what the browser styles is the app's own look.
  defp add_disabled_control(conn) do
    js(conn, """
    (() => {
      const button = document.createElement("button")
      button.id = "feed-disabled"
      button.disabled = true
      button.className = "flex h-10 items-center rounded-xl bg-primary px-4 text-sm font-medium text-primary-content disabled:opacity-50"
      button.textContent = "Disabled"
      document.body.appendChild(button)
      return true
    })()
    """)

    conn
  end

  # `evaluate/3` hands the value to a function instead of returning it, so the
  # value is parked in the test process (where that function runs) and read back.
  defp js(conn, expression) do
    evaluate(conn, expression, &Process.put(:elia_js_value, &1))
    Process.get(:elia_js_value)
  end

  # A JavaScript object arrives as JSON, so its keys are strings.
  defp js_get(map, key) when is_map(map), do: Map.get(map, to_string(key))

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number(_value), do: nil

  # Waits for the page's own JavaScript: the expression is evaluated until it is
  # truthy or the deadline passes, so a test never races the socket.
  defp wait_until(conn, expression, message, timeout \\ 3_000) do
    evaluate(
      conn,
      """
      new Promise(resolve => {
        const until = Date.now() + #{timeout}
        const check = () => {
          if (#{expression}) return resolve(true)
          if (Date.now() > until) return resolve(false)
          setTimeout(check, 20)
        }
        check()
      })
      """,
      [timeout: timeout + 1_000],
      fn reached -> assert reached, "#{message} (within #{timeout}ms)" end
    )
  end
end
