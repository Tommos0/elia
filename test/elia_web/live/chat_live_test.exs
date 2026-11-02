defmodule EliaWeb.ChatLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Projects, Workspace}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  test "/ redirects to a fresh chat", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/c/" <> _id}}} = live(conn, ~p"/")
  end

  # STORE-22, UI-63: a chat started from the UI is saved as it opens, so the
  # sidebar lists it, as the open chat, before the user has sent anything.
  test "a started chat is saved and in the sidebar at once", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/")
    on_exit(fn -> Elia.Store.delete(id) end)

    # STORE-22: on disk with no messages, its project and its start time.
    assert %{id: ^id, title: "New chat", description: "New chat", project_id: "harness"} =
             Enum.find(Elia.Store.list(30), &(&1.id == id))

    assert Elia.Store.load(id) == []

    # UI-63: and the sidebar of the chat it opened shows it right away.
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-link-#{id}", "New chat")
    assert has_element?(view, "#chat-link-#{id}.bg-base-300")
    assert has_element?(view, "#chat-time-#{id}", "just now")
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

  # UI-36: on small screens the chat list opens as a drawer from a toggle button.
  test "chats toggle opens and closes the drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#chats-toggle[aria-expanded='false']")
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

  # UI-36: the toggle and backdrop only exist for small screens.
  test "chats toggle and backdrop are hidden on large screens", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "div.lg\\:hidden #chats-toggle")
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

  # UI-37: header labels collapse to icons on narrow screens.
  test "header buttons hide their labels below the sm breakpoint", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    for id <- ~w(chats-link files-link sessions-link system-link settings-link) do
      assert has_element?(view, "header ##{id}[title]")
      assert has_element?(view, "header ##{id} span.sr-only.sm\\:not-sr-only")
    end
  end

  # UI-32: the header's Chats button goes to "/" and precedes Sessions.
  test "header has a Chats button left of Sessions that opens a fresh chat", %{conn: conn} do
    id = Agent.new_id()

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "header #chats-link[href='/']", "Chats")
    [before_sessions | _] = String.split(html, "id=\"sessions-link\"")
    assert before_sessions =~ "id=\"chats-link\""

    view |> element("#chats-link") |> render_click()
    assert_redirect(view, "/")
  end

  test "chatting with an approval round-trip", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo from-shell"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

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

    assert before?(html, "id=\"chats-link\"", "id=\"projects-link\"")
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

  # PROJ-26, UI-31: "/" starts a chat in the default project.
  test "a new chat starts in the default project", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-default")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create("Default one", root)

    on_exit(fn ->
      File.rm_rf!(root)
      Projects.delete(project.id)
      Elia.Settings.delete(:default_project)
    end)

    Elia.Projects.set_default(project.id)

    assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/")
    assert Agent.snapshot(id).project.id == project.id
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

  # True when `first` appears before `second` in `html`.
  defp before?(html, first, second) do
    [left | _rest] = String.split(html, second)
    left =~ first
  end
end
