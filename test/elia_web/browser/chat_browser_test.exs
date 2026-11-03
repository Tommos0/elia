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

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # BROWSER-8: `/` reaches a chat page. That redirect is a `push_navigate` from
  # the mounted LiveView, so a chat form being there means the socket connected
  # and the page's scripts ran.
  test "the chat page loads in the browser and moves on to a chat", %{conn: conn} do
    opened = session_ids()

    conn =
      conn
      |> visit("/")
      |> assert_has("#sidebar")
      |> assert_has("#chat-form")

    evaluate(conn, "window.location.pathname", fn path ->
      assert path =~ ~r{^/c/[\w-]+$}
    end)

    # Opening `/` made a chat: leave the workspace as we found it.
    on_exit(fn -> for id <- session_ids() -- opened, do: Store.delete(id) end)
  end

  # BROWSER-8: a message typed in the browser is sent and answered. Enter comes
  # from the colocated `.SubmitOnEnter` hook, so this covers JavaScript that the
  # LiveView tests never run.
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

  # The page is only interactive once the LiveView socket connected and its hooks
  # mounted; LiveView puts `phx-connected` on its own container then.
  defp connected(conn),
    do:
      wait_until(conn, "document.querySelector('.phx-connected')", "the LiveView never connected")

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
