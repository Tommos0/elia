defmodule EliaWeb.ChatLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Projects, Workspace}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # UI-77: `/chats` is the chat list's entry point — where the header's Chats
  # link of the pages without a chat list leads (UI-32) and where deleting the
  # open chat lands (UI-65) — so it resumes the chat the user left off in
  # instead of leaving another empty one behind on every visit. `/` is the
  # dashboard instead (DASH-1), which opens no chat at all.
  test "/chats resumes the most recent chat, and looking at it saves nothing", %{conn: conn} do
    with_empty_store(fn ->
      older = saved_chat()
      # A sub-task chat started after it: not where the user left off (UI-77).
      task = saved_task_chat(older)
      newest = saved_chat()
      listed = Enum.map(Elia.Store.list(1000), & &1.id)

      assert {:error, {:live_redirect, %{to: "/c/" <> ^newest}}} = live(conn, ~p"/chats")
      # UI-77, STORE-22: resuming writes nothing, so no empty chat piles up.
      assert Enum.map(Elia.Store.list(1000), & &1.id) == listed
      assert task in listed

      # With the newest chat gone, the next one is resumed rather than the
      # task chat (UI-77, STORE-29).
      :ok = Elia.Store.delete(newest)
      assert {:error, {:live_redirect, %{to: "/c/" <> ^older}}} = live(conn, ~p"/chats")
    end)
  end

  # UI-77, STORE-22: with nothing saved there is no chat to resume, so `/chats`
  # starts one in the default project (PROJ-8) and saves it at once.
  test "/chats starts a chat when there is nothing to resume", %{conn: conn} do
    with_empty_store(fn ->
      # No stored default project, so it is Elia's own (PROJ-8).
      Elia.Settings.delete(:default_project)

      assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/chats")

      assert [%{id: ^id, title: "New chat", project_id: "harness"}] = Elia.Store.list(30)
      assert Elia.Store.load(id) == []
    end)
  end

  # STORE-22, UI-63: a chat started from the UI is saved as it opens, so the
  # sidebar lists it, as the open chat, before the user has sent anything.
  test "a started chat is saved and in the sidebar at once", %{conn: conn} do
    # Its own store: with a chat saved there, `/chats` would resume that one
    # (UI-77).
    with_empty_store(fn ->
      assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/chats")

      # STORE-22: on disk with no messages, its project and its start time.
      assert %{id: ^id, title: "New chat", description: "New chat", project_id: "harness"} =
               Enum.find(Elia.Store.list(30), &(&1.id == id))

      assert Elia.Store.load(id) == []

      # UI-63: and the sidebar of the chat it opened shows it right away.
      {:ok, view, _html} = live(conn, ~p"/c/#{id}")

      assert has_element?(view, "#chat-link-#{id}", "New chat")
      assert has_element?(view, "#chat-link-#{id}.bg-base-300")
      assert has_element?(view, "#chat-time-#{id}", "just now")
    end)
  end

  # UI-6: a turn's start refreshes the sidebar and the page title, so the chat
  # shows its first message without waiting for the turn to end.
  test "the sidebar and page title follow a turn's start", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, [], project: "harness")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert has_element?(view, "#chat-link-#{id}", "New chat")

    Agent.subscribe(id)

    # A turn that is still running while we look at the sidebar.
    FakeLLM.push(fn _request, on_event ->
      Process.sleep(500)
      on_event.({:text_delta, "Sure."})

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("Sure.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    :ok = Agent.send_message(id, "first message")

    assert_receive {:agent, ^id, {:status, :running}}, 2_000
    assert has_element?(view, "#chat-link-#{id}", "first message")
    # The page title follows at once too (the layout's "Elia - " prefix is
    # applied in the browser, so a title updated mid-session reads bare here).
    assert page_title(view) == "first message"

    assert_receive {:agent, ^id, {:status, :idle}}, 5_000
    assert has_element?(view, "#chat-link-#{id}", "first message")
  end

  # UI-31, PROJ-26: the "New chat" button sits above the chat list in the
  # sidebar and starts a chat in the open chat's project.
  test "sidebar shows a New chat button above the chat list", %{conn: conn} do
    id = Agent.new_id()

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#new-chat[href='/p/harness/new']", "New chat")
    # The button lives in the sidebar, before the chat list.
    aside = Regex.run(~r/<aside.*?<\/aside>/s, html) |> hd()
    assert aside =~ "id=\"new-chat\""
    assert String.split(aside, "id=\"chat-list\"") |> hd() =~ "id=\"new-chat\""
    # And appears exactly once overall (the header no longer carries it).
    assert length(Regex.scan(~r/id="new-chat"/, html)) == 1
  end

  # UI-35: the sidebar has an accessible drag handle for resizing.
  test "sidebar has a resize handle driven by a hook", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#sidebar #sidebar-resize")
    assert has_element?(view, "#sidebar-resize[role='separator'][aria-orientation='vertical']")
    assert has_element?(view, "#sidebar-resize[tabindex='0']")
    assert has_element?(view, "#sidebar-resize[phx-hook$='SidebarResize']")

    # The width comes from a CSS variable the hook sets, defaulting to 16rem.
    assert html =~ "var(--sidebar-width,16rem)"
  end

  # UI-32, UI-36: on small screens the chat list opens as a drawer from the
  # header's Chats button, which shows the list instead of leaving the chat.
  test "the header's Chats button opens and closes the drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "header #chats-toggle[aria-expanded='false']")
    assert has_element?(view, "header #chats-toggle[aria-controls='sidebar'][title='Chats']")
    # UI-32: it is not a link, so it never opens another chat.
    refute has_element?(view, "header #chats-link")
    refute has_element?(view, "#chats-backdrop")
    assert has_element?(view, "#sidebar.hidden")

    view |> element("#chats-toggle") |> render_click()
    assert has_element?(view, "#chats-toggle[aria-expanded='true']")
    assert has_element?(view, "#chats-backdrop")
    refute has_element?(view, "#sidebar.hidden")
    assert has_element?(view, "#sidebar #new-chat")
    assert has_element?(view, "#sidebar #chat-list")

    view |> element("#chats-toggle") |> render_click()
    refute has_element?(view, "#chats-backdrop")
    assert has_element?(view, "#sidebar.hidden")
  end

  # UI-36: the backdrop and Escape close the drawer.
  test "backdrop and Escape close the chats drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    view |> element("#chats-toggle") |> render_click()
    view |> element("#chats-backdrop") |> render_click()
    refute has_element?(view, "#chats-backdrop")

    view |> element("#chats-toggle") |> render_click()
    assert has_element?(view, "#sidebar[phx-key='Escape'][phx-window-keydown]")
    render_keydown(view, "close_chats", %{"key" => "Escape"})
    refute has_element?(view, "#chats-backdrop")
  end

  # UI-32, UI-36: the toggle and the backdrop only exist where the drawer does,
  # so the chat page's header has no Chats control from `lg` up — the list is
  # always visible there, and nothing in the header leaves the open chat.
  test "chats toggle and backdrop are hidden on large screens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "header #chats-toggle.lg\\:hidden")
    view |> element("#chats-toggle") |> render_click()
    assert has_element?(view, "#chats-backdrop.lg\\:hidden")
  end

  # UI-33: hovering a sidebar chat shows its full description.
  test "sidebar chat links carry the full description as a tooltip", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    text = String.duplicate("word ", 40) <> "END"
    :ok = Elia.Store.save(id, [Message.user(text)])

    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#chat-link-#{id}[title='#{text}']")
  end

  # PREVIEW-8, IMG-6: a preview's screenshot reaches the chat as a picture,
  # shown at the transcript's width, with the viewer it opens in — the server's
  # own markup, hidden until the hook fills it in (`specs/image-viewer.md`).
  test "an image in a message renders as a picture", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    :ok =
      Elia.Store.save(id, [
        Message.user("show me"),
        %Message{
          role: :assistant,
          content: [Message.text("Here it is: ![preview](/preview/#{id}/0-root.png)")]
        }
      ])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    document = view |> render() |> LazyHTML.from_fragment()

    assert [image] = document |> LazyHTML.query(".markdown img") |> Enum.to_list()
    assert LazyHTML.attribute(image, "src") == ["/preview/#{id}/0-root.png"]

    # IMG-6: the hook that shows the viewer is on the viewer, outside the
    # transcript's stream.
    assert [] == LazyHTML.query(document, "#transcript") |> LazyHTML.attribute("phx-hook")

    assert [lightbox] = document |> LazyHTML.query("#image-lightbox") |> Enum.to_list()
    assert [hook] = LazyHTML.attribute(lightbox, "phx-hook")
    assert hook =~ "ZoomImage"

    # IMG-7: the viewer is hidden by its own markup, not by a rule in
    # assets/css/app.css — a page can render this markup while its stylesheet is
    # the one from before the change (HOT-8) — its backdrop is its own markup's
    # too, and LiveView never patches it.
    assert [style] = LazyHTML.attribute(lightbox, "style")
    assert style =~ "display: none"
    assert style =~ "background-color: rgb(0 0 0 / 0.85)"
    assert ["ignore"] = LazyHTML.attribute(lightbox, "phx-update")

    # IMG-3: the close button is the viewer's own, so closing it never depends
    # on the browser's or the phone's back control.
    assert [close] = document |> LazyHTML.query("#image-lightbox-close") |> Enum.to_list()
    assert LazyHTML.attribute(close, "aria-label") == ["Close image"]

    # IMG-2: the picture itself, empty until the hook puts one in.
    assert [viewer] = document |> LazyHTML.query("#image-lightbox-image") |> Enum.to_list()
    assert LazyHTML.attribute(viewer, "src") == []
  end

  # UI-34: each sidebar chat shows its start time, and the text keeps up with the clock.
  test "sidebar chats show a relative start time that refreshes", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, [Message.user("hi")])
    chat = Enum.find(Elia.Store.list(30), &(&1.id == id))

    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    time = "time#chat-time-#{id}"
    assert has_element?(view, "#{time}[datetime='#{DateTime.to_iso8601(chat.created_at)}']")
    title = Calendar.strftime(chat.created_at, "%Y-%m-%d %H:%M:%S UTC")
    assert has_element?(view, "#{time}[title='#{title}']")
    assert has_element?(view, time, "just now")

    # Age the listed chat by an hour without rendering, then let the tick render it.
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.chats, fn chats ->
        Enum.map(chats, &%{&1 | created_at: DateTime.add(&1.created_at, -3600)})
      end)
    end)

    send(view.pid, :tick_now)
    assert has_element?(view, time, "1 hour ago")
  end

  # UI-64: every chat row — task chats too (UI-45) — has a delete button beside
  # its link, as a sibling of it rather than nested inside it.
  test "each sidebar chat has a delete button beside its link", %{conn: conn} do
    parent = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> Enum.each([parent, child], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(parent, [Message.user("delegate this")])

    :ok =
      Elia.Store.save(child, [Message.user("preamble")],
        task: %{parent_id: parent, parent_call_id: "s1", title: "Task one", status: "done"}
      )

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    for id <- [parent, child] do
      assert has_element?(
               view,
               "#delete-chat-#{id}[aria-label='Delete chat'][title='Delete chat']"
             )

      assert has_element?(view, "#delete-chat-#{id} .hero-trash")
      # A sibling of the link, and never nested in it (or in another button).
      assert has_element?(view, "#chat-row-#{id} > #chat-link-#{id}")
      assert has_element?(view, "#chat-row-#{id} > #delete-chat-#{id}")
      refute has_element?(view, "#chat-link-#{id} #delete-chat-#{id}")
      refute has_element?(view, "#chat-link-#{id} button")
      refute has_element?(view, "#delete-chat-#{id} a")
    end

    # The link keeps the status indicator and the start time (UI-34, UI-59).
    assert has_element?(view, "#chat-link-#{parent} #chat-status-#{parent}")
    assert has_element?(view, "#chat-link-#{parent} #chat-time-#{parent}")
    assert has_element?(view, "#chat-link-#{parent}.bg-base-300")
    # UI-64: the confirmation names the chat it deletes.
    assert has_element?(view, "#delete-chat-#{parent}[data-confirm*='delegate this']")
    assert has_element?(view, "#delete-chat-#{child}[data-confirm*='Task one']")
  end

  # UI-64, UI-65: confirming removes the chat, flashes, and leaves the open chat
  # where it is.
  test "deleting another chat removes its row and flashes", %{conn: conn} do
    open = Agent.new_id()
    other = Agent.new_id()
    on_exit(fn -> Enum.each([open, other], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(open, [Message.user("the open chat")])
    :ok = Elia.Store.save(other, [Message.user("the other chat")])

    {:ok, view, _html} = live(conn, ~p"/c/#{open}")
    assert has_element?(view, "#chat-link-#{other}", "the other chat")

    view |> element("#delete-chat-#{other}") |> render_click()

    refute has_element?(view, "#chat-link-#{other}")
    refute has_element?(view, "#delete-chat-#{other}")
    assert render(view) =~ "Chat deleted."
    assert Elia.Store.load(other) == []
    # The open chat stays open and highlighted (UI-4).
    assert has_element?(view, "#chat-link-#{open}.bg-base-300")
  end

  # UI-65: deleting the chat that is open leaves for `/chats`, which resumes the
  # next chat or starts a fresh one (UI-77).
  test "deleting the open chat navigates to the chat list entry point", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, [Message.user("delete me")])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    view |> element("#delete-chat-#{id}") |> render_click()
    assert_redirect(view, "/chats")

    assert Elia.Store.load(id) == []
  end

  # UI-65: a chat whose turn is running can be deleted from any chat's sidebar:
  # its turn is stopped first (SESS-8, SESS-22, SESS-29).
  test "deleting a running chat from another chat's sidebar stops it", %{conn: conn} do
    open = Agent.new_id()
    busy = Agent.new_id()
    on_exit(fn -> Enum.each([open, busy], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(open, [Message.user("the open chat")])

    {:ok, pid} = Agent.ensure_started(busy)
    Agent.subscribe(busy)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(5000)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("late")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    :ok = Agent.send_message(busy, "go")
    assert_receive {:agent, ^busy, {:status, :running}}, 2_000

    # The chat is working as the sidebar renders (UI-59).
    {:ok, view, _html} = live(conn, ~p"/c/#{open}")
    assert has_element?(view, "#chat-status-#{busy}[data-status='working']")

    view |> element("#delete-chat-#{busy}") |> render_click()

    refute has_element?(view, "#chat-link-#{busy}")
    assert Registry.lookup(Elia.Agent.Registry, busy) == []
    assert Elia.Store.load(busy) == []
  end

  # UI-66: deleting a parent leaves its task chats saved and listed on their own
  # at the top level (UI-45).
  test "deleting a parent leaves its task chat at the top level", %{conn: conn} do
    observer = Agent.new_id()
    parent = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> Enum.each([observer, parent, child], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(observer, [Message.user("just watching")])
    :ok = Elia.Store.save(parent, [Message.user("delegate this")])

    :ok =
      Elia.Store.save(child, [Message.user("preamble")],
        task: %{parent_id: parent, parent_call_id: "s1", title: "Nested task", status: "done"}
      )

    {:ok, view, _html} = live(conn, ~p"/c/#{observer}")
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{child}")

    view |> element("#delete-chat-#{parent}") |> render_click()

    refute has_element?(view, "#chat-link-#{parent}")
    refute has_element?(view, "#chat-children-#{parent}")
    assert has_element?(view, "#chat-list #chat-link-#{child}", "Nested task")
    assert has_element?(view, "#chat-status-#{child}[data-status='done']")
    # The task chat is left saved, with its parent metadata (STORE-17).
    assert [%Message{}] = Elia.Store.load(child)
    assert %{parent_id: ^parent} = Elia.Store.load_task(child)
  end

  # UI-37: header labels collapse to icons on narrow screens.
  test "header buttons hide their labels below the sm breakpoint", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    # UI-32: on the chat page the first control is the chat list's toggle.
    for id <- ~w(chats-toggle projects-link files-link sessions-link system-link settings-link) do
      assert has_element?(view, "header ##{id}[title]")
      assert has_element?(view, "header ##{id} span.sr-only.sm\\:not-sr-only")
    end
  end

  # UI-32: the header's Chats control comes before the other pages' links. On
  # the chat page it is the chat list's drawer toggle (UI-36), which shows the
  # list and never navigates; a page without a chat list — the dashboard
  # included (DASH-2) — keeps the link to `/chats`, the chat list's entry point,
  # which resumes the most recent chat (UI-77).
  test "the header's Chats control shows the chat list, or goes to /chats", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "header #chats-toggle")
    assert before?(html, "id=\"chats-toggle\"", "id=\"sessions-link\"")
    assert before?(html, "id=\"chats-toggle\"", "id=\"projects-link\"")

    # Clicking it opens the drawer. The view is still mounted afterwards, so
    # the click did not navigate anywhere.
    view |> element("#chats-toggle") |> render_click()
    assert has_element?(view, "#chats-backdrop")
    assert has_element?(view, "#chat-form")

    {:ok, files, _html} = live(conn, ~p"/files")
    assert has_element?(files, "header #chats-link[href='/chats']", "Chats")
    refute has_element?(files, "header #chats-toggle")
    files |> element("#chats-link") |> render_click()
    assert_redirect(files, "/chats")
  end

  test "chatting with an approval round-trip", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo from-shell"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

    # APPR-14: a new chat auto-approves every tool, so this chat is started with
    # an empty set — the command below has to wait for approval.
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    {:ok, view, html} = live(conn, ~p"/c/#{id}")
    assert html =~ "What should we work on?"
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "say something"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000
    assert render(view) =~ "echo from-shell"
    assert has_element?(view, "#approve-c1")

    view |> element("#approve-c1") |> render_click()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    html = render(view)
    assert html =~ "say something"
    assert html =~ "from-shell"
    assert html =~ "All done."
    refute has_element?(view, "#approve-c1")
  end

  # CTX-1, CTX-2: the indicator shows the estimate, the window and the percent.
  test "context indicator shows the estimate and the window on an empty chat", %{conn: conn} do
    id = Agent.new_id()

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    assert html =~ "Context"
    assert has_element?(view, "#context-indicator")
    assert has_element?(view, "#context-size")
    # Anthropic's built-in fallback window (CTX-7) is 200K.
    assert render(view) =~ "/ 200K"
    refute has_element?(view, "#context-breakdown")
  end

  # CTX-4: clicking the indicator toggles the breakdown.
  test "clicking the context indicator toggles the breakdown", %{conn: conn} do
    id = Agent.new_id()

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    view |> element("#context-indicator") |> render_click()
    assert has_element?(view, "#context-breakdown")

    html = render(view)
    assert html =~ "System prompt"
    assert html =~ "Agent instructions"
    assert html =~ "Skill:"
    assert html =~ "Tool definitions"
    assert html =~ "Messages"
    assert html =~ "Estimated total"
    assert has_element?(view, "#context-total")

    view |> element("#context-indicator") |> render_click()
    refute has_element?(view, "#context-breakdown")
  end

  # CTX-5: file and shell tool traffic lands in its own breakdown buckets.
  test "context breakdown buckets files and shell from a saved chat", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    messages = [
      Message.user("read my notes"),
      %Message{
        role: :assistant,
        content: [
          %{type: :tool_call, id: "r1", name: "read_file", input: %{"path" => "notes.txt"}},
          %{type: :tool_call, id: "s1", name: "shell", input: %{"command" => "ls"}}
        ]
      },
      %Message{
        role: :tool,
        content: [
          Message.tool_result("r1", "hello from notes"),
          Message.tool_result("s1", "lib\nREADME.md\n")
        ]
      },
      %Message{role: :assistant, content: [Message.text("Found it.")]}
    ]

    Elia.Store.save(id, messages)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    view |> element("#context-indicator") |> render_click()

    html = render(view)
    assert html =~ "Files"
    assert html =~ "Shell"
    assert html =~ "User"
    assert html =~ "Assistant"
  end

  # UI-25: saved and streaming assistant text both render as Markdown.
  test "assistant text renders as Markdown", %{conn: conn} do
    id = Agent.new_id()
    test_pid = self()

    FakeLLM.push(fn _request, on_event ->
      on_event.({:text_delta, "## Draft heading"})
      send(test_pid, {:streamed, self()})
      receive do: (:finish -> :ok)
      msg = FakeLLM.assistant([Message.text("## Saved heading\n\n- **item**")])
      {:ok, %{message: msg, stop_reason: :end_turn, model: "fake", usage: %{}}}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "format it"}) |> render_submit()
    assert_receive {:streamed, llm}, 5000
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#draft .markdown h2", "Draft heading")

    send(llm, :finish)
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    assert has_element?(view, "#transcript .markdown h2", "Saved heading")
    assert has_element?(view, "#transcript .markdown li strong", "item")
  end

  # FLINK-1, FLINK-4: a file the agent mentions in a reply, and the path on a
  # file tool's card, link to that file's own Files page — that of the workspace
  # the chat works in (FLINK-5).
  test "a mentioned file links to the Files page", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    file = "chat_live_mention_fixture.txt"
    File.write!(Path.join(Workspace.root(), file), "hi\n")
    on_exit(fn -> File.rm!(Path.join(Workspace.root(), file)) end)

    Elia.Store.save(id, [
      Message.user("where is it?"),
      %Message{
        role: :assistant,
        content: [
          Message.text("It is in `#{file}`, at line 3. Not in `nowhere_file.txt`."),
          %{type: :tool_call, id: "call-flink", name: "read_file", input: %{"path" => file}}
        ]
      },
      %Message{role: :tool, content: [Message.tool_result("call-flink", "hi\n")]}
    ])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    href = "/files?chat=#{id}&path=#{file}"

    # FLINK-1: the mention links, and still reads as code (FLINK-7).
    assert has_element?(view, "#transcript .markdown a[href='#{href}'] code", file)
    # FLINK-4: so does the card's path.
    assert has_element?(view, "#tool-path-call-flink[href='#{href}']", file)
    # FLINK-5: a path the workspace doesn't have is no link at all.
    refute has_element?(view, "#transcript .markdown a code", "nowhere_file.txt")
  end

  # UI-29: saved reasoning is collapsed behind a header with its word count.
  test "saved reasoning is collapsed by default", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    Elia.Store.save(id, [
      Message.user("think first"),
      %Message{
        role: :assistant,
        content: [%{type: :reasoning, text: "Let me weigh this"}, Message.text("Done.")]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#transcript details:not([open]) summary", "Reasoning")
    assert has_element?(view, "#transcript details summary", "4 words")
    assert has_element?(view, "#transcript details .reasoning-text", "Let me weigh this")
  end

  # UI-29, UI-30: streaming reasoning is collapsed too and marked as in progress.
  test "streaming reasoning is collapsed and marked in progress", %{conn: conn} do
    id = Agent.new_id()
    test_pid = self()

    FakeLLM.push(fn _request, on_event ->
      on_event.({:reasoning_delta, "Pondering"})
      send(test_pid, {:streamed, self()})
      receive do: (:finish -> :ok)
      msg = FakeLLM.assistant([%{type: :reasoning, text: "Pondering"}, Message.text("Hi.")])
      {:ok, %{message: msg, stop_reason: :end_turn, model: "fake", usage: %{}}}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "think"}) |> render_submit()
    assert_receive {:streamed, llm}, 5000
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#draft-reasoning details:not([open]) summary", "Reasoning…")

    send(llm, :finish)
    assert_receive {:agent, ^id, {:status, :idle}}, 5000
    refute has_element?(view, "#draft-reasoning")
    assert has_element?(view, "#transcript details:not([open]) summary", "1 word")
  end

  # CTX-6: provider-reported input usage (with cache tokens) appears after a
  # turn, and a reset clears it.
  test "provider-reported usage is shown after a turn", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(fn _request, on_event ->
      text = "Counting tokens."
      on_event.({:text_delta, text})
      msg = FakeLLM.assistant([Message.text(text)])
      usage = %{"input_tokens" => 345, "cache_read_input_tokens" => 12_000}
      {:ok, %{message: msg, stop_reason: :end_turn, model: "fake", usage: usage}}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "how big is my context?"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    view |> element("#context-indicator") |> render_click()
    assert view |> element("#context-provider-usage") |> render() =~ "12K"

    send(view.pid, {:agent, id, {:reset, []}})
    refute has_element?(view, "#context-provider-usage")
  end

  # CTX-10: the total follows the provider's figure, including on a remount, and
  # a reset clears the adjustment.
  test "the context total is calibrated by provider usage", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(fn _request, _on_event ->
      msg = FakeLLM.assistant([Message.text("Done.")])

      {:ok,
       %{message: msg, stop_reason: :end_turn, model: "fake", usage: %{"input_tokens" => 90_000}}}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "hello"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    view |> element("#context-indicator") |> render_click()
    assert view |> element("#context-total") |> render() =~ "90K"
    assert view |> element("#context-breakdown") |> render() =~ "Provider adjustment"

    {:ok, remounted, _html} = live(conn, ~p"/c/#{id}")
    remounted |> element("#context-indicator") |> render_click()
    assert remounted |> element("#context-total") |> render() =~ "90K"

    send(view.pid, {:agent, id, {:reset, []}})
    refute view |> element("#context-breakdown") |> render() =~ "Provider adjustment"
  end

  # CTX-10: an estimate above the provider's figure shows a negative adjustment.
  test "a negative provider adjustment is shown with its sign", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(fn _request, _on_event ->
      msg = FakeLLM.assistant([Message.text("Done.")])
      {:ok, %{message: msg, stop_reason: :end_turn, model: "fake", usage: %{"input_tokens" => 1}}}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "hello"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    view |> element("#context-indicator") |> render_click()
    assert view |> element("#context-breakdown") |> render() =~ ~r/>\s*-\d+K?\s*</
  end

  # CTX-2: the percentage and the coloured bar show when the window is known.
  test "context indicator shows the percentage and bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#context-percent")
    assert has_element?(view, "#context-bar.bg-success")
  end

  # CTX-8: the indicator updates as messages arrive, without a re-mount.
  test "context indicator updates live as messages arrive", %{conn: conn} do
    id = Agent.new_id()
    FakeLLM.push(FakeLLM.assistant([Message.text(String.duplicate("word ", 8000))]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)
    before = view |> element("#context-size") |> render()

    view |> form("#chat-form", chat: %{text: "write a lot"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    after_turn = view |> element("#context-size") |> render()
    refute after_turn == before

    {:ok, fresh, _html} = live(conn, ~p"/c/#{id}")
    assert fresh |> element("#context-size") |> render() == after_turn
  end

  # CTX-8: a skills reload refreshes the system-prompt breakdown.
  test "context breakdown follows a skills reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")
    view |> element("#context-indicator") |> render_click()
    assert has_element?(view, "#context-breakdown li", "Skill:")

    send(view.pid, {:skills_reloaded, []})
    refute has_element?(view, "#context-breakdown li", "Skill:")
  end

  # PROJ-25: the header carries a Projects link next to Chats.
  test "the header has a Projects link next to Chats", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "header #projects-link[href='/projects'][title='Projects']")
    assert has_element?(view, "header #projects-link span.sr-only.sm\\:not-sr-only")

    assert before?(html, "id=\"chats-toggle\"", "id=\"projects-link\"")
  end

  # PROJ-24: the sidebar groups chats under a header per project, with a
  # per-project new chat button; a project without chats still has a header.
  test "sidebar groups chats by project", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-group")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create("Grouped", root)
    {:ok, empty} = Projects.create("No chats", root)

    project_chat = Agent.new_id()
    harness_chat = Agent.new_id()

    on_exit(fn ->
      File.rm_rf!(root)
      Elia.Store.delete(project_chat)
      Elia.Store.delete(harness_chat)
      Projects.delete(project.id)
      Projects.delete(empty.id)
    end)

    :ok = Elia.Store.save(project_chat, [Message.user("in project")], project: project.id)
    :ok = Elia.Store.save(harness_chat, [Message.user("in harness")])

    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#project-header-harness", "Elia")
    assert has_element?(view, "#project-header-#{empty.id}", "No chats")
    assert has_element?(view, "#project-header-#{project.id}", "Grouped")
    assert has_element?(view, "#new-chat-#{project.id}[href='/p/#{project.id}/new']")
    assert has_element?(view, "#new-chat-harness[href='/p/harness/new']")

    html = render(view)
    # Each chat sits under its own project's header.
    assert before?(html, "project-header-harness", "chat-link-#{harness_chat}")
    assert before?(html, "chat-link-#{harness_chat}", "project-header-#{project.id}")
    assert before?(html, "project-header-#{project.id}", "chat-link-#{project_chat}")
  end

  # PROJ-26: /p/<id>/new starts a chat in that project and makes it the default.
  test "starting a chat in a project", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-new")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create("New one", root)

    on_exit(fn ->
      File.rm_rf!(root)
      Projects.delete(project.id)
      Elia.Settings.delete(:default_project)
    end)

    assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/p/#{project.id}/new")

    assert Agent.snapshot(id).project.id == project.id
    assert Projects.default().id == project.id
  end

  # PROJ-26: an unknown project id redirects home.
  test "starting a chat with an unknown project id redirects home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/p/nope/new")
  end

  # PROJ-8, PROJ-26, UI-77: with nothing to resume, "/chats" starts a chat in the
  # default project.
  test "a new chat starts in the default project", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-default")
    File.mkdir_p!(root)

    # A store with no chat to resume (UI-77): this is the starting-over path.
    with_empty_store(fn ->
      {:ok, project} = Projects.create("Default one", root)

      on_exit(fn ->
        File.rm_rf!(root)
        Projects.delete(project.id)
        Elia.Settings.delete(:default_project)
      end)

      Elia.Projects.set_default(project.id)

      assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/chats")
      assert Agent.snapshot(id).project.id == project.id
    end)
  end

  # PROJ-26: the sidebar's "New chat" button (UI-31) starts a chat in the open
  # chat's project, not in the default project, and that destination still
  # starts a project chat (PROJ-11).
  test "the New chat button starts a chat in the open chat's project", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-open-project")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create("Open one", root)
    open = Agent.new_id()

    on_exit(fn ->
      File.rm_rf!(root)
      Elia.Store.delete(open)
      Projects.delete(project.id)
      Elia.Settings.delete(:default_project)
    end)

    :ok = Elia.Store.save(open, [Message.user("in project")], project: project.id)

    {:ok, view, _html} = live(conn, ~p"/c/#{open}")

    # The button follows the open chat's project, not "/".
    assert has_element?(view, "#new-chat[href='/p/#{project.id}/new']")

    view |> element("#new-chat") |> render_click()
    assert_redirect(view, "/p/#{project.id}/new")

    # Following that destination starts a chat in that project.
    assert {:error, {:live_redirect, %{to: "/c/" <> id}}} =
             live(conn, ~p"/p/#{project.id}/new")

    assert Agent.snapshot(id).project.id == project.id
  end

  # UI-73, UI-9, INTR-3, UI-72
  test "a turn a restart cut short is an error row, and the chat is no longer flagged",
       %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # The app stopped mid-turn: the chat carries the turn it was running, so
    # opening it is what turns the record into a notice (INTR-3).
    turn = %{id: "turn-1", started_at: DateTime.utc_now()}
    :ok = Elia.Store.save(id, [Message.user("run it")], turn: turn)

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    # UI-9, UI-73: a harness message, but rendered as an error rather than as a
    # notice. (The transcript streams its items, so the row's own id is the
    # item's, prefixed by the stream's name.)
    assert has_element?(view, "#items-m1 [data-kind='error']")
    refute has_element?(view, "#items-m1 [data-kind='notice']")
    assert html =~ "The app restarted while this turn was running"

    # UI-72: the page read the chats after its session started, so the chat it is
    # showing is not flagged as interrupted.
    assert has_element?(view, "#chat-status-#{id}[data-status='idle']")
    refute has_element?(view, "#chat-status-#{id}[data-status='interrupted']")
    assert Elia.Store.load_turn(id) == nil
  end

  # UI-9: the loop's own harness messages are still notices (COMPACT-19).
  test "an ordinary harness message is a notice, not an error", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    messages = [Message.user("hi"), Message.harness("A note from the harness")]
    :ok = Elia.Store.save(id, messages)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#items-m1 [data-kind='notice']")
    refute has_element?(view, "#items-m1 [data-kind='error']")
  end

  # UI-81, LIMIT-10, SESS-37
  test "a pause at a limit is an error row in the transcript", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # The message a session writes when the loop pauses at a limit (LIMIT-10,
    # SESS-37): a harness message marked with the limit it names.
    notice =
      Message.harness(
        "Step limit reached (2 steps). The turn is paused: Continue starts the count over, Fail ends it."
      )

    notice = %{notice | meta: Map.put(notice.meta, :limit, {:steps, 2})}
    :ok = Elia.Store.save(id, [Message.user("go"), notice])

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    # UI-81: an error row, not an ordinary harness notice (UI-9), on first
    # render, from the saved messages.
    assert has_element?(view, "#items-m1 [data-kind='error']")
    refute has_element?(view, "#items-m1 [data-kind='notice']")
    assert html =~ "The turn is paused"
  end

  # UI-82, STOP-1, STOP-2
  test "a stop is an error row in the transcript, and one only", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, [], project: "harness")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    Agent.subscribe(id)

    # A turn that is running while we look at it.
    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(1_000)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("Sure.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    :ok = Agent.send_message(id, "a long turn")
    assert_receive {:agent, ^id, {:status, :running}}, 2_000

    :ok = Agent.stop(id)
    assert_receive {:agent, ^id, {:status, :idle}}, 2_000

    # UI-82: the message the session wrote (STOP-1) is the row, and it reads as
    # an error rather than as an ordinary harness notice (UI-9).
    assert has_element?(view, "[data-kind='error']")
    assert render(view) =~ "Stopped by the user."

    # UI-82, STOP-4: the error event the session also sends carries the same
    # text, and is not a second row of its own.
    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      Elia.Agent.topic(id),
      {:agent, id, {:error, "Stopped by the user."}}
    )

    html = render(view)
    assert length(String.split(html, "Stopped by the user.")) == 2
  end

  # UI-82, STOP-1
  test "a stop a session wrote reads as an error row when the chat is opened", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # The message a session writes when a turn's provider fails (STOP-1,
    # STOP-2): a harness message marked with the kind of stop it was.
    stopped = Message.harness("FakeLLM: no scripted turn")
    stopped = %{stopped | meta: Map.put(stopped.meta, :stopped, :error)}
    :ok = Elia.Store.save(id, [Message.user("go"), stopped])

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#items-m1 [data-kind='error']")
    refute has_element?(view, "#items-m1 [data-kind='notice']")
    assert html =~ "FakeLLM: no scripted turn"
  end

  # UI-77: a store of its own — a throwaway runtime root, where Elia's data and
  # so the saved chats live (DEPLOY-2) — so what `/` resumes doesn't depend on
  # the chats other tests leave behind.
  defp with_empty_store(fun) do
    root = Path.join(Workspace.root(), "resume-#{Agent.new_id()}")
    File.mkdir_p!(root)
    previous = Application.get_env(:elia, :runtime_root)
    Application.put_env(:elia, :runtime_root, root)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:elia, :runtime_root, previous),
        else: Application.delete_env(:elia, :runtime_root)

      File.rm_rf!(root)
      Elia.Settings.delete(:default_project)
    end
  end

  # A chat `/` can resume: saved with one message, so it has a title (STORE-7).
  defp saved_chat do
    id = Agent.new_id()
    :ok = Elia.Store.save(id, [Message.user("where I left off")])
    id
  end

  # A sub-task chat started after it (STORE-16, UI-77).
  defp saved_task_chat(parent) do
    id = Agent.new_id()

    :ok =
      Elia.Store.save(id, [Message.user("preamble")],
        task: %{parent_id: parent, title: "A task", brief: "Brief", status: "running"}
      )

    id
  end

  # True when `first` appears before `second` in `html`.
  defp before?(html, first, second) do
    [left | _rest] = String.split(html, second)
    left =~ first
  end
end
