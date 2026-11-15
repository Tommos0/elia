defmodule EliaWeb.ChatUploadTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store, Workspace}
  alias Elia.LLM.Message

  # UPLOAD-1 to UPLOAD-5, UPLOAD-9, UPLOAD-12, UPLOAD-13: the composer's attach
  # control — what it takes, what it says about what it will not, and the message
  # the files are sent with.

  setup do
    start_supervised!(FakeLLM)
    # A chat with no project works in the runtime root (PROJ-12), which is where
    # its uploads land (UPLOAD-6) — the directory this test owns and clears.
    root = Workspace.root()
    File.rm_rf!(Path.join(root, "uploads"))
    on_exit(fn -> File.rm_rf!(Path.join(root, "uploads")) end)
    %{root: root}
  end

  defp attach(view, entries), do: file_input(view, "#upload-form", :uploads, entries)

  defp entry(name, content \\ "hello"),
    do: %{name: name, content: content, size: byte_size(content)}

  defp new_chat do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [], project: "harness")
    id
  end

  defp reply(text \\ "Sure.") do
    FakeLLM.push(fn _request, _on_event ->
      {:ok,
       %{
         message: FakeLLM.assistant([Message.text(text)]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)
  end

  # Waits for the turn to finish — its reply saved, and the composer back, which
  # it only is once the chat is idle again (UPLOAD-4) — so what the chat holds
  # and what the view shows have both settled before a test reads them.
  defp await_turn(id, view, tries \\ 100) do
    if Enum.any?(Store.load(id), &(&1.role == :assistant)) and has_element?(view, "#upload-form") do
      :ok
    else
      if tries == 0 do
        flunk("the turn did not finish")
      else
        Process.sleep(50)
        await_turn(id, view, tries - 1)
      end
    end
  end

  defp files_page(id, path), do: "/files?" <> URI.encode_query([{"chat", id}, {"path", path}])

  defp ref_of(upload, name) do
    Enum.find_value(upload.entries, fn
      %{"name" => ^name, "ref" => ref} -> ref
      %{} -> nil
    end)
  end

  ## The attach control (UPLOAD-1, UPLOAD-3)

  # UPLOAD-1, UPLOAD-3
  test "the composer has an attach control, and a picked file shows as a chip", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#upload-button", "Attach files")
    assert has_element?(view, "#upload-button input[type='file'][name='uploads']")
    # UPLOAD-1: the picker reports to its own form, and neither form is inside
    # the other — one form cannot hold another.
    assert has_element?(view, "#upload-form[phx-change='validate_uploads']")
    assert has_element?(view, "#upload-form input[type='file'][name='uploads']")
    assert has_element?(view, "#chat-form[phx-submit='send'] #chat-input")
    refute has_element?(view, "#upload-form #chat-form")
    refute has_element?(view, "#upload-list")

    upload = attach(view, [entry("report.txt", String.duplicate("x", 100))])
    # UPLOAD-1: how far the file is, while it is on its way.
    render_upload(upload, "report.txt", 50)
    assert has_element?(view, "#upload-list", "report.txt")
    assert has_element?(view, "#upload-list", "100 B")
    assert has_element?(view, "[id^='upload-progress-']", "50%")

    render_upload(upload, "report.txt", 50)
    # UPLOAD-3: the chip keeps the name and the size once it is there.
    assert has_element?(view, "#upload-list", "report.txt")
    refute has_element?(view, "[id^='upload-progress-']")

    # UPLOAD-3: its remove button drops it from the message.
    assert has_element?(view, "#upload-list button[phx-click='remove_upload']")
    view |> element("#upload-list button[phx-click='remove_upload']") |> render_click()
    refute has_element?(view, "#upload-list", "report.txt")
  end

  # UPLOAD-2, UPLOAD-3
  test "a message takes at most 10 files", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    upload = attach(view, for(n <- 1..10, do: entry("file-#{n}.txt")))
    for n <- 1..10, do: render_upload(upload, "file-#{n}.txt", 100)
    refute has_element?(view, "#upload-error")

    # The eleventh is a file the message does not carry: the composer says which
    # bound it broke, and the ten within it stay attached.
    upload_11 = attach(view, [entry("file-11.txt")])
    preflight_upload(upload_11)

    assert has_element?(view, "#upload-error", "a message takes at most 10 files")
    assert has_element?(view, "#upload-list", "file-1.txt")
    assert has_element?(view, "#upload-list", "file-10.txt")
    # Its chip is there too, with the button that drops it.
    ref = ref_of(upload_11, "file-11.txt")
    assert has_element?(view, "#upload-#{ref}", "file-11.txt")
    assert has_element?(view, "#upload-remove-#{ref}")

    # UPLOAD-2: and the message is not sent while it is attached.
    view |> form("#chat-form", %{"chat" => %{"text" => "eleven files"}}) |> render_submit()
    assert Store.load(id) == []
    assert has_element?(view, "#upload-error", "over a bound")

    # Dropping it lets the message go with the ten that are within the bound.
    reply()
    view |> element("#upload-remove-#{ref}") |> render_click()
    refute has_element?(view, "#upload-#{ref}")

    view |> form("#chat-form", %{"chat" => %{"text" => "ten files"}}) |> render_submit()
    await_turn(id, view)

    assert [%Message{role: :user} = message | _] = Store.load(id)
    assert length(Message.attachments(message)) == 10
  end

  # UPLOAD-2, UPLOAD-3
  test "a file may be at most 25 MB", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # The one within the bound first, so it is uploaded and done.
    upload = attach(view, [entry("small.txt")])
    render_upload(upload, "small.txt", 100)

    big = entry("big.bin", String.duplicate("x", 26 * 1024 * 1024))
    upload = attach(view, [big])
    preflight_upload(upload)

    # UPLOAD-2: the one over the bound is a file the message does not carry —
    # its own chip says which bound it broke — and the one within it stays.
    big_ref = ref_of(upload, "big.bin")
    assert has_element?(view, "#upload-#{big_ref}", "big.bin")
    assert has_element?(view, "#upload-#{big_ref}", "a file may be at most 25 MB")
    assert has_element?(view, "#upload-list", "small.txt")
    refute has_element?(view, "#upload-progress-#{big_ref}")

    # And the message is not sent while it is attached.
    view |> form("#chat-form", %{"chat" => %{"text" => "one of each"}}) |> render_submit()
    assert Store.load(id) == []
    assert has_element?(view, "#upload-error", "over a bound")

    # Dropping it lets the message go with the file that is within the bound,
    # which is written into the chat's workspace (UPLOAD-6).
    reply()
    view |> element("#upload-remove-#{big_ref}") |> render_click()
    refute has_element?(view, "#upload-error")

    view |> form("#chat-form", %{"chat" => %{"text" => "just the small one"}}) |> render_submit()
    await_turn(id, view)

    assert [%Message{role: :user} = message | _] = Store.load(id)
    assert Message.attachments(message) == ["uploads/small.txt"]
  end

  # UPLOAD-4
  test "no file can be picked or removed while a turn runs", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    upload = attach(view, [entry("report.txt")])
    render_upload(upload, "report.txt", 100)
    assert has_element?(view, "#upload-list button[phx-click='remove_upload']")

    Agent.subscribe(id)

    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(300)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("Done.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:status, :running}}, 2_000

    # UPLOAD-4: the control is not there, so nothing can be picked — and no chip
    # can be dropped either; the file stays for the message it was attached to.
    refute has_element?(view, "#upload-button")
    refute has_element?(view, "#upload-form")
    refute has_element?(view, "#upload-list button[phx-click='remove_upload']")
    assert has_element?(view, "#upload-list", "report.txt")

    await_turn(id, view)
    assert has_element?(view, "#upload-button")
  end

  ## Where the files go (UPLOAD-6 to UPLOAD-9)

  # UPLOAD-6
  test "a sent message's files are written into the chat's workspace", %{conn: conn, root: root} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    reply()
    upload = attach(view, [entry("report.txt", "the report")])
    render_upload(upload, "report.txt", 100)

    view |> form("#chat-form", %{"chat" => %{"text" => "here it is"}}) |> render_submit()
    await_turn(id, view)

    # UPLOAD-6: under `uploads/` at the chat's own workspace root, which the
    # agent reaches with its own tools (FILE).
    assert File.read!(Path.join([root, "uploads", "report.txt"])) == "the report"
  end

  # UPLOAD-8
  test "two uploads of one name both survive", %{conn: conn, root: root} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    reply()
    upload = attach(view, [entry("shot.png", "one")])
    render_upload(upload, "shot.png", 100)
    view |> form("#chat-form", %{"chat" => %{"text" => "first"}}) |> render_submit()
    await_turn(id, view)

    # The same name again, in a later message: the first is still there.
    reply()
    upload = attach(view, [entry("shot.png", "two")])
    render_upload(upload, "shot.png", 100)
    view |> form("#chat-form", %{"chat" => %{"text" => "second"}}) |> render_submit()
    await_turn(id, view)

    assert File.read!(Path.join([root, "uploads", "shot.png"])) == "one"
    assert File.read!(Path.join([root, "uploads", "shot-1.png"])) == "two"
  end

  # UPLOAD-9
  test "a file that cannot be written is reported and the message is not sent", %{
    conn: conn,
    root: root
  } do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # `uploads` is a file, so the directory cannot be created under the root.
    File.write!(Path.join(root, "uploads"), "not a directory")

    upload = attach(view, [entry("report.txt")])
    render_upload(upload, "report.txt", 100)

    view |> form("#chat-form", %{"chat" => %{"text" => "here it is"}}) |> render_submit()

    # UPLOAD-9: the composer says the workspace cannot take the files and
    # nothing was sent — and the file stays attached, so the user can send it
    # once the problem is gone.
    assert has_element?(view, "#upload-error", "Could not save the files")
    assert Store.load(id) == []
    assert has_element?(view, "#upload-list", "report.txt")
  end

  # UPLOAD-15
  test "a message is not sent while a file it carries is still on its way", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    upload = attach(view, [entry("report.txt", String.duplicate("x", 100))])
    # Halfway: the file is still uploading.
    render_upload(upload, "report.txt", 50)

    view |> form("#chat-form", %{"chat" => %{"text" => "here it is"}}) |> render_submit()

    assert has_element?(view, "#upload-error", "Still uploading")
    assert Store.load(id) == []

    # Once it is in, the same message goes.
    render_upload(upload, "report.txt", 50)
    reply()
    view |> form("#chat-form", %{"chat" => %{"text" => "here it is"}}) |> render_submit()
    await_turn(id, view)

    assert Enum.any?(Store.load(id), &(&1.role == :user))
  end

  ## The message and the transcript (UPLOAD-5, UPLOAD-10 to UPLOAD-13)

  # UPLOAD-5, UPLOAD-10, UPLOAD-11
  test "a message of files and no text is sent, and names their paths", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    reply()
    upload = attach(view, [entry("report.txt")])
    render_upload(upload, "report.txt", 100)

    # No text at all (UPLOAD-5, UI-22).
    view |> form("#chat-form", %{"chat" => %{"text" => ""}}) |> render_submit()
    await_turn(id, view)

    # UPLOAD-10: the message says what the user wrote — nothing — and then the
    # one line naming the paths, which is where the agent reads them.
    assert [%Message{role: :user} = message | _] = Store.load(id)
    assert Message.user_text(message) == ""
    assert Message.text_content(message) == "[Uploaded files: uploads/report.txt]"
    # UPLOAD-11: and the paths are in its meta.
    assert Message.attachments(message) == ["uploads/report.txt"]
  end

  # UPLOAD-5
  test "a message of neither text nor files is not sent", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    view |> form("#chat-form", %{"chat" => %{"text" => "   "}}) |> render_submit()

    assert Store.load(id) == []
    refute has_element?(view, "#upload-error")
  end

  # UPLOAD-12
  test "the transcript shows the user's text with a chip per file", %{conn: conn} do
    id = new_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    reply()
    upload = attach(view, [entry("report.txt"), entry("shot.png")])
    render_upload(upload, "report.txt", 100)
    render_upload(upload, "shot.png", 100)

    view |> form("#chat-form", %{"chat" => %{"text" => "have a look"}}) |> render_submit()
    await_turn(id, view)

    # UPLOAD-12: the user's own text, without the harness's line of paths.
    assert has_element?(view, "#transcript", "have a look")
    refute has_element?(view, "#transcript", "[Uploaded files:")

    # One chip per file, each a link to that file's Files page in this chat's
    # own workspace (FLINK-5) — and the file is there, so that page shows it.
    assert has_element?(
             view,
             "a[href='#{files_page(id, "uploads/report.txt")}']",
             "uploads/report.txt"
           )

    assert has_element?(
             view,
             "a[href='#{files_page(id, "uploads/shot.png")}']",
             "uploads/shot.png"
           )
  end

  # UPLOAD-12: a saved chat shows the same chips when it is opened again, which
  # is what the paths in the message's meta are for (UPLOAD-11).
  test "the chips come back with a saved chat", %{conn: conn, root: root} do
    id = new_chat()
    :ok = Store.save(id, [Message.user("have a look", ["uploads/report.txt"])])

    # The file the message names is in the chat's workspace, as it is once the
    # message has been sent (UPLOAD-6).
    File.mkdir_p!(Path.join(root, "uploads"))
    File.write!(Path.join([root, "uploads", "report.txt"]), "the report")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(
             view,
             "a[href='#{files_page(id, "uploads/report.txt")}']",
             "uploads/report.txt"
           )

    refute has_element?(view, "#transcript", "[Uploaded files:")
  end

  # UPLOAD-13, UI-90
  test "the compact view keeps a message that carries files and no text", %{
    conn: conn,
    root: root
  } do
    id = new_chat()
    :ok = Store.save(id, [Message.user("", ["uploads/report.txt"])])

    File.mkdir_p!(Path.join(root, "uploads"))
    File.write!(Path.join([root, "uploads", "report.txt"]), "the report")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    render_hook(view, "set_compact_view", %{"on" => true})

    # UI-90 would leave a message with no text of its own out; its chips are
    # something to show (UPLOAD-13).
    assert has_element?(
             view,
             "a[href='#{files_page(id, "uploads/report.txt")}']",
             "uploads/report.txt"
           )
  end
end
