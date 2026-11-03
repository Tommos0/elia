defmodule EliaWeb.ChatBrowserTest do
  @moduledoc """
  The chat page in a real headless Chromium (BROWSER-8): the websocket, the
  colocated JavaScript hooks and the DOM as a browser sees them, which
  `Phoenix.LiveViewTest` cannot cover.

  `Elia.FakeLLM` answers the model call, because the tests drive the test env
  server in this same node (BROWSER-7).
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

  defp session_ids, do: Store.list(100) |> Enum.map(& &1.id)
end
