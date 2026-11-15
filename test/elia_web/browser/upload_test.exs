defmodule EliaWeb.Browser.UploadTest do
  @moduledoc """
  Attaching a file in a real headless Chromium (BROWSER-1, BROWSER-8), and the
  message it is then sent with.

  UPLOAD-1 has a client half: the pick itself is what starts the upload.
  `Phoenix.LiveViewTest`'s upload helper drives an upload server-side — it hands
  the server an entry — so the LiveView suite passes with an attach control
  whose pick starts nothing at all. This is where the path as a whole is asked
  for.
  """

  use EliaWeb.BrowserCase

  alias Elia.{Agent, FakeLLM, Store, Workspace}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    # A chat with no project works in the runtime root (PROJ-12), which is where
    # its uploads land (UPLOAD-6) — the directory this test owns and clears.
    root = Workspace.root()
    File.rm_rf!(Path.join(root, "uploads"))
    on_exit(fn -> File.rm_rf!(Path.join(root, "uploads")) end)
    %{root: root}
  end

  # UPLOAD-1, UPLOAD-12: a file picked in the composer uploads from the pick
  # alone, with nothing sent, and the message it is then sent with carries it.
  test "a picked file uploads, and the message carries it", %{conn: conn, root: root} do
    id = Agent.new_id()
    :ok = Store.save(id, [], project: "harness")
    on_exit(fn -> Store.delete(id) end)

    name = "browser-upload.txt"
    # The browser hands the server the name the local file has, so the picked
    # file is set up under exactly the name this test then looks for.
    dir = Path.join(System.tmp_dir!(), "elia-browser-upload-#{id}")
    File.mkdir_p!(dir)
    picked = Path.join(dir, name)
    File.write!(picked, "hello from a real browser")
    on_exit(fn -> File.rm_rf(dir) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Got it.")]))

    conn =
      conn
      |> visit("/c/#{id}")
      # The pick only reaches the server once the page is live: before the
      # socket joins, the file input has no hook and a change goes nowhere.
      |> connected()
      |> assert_has("#upload-button", text: "Attach files")
      |> upload("Attach files", picked)
      # UPLOAD-3: the chip the composer holds what was picked in.
      |> assert_has("#upload-list", text: name)

    # UPLOAD-1: the pick alone carries the file all the way in — the composer
    # shows how far it is until then, and stops showing progress once it is
    # there.
    wait_until(
      conn,
      """
      (() => {
        const input = document.querySelector("#upload-form input[type=file]")
        const done = input.getAttribute("data-phx-done-refs") || ""
        const errors = input.getAttribute("data-phx-error-refs") || ""
        return done !== "" && errors === "" && !document.querySelector("[id^='upload-progress-']")
      })()
      """,
      "a picked file never finished uploading, so the pick started nothing (UPLOAD-1)"
    )

    conn =
      conn
      |> type("#chat-input", "here is a file")
      |> press("#chat-input", "Enter")
      |> assert_has("#transcript", text: "here is a file")

    # UPLOAD-12: the chip under it links to that file's Files page; UPLOAD-10,
    # UPLOAD-6: the file is in the chat's workspace, as the browser handed it
    # over — which is what the path the message names points at.
    assert_has(conn, "#transcript a[href*='/files?']", text: name)
    assert File.read!(Path.join([root, "uploads", name])) == "hello from a real browser"
  end

  # The page is live: the socket has joined, so LiveView has marked the root
  # `.phx-connected` — from then on the file input has its hook and a change
  # reaches the view.
  defp connected(conn) do
    wait_until(
      conn,
      "document.querySelector('.phx-connected')",
      "the LiveView never connected",
      8_000
    )
  end

  # A promise the page resolves: the expression is evaluated until it is truthy
  # or the deadline passes, so a test never races the socket or an upload.
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
