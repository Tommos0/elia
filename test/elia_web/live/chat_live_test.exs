defmodule EliaWeb.ChatLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Projects, Terminal, Workspace}
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

  # NET-1, STORE-22: a chat the UI starts is saved with no network entry at all,
  # so what it comes up as is the default of NET-1 rather than the whole network
  # by not choosing — the limit is built where the chat's jail is on, as it is
  # by default (ISOL-16).
  test "a chat started from the UI comes up allowlisted", %{conn: conn} do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    with_empty_store(fn ->
      # No stored default project, so it is Elia's own (PROJ-8).
      Elia.Settings.delete(:default_project)

      assert {:error, {:live_redirect, %{to: "/c/" <> id}}} = live(conn, ~p"/chats")

      # STORE-22, STORE-53: saved as it is started, and its file names no mode.
      chat =
        Path.join(Elia.Store.dir(), id <> ".term")
        |> File.read!()
        |> :erlang.binary_to_term()

      refute Map.has_key?(chat, :network)

      # NET-1, STORE-54: and the chat it starts is allowlisted, where a limit
      # can be built here.
      if Elia.Net.available?() do
        assert Agent.snapshot(id).settings.network == %{mode: :allowlist, hosts: []}
      end
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

  # UI-32, UI-36, UI-91: on the chat page the header's Chats button is the chat
  # list's small-screen shape — the list is on the page from `lg` up — and it
  # never navigates.
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

  # VISION-16: the card of a call that looked at a picture (VISION-12) shows the
  # picture itself, served from the chat's own workspace through the route a
  # preview's bytes come from (EXPL-24), and the `.ZoomImage` hook delegates on
  # it like any other picture of the transcript (IMG-1, IMG-6).
  test "a look's card shows the picture it read", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-vision")
    File.mkdir_p!(Path.join(root, "uploads"))
    File.write!(Path.join(root, "uploads/shot.png"), <<0x89, "PNG\r\n", 0x1A, "\n">> <> "body")
    {:ok, project} = Projects.create("Pictures", root)

    id = Agent.new_id()

    on_exit(fn ->
      File.rm_rf!(root)
      Projects.delete(project.id)
      Elia.Store.delete(id)
    end)

    :ok =
      Elia.Store.save(
        id,
        [
          Message.user("what does it show?"),
          %Message{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                id: "c1",
                name: "view_image",
                input: %{"path" => "uploads/shot.png"}
              }
            ]
          },
          %Message{
            role: :tool,
            content: [
              Message.tool_result("c1", "Looked at uploads/shot.png.", false, %{
                image: %{path: "uploads/shot.png", media_type: "image/png", size: 20}
              })
            ]
          }
        ],
        project: project.id
      )

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    document = view |> render() |> LazyHTML.from_fragment()

    assert [picture] = document |> LazyHTML.query("#items-call-c1 img") |> Enum.to_list()

    assert LazyHTML.attribute(picture, "src") == [
             "/files/raw?chat=#{id}&path=uploads%2Fshot.png"
           ]

    assert LazyHTML.attribute(picture, "alt") == ["uploads/shot.png"]
    # VISION-16: the attribute the viewer's delegated listener takes.
    assert LazyHTML.attribute(picture, "data-transcript-image") == [""]

    # The picture is not a markdown one, so the card is where the viewer gets it.
    assert [] == LazyHTML.query(document, ".markdown img") |> Enum.to_list()

    # IMG-6: the listener is on the viewer, and takes an image wherever the
    # transcript put it.
    assert [hook] =
             document |> LazyHTML.query("#image-lightbox") |> LazyHTML.attribute("phx-hook")

    assert hook =~ "ZoomImage"
  end

  # VISION-16: the card shows the picture of a call just made, in the running
  # turn — the same card the saved chat renders.
  test "a look's card shows the picture in a live turn", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-vision-live")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "shot.png"), <<0x89, "PNG\r\n", 0x1A, "\n">> <> "body")
    {:ok, project} = Projects.create("Live pictures", root)

    id = Agent.new_id()

    on_exit(fn ->
      File.rm_rf!(root)
      Projects.delete(project.id)
      Elia.Store.delete(id)
    end)

    :ok = Elia.Store.save(id, [], project: project.id)

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "view_image", %{"path" => "shot.png"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("A picture.")]))

    # VISION-4, VISION-7: the turn's model accepts pictures, which is what the
    # look is refused without.
    {:ok, _pid} = Agent.ensure_started(id, loop_opts: [llm: %{provider: FakeLLM, vision: true}])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "look at shot.png"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    assert has_element?(view, "#items-call-c1 img[src='/files/raw?chat=#{id}&path=shot.png']")
    assert has_element?(view, "#items-call-c1 img[data-transcript-image]")
  end

  # VISION-16: a card whose file the route would not serve — a path that left the
  # workspace, one that is gone, one that is no previewable file (EXPL-25) —
  # carries no picture rather than a broken one.
  test "a look's card shows nothing for a picture that can't be served", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-vision-gone")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create("No pictures", root)

    id = Agent.new_id()

    on_exit(fn ->
      File.rm_rf!(root)
      Projects.delete(project.id)
      Elia.Store.delete(id)
    end)

    looks =
      for {call, path} <- [
            {"c1", "uploads/gone.png"},
            {"c2", "../outside.png"},
            {"c3", "uploads/"}
          ] do
        [
          %Message{
            role: :assistant,
            content: [
              %{type: :tool_call, id: call, name: "view_image", input: %{"path" => path}}
            ]
          },
          %Message{
            role: :tool,
            content: [
              Message.tool_result(call, "Looked at #{path}.", false, %{
                image: %{path: path, media_type: "image/png", size: 20}
              })
            ]
          }
        ]
      end

    :ok = Elia.Store.save(id, [Message.user("look") | List.flatten(looks)], project: project.id)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    for call <- ~w(c1 c2 c3) do
      assert has_element?(view, "#items-call-#{call}")
      refute has_element?(view, "#items-call-#{call} img")
    end
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

    # Age the listed chat by an hour without rendering, then let the list's
    # clock render it (UI-34, UI-92).
    :sys.replace_state(view.pid, fn state ->
      update_in(state.socket.assigns.chat_list.chats, fn chats ->
        Enum.map(chats, &%{&1 | created_at: DateTime.add(&1.created_at, -3600)})
      end)
    end)

    send(view.pid, :chat_list_tick)
    assert has_element?(view, time, "1 hour ago")
  end

  # UI-64, UI-103: every chat row — task chats too (UI-45) — draws a menu of its
  # own, and the menu is where the row's delete entry lives. It is in the row's
  # markup from the first render and shut until the gesture opens it, and it is
  # the client's: never patched by the server, so an open one is never a state
  # the server has to remember (UI-103). A row carries no delete control of its
  # own (UI-64).
  test "each sidebar chat draws its own menu, shut, from the first render", %{conn: conn} do
    parent = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> Enum.each([parent, child], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(parent, [Message.user("delegate this")])

    :ok =
      Elia.Store.save(child, [Message.user("preamble")],
        title: "Task one",
        task: %{parent_id: parent, started_at: DateTime.utc_now()}
      )

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    for id <- [parent, child] do
      # UI-103: the row opens it, so the hook is on the row itself.
      assert has_element?(
               view,
               "#chat-row-#{id}[phx-hook='EliaWeb.ChatRowMenu.ChatRowMenu'][data-row-chat='#{id}']"
             )

      # UI-103: in the markup from the first render, and hidden until then.
      assert has_element?(view, "#chat-row-#{id} > #chat-row-menu-#{id}[style='display: none']")
      assert has_element?(view, "#chat-row-menu-#{id}[aria-hidden='true']")

      # The client owns it (UI-103): patching the row never touches the menu.
      assert has_element?(view, "#chat-row-menu-#{id}[phx-update='ignore']")

      # It sits beside the link, in the row's own box, so neither is nested in
      # the other (UI-103) — and the link is not inside it.
      assert has_element?(view, "#chat-row-#{id} > #chat-link-#{id}")
      refute has_element?(view, "#chat-link-#{id} #chat-row-menu-#{id}")
      refute has_element?(view, "#chat-link-#{id} button")

      # UI-103: "Rename" first, then the delete entry (UI-64), in that order.
      assert has_element?(view, "#chat-row-menu-#{id} #rename-chat-#{id}", "Rename")
      assert has_element?(view, "#chat-row-menu-#{id} #delete-chat-#{id}")
      assert id_of(view, "#chat-row-menu-#{id} button:first-of-type") == "rename-chat-#{id}"
      assert id_of(view, "#chat-row-menu-#{id} button:last-of-type") == "delete-chat-#{id}"

      # UI-64: the delete entry keeps its accessible label and names the chat it
      # deletes. It is a button of the menu, not one of the row's own.
      assert has_element?(
               view,
               "#delete-chat-#{id}[aria-label='Delete chat'][title='Delete chat']"
             )

      assert has_element?(view, "#delete-chat-#{id} .hero-trash")
      refute has_element?(view, "#chat-row-#{id} button:not(#chat-row-menu-#{id} button)")
    end

    # The link keeps the status indicator and the start time (UI-34, UI-59), and
    # the link is what the menu's gesture is looked for on (UI-103).
    assert has_element?(view, "#chat-link-#{parent} #chat-status-#{parent}")
    assert has_element?(view, "#chat-link-#{parent} #chat-time-#{parent}")
    assert has_element?(view, "#chat-link-#{parent}.bg-base-300")
    assert has_element?(view, "#chat-link-#{parent}[data-row-link]")
    # UI-64: the confirmation names the chat it deletes.
    assert has_element?(view, "#delete-chat-#{parent}[data-confirm*='delegate this']")
    assert has_element?(view, "#delete-chat-#{child}[data-confirm*='Task one']")
  end

  # The id of one element, for the assertions about a menu's order (UI-103).
  defp id_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("id")
    |> List.first()
  end

  # UI-104, UI-103: a chat is renamed from its own row. The menu's "Rename" puts
  # the input in the row's place — the link is not rendered then, so a press on
  # the row cannot navigate away mid-rename — holding the chat's title with all
  # of it selected and focused, and the name the input posts on Enter (the
  # form's own `phx-submit`) is the chat's from then on (TITLE-8, STORE-55).
  # The row's `title` attribute stays the chat's description (UI-33).
  test "a chat is renamed from its own row", %{conn: conn} do
    open = Agent.new_id()
    other = Agent.new_id()
    on_exit(fn -> Enum.each([open, other], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(open, [Message.user("the open chat")])
    :ok = Elia.Store.save(other, [Message.user("the other chat")])

    {:ok, view, _html} = live(conn, ~p"/c/#{open}")
    assert has_element?(view, "#chat-link-#{other}[title='the other chat']")
    refute has_element?(view, "#rename-form-#{other}")

    view |> element("#rename-chat-#{other}") |> render_click()

    # The input takes the link's place, holding the chat's title — not its
    # description (UI-33) — and the row's link is not rendered at all.
    assert has_element?(view, "#chat-row-#{other} > #rename-form-#{other}")
    refute has_element?(view, "#chat-link-#{other}")
    assert has_element?(view, "#chat-rename-#{other}[value='the other chat']")
    assert has_element?(view, "#chat-rename-#{other}[maxlength='60']")
    assert has_element?(view, "#chat-rename-#{other}[phx-hook='EliaWeb.ChatRowMenu.ChatRename']")
    refute has_element?(view, "#chat-rename-#{other} #chat-row-menu-#{other}")

    view
    |> form("#rename-form-#{other}", %{"title" => "  A name of its own  "})
    |> render_submit()

    # TITLE-2: a name is shaped like any title; the row shows it and the link is
    # back. TITLE-9: and it is the user's from then on.
    assert has_element?(view, "#chat-link-#{other}", "A name of its own")
    refute has_element?(view, "#rename-form-#{other}")
    assert Elia.Store.load_title(other) == "A name of its own"
    assert Elia.Store.title_by(other) == "user"
  end

  # UI-104, TITLE-2: a name that is blank once trimmed is no title at all — it
  # saves nothing and the row goes back to what it showed, exactly as
  # cancelling leaves it.
  test "a blank name leaves the row as it was", %{conn: conn} do
    open = Agent.new_id()
    other = Agent.new_id()
    on_exit(fn -> Enum.each([open, other], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(open, [Message.user("the open chat")])
    :ok = Elia.Store.save(other, [Message.user("the other chat")])

    {:ok, view, _html} = live(conn, ~p"/c/#{open}")
    view |> element("#rename-chat-#{other}") |> render_click()

    view |> form("#rename-form-#{other}", %{"title" => "   "}) |> render_submit()

    refute has_element?(view, "#rename-form-#{other}")
    assert has_element?(view, "#chat-link-#{other}", "the other chat")
    assert Elia.Store.load_title(other) == nil
    assert Elia.Store.title_by(other) == nil
  end

  # UI-104: cancelling — the row's own control, and the hook's Escape and press
  # outside — puts the row back exactly as it was and saves nothing.
  test "cancelling a rename puts the link back", %{conn: conn} do
    open = Agent.new_id()
    other = Agent.new_id()
    on_exit(fn -> Enum.each([open, other], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(open, [Message.user("the open chat")])
    :ok = Elia.Store.save(other, [Message.user("the other chat")])

    {:ok, view, _html} = live(conn, ~p"/c/#{open}")
    view |> element("#rename-chat-#{other}") |> render_click()
    view |> element("#cancel-rename-#{other}") |> render_click()

    refute has_element?(view, "#rename-form-#{other}")
    assert has_element?(view, "#chat-link-#{other}", "the other chat")
    assert Elia.Store.load_title(other) == nil

    # The same through the event the input's own hook pushes when the focus
    # leaves it or Escape is pressed in it (UI-104).
    view |> element("#rename-chat-#{other}") |> render_click()
    assert has_element?(view, "#rename-form-#{other}")
    render_hook(view, "cancel_rename", %{})

    refute has_element?(view, "#rename-form-#{other}")
    assert Elia.Store.load_title(other) == nil
  end

  # UI-103, UI-64: choosing a menu's entry once is enough — "Rename" opens the
  # input (UI-104), and a chat can be deleted straight from the menu it opened
  # (UI-64, UI-65).
  test "a menu's entries act on the row they were opened for", %{conn: conn} do
    open = Agent.new_id()
    other = Agent.new_id()
    on_exit(fn -> Enum.each([open, other], &Elia.Store.delete/1) end)
    :ok = Elia.Store.save(open, [Message.user("the open chat")])
    :ok = Elia.Store.save(other, [Message.user("the other chat")])

    {:ok, view, _html} = live(conn, ~p"/c/#{open}")

    view |> element("#delete-chat-#{other}") |> render_click()

    refute has_element?(view, "#chat-row-#{other}")
    assert has_element?(view, "#chat-row-#{open}")
    assert Elia.Store.list() |> Enum.any?(&(&1.id == other)) == false

    view |> element("#rename-chat-#{open}") |> render_click()
    assert has_element?(view, "#chat-rename-#{open}")
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
        title: "Nested task",
        task: %{parent_id: parent, started_at: DateTime.utc_now()},
        done: true
      )

    {:ok, view, _html} = live(conn, ~p"/c/#{observer}")
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{child}")

    view |> element("#delete-chat-#{parent}") |> render_click()

    refute has_element?(view, "#chat-link-#{parent}")
    refute has_element?(view, "#chat-children-#{parent}")
    assert has_element?(view, "#chat-list #chat-link-#{child}", "Nested task")
    # UI-46, DONE-2: its status is its own chat's — `done`, since its chat is
    # marked done — not a task status of its own (STORE-16).
    assert has_element?(view, "#chat-status-#{child}[data-status='done']")
    # The task chat is left saved, with its parent metadata (STORE-17).
    assert [%Message{}] = Elia.Store.load(child)
    assert %{parent_id: ^parent} = Elia.Store.load_task(child)
  end

  # UI-37: header labels collapse to icons on narrow screens.
  test "header buttons hide their labels below the sm breakpoint", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    # UI-32: on the chat page the first control is the chat list's toggle.
    for id <- ~w(chats-toggle files-link sessions-link system-link settings-link) do
      assert has_element?(view, "header ##{id}[title]")
      assert has_element?(view, "header ##{id} span.sr-only.sm\\:not-sr-only")
    end

    # PROJ-29: the open project beside the logo is not an icon-only control — it
    # names the project at every width, which is the point of it.
    assert has_element?(view, "header #project-switcher", "Elia")
  end

  # UI-32, UI-36, UI-91: the header's Chats control comes before the other
  # pages' links, and it is the chat list's drawer toggle wherever it is — on the
  # chat page (which draws the list itself, UI-4) and on a page that keeps no
  # list of its own (UI-91). It never navigates: the drawer opens over the page
  # and the page is still there afterwards.
  test "the header's Chats control opens the chat list's drawer, on every page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "header #chats-toggle")
    assert before?(html, "id=\"chats-toggle\"", "id=\"sessions-link\"")
    assert before?(html, "id=\"project-switcher\"", "id=\"chats-toggle\"")

    # Clicking it opens the drawer. The view is still mounted afterwards, so
    # the click did not navigate anywhere.
    view |> element("#chats-toggle") |> render_click()
    assert has_element?(view, "#chats-backdrop")
    assert has_element?(view, "#chat-form")

    # UI-32, UI-91: on the chat page it opens the page's own list; elsewhere it
    # opens the drawer that is that page's chat list, and the page stays put.
    {:ok, files, _html} = live(conn, ~p"/files")
    assert has_element?(files, "header #chats-toggle[aria-controls='chats-drawer']", "Chats")
    refute has_element?(files, "header #chats-link")
    refute has_element?(files, "#chats-backdrop")

    files |> element("#chats-toggle") |> render_click()
    assert has_element?(files, "#chats-backdrop")
    refute has_element?(files, "#chats-drawer.hidden")
    assert has_element?(files, "#chats-drawer #drawer-chat-list")
    assert has_element?(files, "#file-viewer")
  end

  # UI-7, UI-18: an empty chat shows the empty state that says Elia can run shell
  # commands and that the user approves each one, and a call awaiting approval
  # offers its Approve and Deny buttons (`#approve-<call_id>`, `#deny-<call_id>`).
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

  # UI-87: the top of the chat carries a jump-to-the-end button beside the
  # context indicator (CTX-1) on any chat, whatever the transcript holds. What
  # pressing it does is the browser's own: the scroll and the follow state it
  # restores (UI-14) are covered in the browser suite, since a JS command pushes
  # no event for a LiveView test to see.
  test "the chat top shows the jump-to-the-end button", %{conn: conn} do
    id = Agent.new_id()

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "button#jump-to-end")
    assert has_element?(view, "#jump-to-end[title='Jump to the latest message']")
    assert has_element?(view, "#jump-to-end[aria-label='Jump to the latest message']")
    assert has_element?(view, "#context-indicator")
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

  # CTX-5: shell traffic lands in the Shell bucket, every other tool in Other
  # tools.
  test "context breakdown buckets a tool call from a saved chat", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    messages = [
      Message.user("read my notes"),
      %Message{
        role: :assistant,
        content: [
          %{type: :tool_call, id: "r1", name: "cd", input: %{"path" => "lib"}},
          %{type: :tool_call, id: "s1", name: "shell", input: %{"command" => "ls"}}
        ]
      },
      %Message{
        role: :tool,
        content: [
          Message.tool_result("r1", "Working directory: lib"),
          Message.tool_result("s1", "lib\nREADME.md\n")
        ]
      },
      %Message{role: :assistant, content: [Message.text("Found it.")]}
    ]

    Elia.Store.save(id, messages)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    view |> element("#context-indicator") |> render_click()

    html = render(view)
    assert html =~ "Other tools"
    assert html =~ "Shell"
    assert html =~ "User"
    assert html =~ "Assistant"
  end

  # UI-8, UI-10, UI-25: assistant text renders as Markdown, and the text that is
  # still streaming lives in a draft block below the transcript — which is gone
  # once the assistant message lands.
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

  # FLINK-1, FLINK-4: a file the agent mentions in a reply, and the path on a tool
  # call whose input carries one — a `cd` — link to that file's own Files page,
  # that of the workspace the chat works in (FLINK-5).
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
          %{type: :tool_call, id: "call-flink", name: "cd", input: %{"path" => file}}
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

  # FUNC-1, FUNC-4: an Elixir function the agent mentions in a reply links to
  # the line its definition is written at, in the workspace the chat works in —
  # while the text streams into the draft (UI-10) and once the message is saved
  # (UI-8) — and an arity the workspace doesn't define stays plain text.
  test "a mentioned function links to its definition", %{conn: conn} do
    id = Agent.new_id()
    test_pid = self()
    on_exit(fn -> Elia.Store.delete(id) end)

    file = "chat_live_function_fixture.ex"

    File.write!(
      Path.join(Workspace.root(), file),
      "defmodule ChatFixture do\n  def go(a), do: a\nend\n"
    )

    on_exit(fn -> File.rm!(Path.join(Workspace.root(), file)) end)

    FakeLLM.push(fn _request, on_event ->
      on_event.({:text_delta, "It is `ChatFixture.go/1`, not ChatFixture.go/2."})
      send(test_pid, {:streamed, self()})
      receive do: (:finish -> :ok)

      {:ok,
       %{
         message:
           FakeLLM.assistant([Message.text("It is `ChatFixture.go/1`, not ChatFixture.go/2.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "where is it?"}) |> render_submit()
    assert_receive {:streamed, llm}, 5000
    _ = :sys.get_state(view.pid)

    href = "/files?chat=#{id}&path=#{file}&line=2"

    # FUNC-1, FUNC-8, UI-10: the mention in the streaming draft links, and still
    # reads as code.
    assert has_element?(view, "#draft .markdown a[href='#{href}'] code", "ChatFixture.go/1")

    send(llm, :finish)
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    # FUNC-1, UI-8: and so does the saved message.
    assert has_element?(view, "#transcript .markdown a[href='#{href}'] code", "ChatFixture.go/1")
    refute has_element?(view, "#transcript .markdown a", "ChatFixture.go/2")
  end

  # CITE-1: a requirement the reply cites carries that requirement's own text as
  # a tooltip — while the text streams into the draft (UI-10) and once the
  # message is saved (UI-8) — read from the corpus the chat's own workspace
  # holds (CITE-4, PROJ-12).
  test "a cited requirement shows its own text as a tooltip", %{conn: conn} do
    id = Agent.new_id()
    test_pid = self()

    spec = "chat_live_cite_fixture.md"
    dir = Path.join(Workspace.root(), "specs")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, spec),
      "# Fixture\n\n## Requirements\n\n- **CITE-8** A requirement the reply cites.\n"
    )

    on_exit(fn ->
      File.rm(Path.join(dir, spec))
      File.rmdir(dir)
    end)

    FakeLLM.push(fn _request, on_event ->
      on_event.({:text_delta, "See CITE-8"})
      send(test_pid, {:streamed, self()})
      receive do: (:finish -> :ok)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("See CITE-8")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "which requirement?"}) |> render_submit()
    assert_receive {:streamed, llm}, 5000
    _ = :sys.get_state(view.pid)

    cited = "span.spec-cite[title='A requirement the reply cites.']"

    # CITE-1, UI-10: the citation in the streaming draft carries it too.
    assert has_element?(view, "#draft .markdown #{cited}", "CITE-8")

    send(llm, :finish)
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    # CITE-1, UI-8: and so does the saved message.
    assert has_element?(view, "#transcript .markdown #{cited}", "CITE-8")
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

  # UI-10, UI-29, UI-30: streaming reasoning is collapsed too and marked as in
  # progress, and its draft clears when the message lands.
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

  # CTX-6, CTX-12: provider-reported input usage (with cache tokens) appears
  # after a turn, and a reset clears it and its cache line (CTX-13).
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

    # CTX-12: the cached part of that figure is shown too.
    cache = view |> element("#context-cache-usage") |> render()
    assert cache =~ "12K"
    assert cache =~ "prompt cache"

    send(view.pid, {:agent, id, {:reset, []}})
    refute has_element?(view, "#context-provider-usage")
    refute has_element?(view, "#context-cache-usage")
  end

  # CTX-13: a report with no cache figure leaves the cache line out rather than
  # showing a zero.
  test "a report without cache figures shows no cache line", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(fn _request, _on_event ->
      msg = FakeLLM.assistant([Message.text("No caching here.")])

      {:ok,
       %{message: msg, stop_reason: :end_turn, model: "fake", usage: %{"input_tokens" => 345}}}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "how big is my context?"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    view |> element("#context-indicator") |> render_click()
    assert has_element?(view, "#context-provider-usage")
    refute has_element?(view, "#context-cache-usage")
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

  # PROJ-29, PROJ-30: the header names the open project next to the logo, and it
  # carries no Projects link of its own — the projects page is reached from the
  # switcher's menu.
  test "the header names the open project next to the logo", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "header #project-switcher", "Elia")
    refute has_element?(view, "header #projects-link")
    # It stands beside the logo, before the header's other controls.
    assert before?(html, "id=\"project-switcher\"", "id=\"chats-toggle\"")
  end

  # PROJ-31, PROJ-28: the sidebar holds the open project's chats and no other
  # project's, and its "New chat" starts a chat in that project (UI-31).
  test "the sidebar lists the open project's chats only", %{conn: conn} do
    root = Path.join(Workspace.root(), "chat-live-group")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create("Grouped", root)

    project_chat = Agent.new_id()
    harness_chat = Agent.new_id()

    on_exit(fn ->
      File.rm_rf!(root)
      Elia.Store.delete(project_chat)
      Elia.Store.delete(harness_chat)
      Projects.delete(project.id)
    end)

    :ok = Elia.Store.save(project_chat, [Message.user("in project")], project: project.id)
    :ok = Elia.Store.save(harness_chat, [Message.user("in harness")])

    # A chat with no project is in Elia's own project (PROJ-9), which is the
    # open one here, so its chats are the list's.
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#new-chat[href='/p/harness/new']")
    assert has_element?(view, "#chat-list #chat-link-#{harness_chat}")
    refute has_element?(view, "#chat-list #chat-link-#{project_chat}")
    refute has_element?(view, "#chat-list #project-header-harness")

    # Opening the other project's chat opens that project (PROJ-28), and the
    # list is then that project's.
    {:ok, view, _html} = live(conn, ~p"/c/#{project_chat}")

    assert has_element?(view, "header #project-switcher", "Grouped")
    assert has_element?(view, "#new-chat[href='/p/#{project.id}/new']")
    assert has_element?(view, "#chat-list #chat-link-#{project_chat}")
    refute has_element?(view, "#chat-list #chat-link-#{harness_chat}")
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

  # UI-86, RETRY-2, RETRY-3
  test "a retry clears the drafts and shows why it is waiting", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    # RETRY-4: a wait short enough for a test, long enough to look at.
    {:ok, pid} = Agent.ensure_started(id, loop_opts: [step_retry: [delays_ms: [1000]]])
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    # The first attempt streams half an answer and times out; the retry answers.
    FakeLLM.push(fn _request, on_event ->
      on_event.({:text_delta, "Half an ans"})
      {:error, Elia.LLM.Error.transient("Anthropic API request failed: timeout")}
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("A whole answer.")]))

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:retry, _info}}, 5000

    # While it waits: the row says why and for how long (UI-86), and the half
    # answer the failed attempt streamed is gone — the drafts clear, since the
    # answer starts over (RETRY-2) — with the new answer not in yet.
    html = render(view)
    assert html =~ "Anthropic API request failed: timeout. Retrying in 1 second (attempt 2 of 2)."
    refute html =~ "Half an ans"
    refute html =~ "A whole answer."

    assert_receive {:agent, ^id, {:status, :idle}}, 10_000
    assert render(view) =~ "A whole answer."
  end

  # UI-77: a store of its own — a throwaway runtime root, where Elia's data and
  # so the saved chats live (DEPLOY-2) — so what `/` resumes doesn't depend on
  # the chats other tests leave behind. A session left running by an earlier
  # test is stopped first, so nothing writes into the throwaway store while this
  # test reads it: a chat that landed there from elsewhere would be the one
  # `/chats` resumes, and the assertions below are about this test's own chats.
  defp with_empty_store(fun) do
    # A session that dies in between is nothing to stop.
    for id <- Elia.Agent.running() do
      try do
        Elia.Agent.stop(id)
      catch
        :exit, _reason -> :ok
      end
    end

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

  # UI-111, TERM-41: a chat whose terminal is running shows the small terminal
  # mark beside its status indicator in the sidebar, and loses it when that
  # terminal ends. A chat with no terminal shows none.
  @tag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")
  test "a chat's row marks a running terminal", %{conn: conn} do
    with_empty_store(fn ->
      id = saved_chat()
      # TERM-3: deleting the chat stops its terminal, which is what a leaked
      # session needs to not leave a process tree behind for the next test.
      on_exit(fn -> Agent.delete(id) end)

      assert {:ok, _pid} = Terminal.start(id, command: "sleep 30", jail: false)

      {:ok, view, _html} = live(conn, ~p"/c/#{id}")

      assert has_element?(view, "#chat-terminal-#{id}[data-terminal='running']")
      # UI-59: the status indicator is still there, unchanged — the mark is
      # beside it, not in its place.
      assert has_element?(view, "#chat-status-#{id}")

      assert {:ok, _status} = Terminal.stop(id)
      refute has_element?(view, "#chat-terminal-#{id}")
    end)
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

  # SNAP-10, SNAP-11: a `shell` call's card lists the files the call changed and
  # the diff between the two snapshots it was bracketed by.
  test "a shell call's card shows the files it changed and their diff", %{conn: conn} do
    with_empty_store(fn ->
      id = snapshot_chat(pair_with_a_change())

      {:ok, view, html} = live(conn, ~p"/c/#{id}")

      assert has_element?(view, "#snapshot-c1")
      assert html =~ "1 file changed"
      assert html =~ "modified"
      assert html =~ "notes.txt"
      # SNAP-12: the diff comes from the pair's own snapshots.
      assert html =~ "-one"
      assert html =~ "+two"
    end)
  end

  # SNAP-15: each file the card lists is a toggle of its own — opening it shows
  # the part of the pair's diff that changes that file and no other file's
  # lines — and no diff for the call as a whole.
  test "each file's own diff opens on its own", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, html} = live(conn, ~p"/c/#{snapshot_chat(pair_with_two_changes())}")

      assert has_element?(view, "#diff-c1-0[phx-hook=Highlight][data-language=diff]")
      assert has_element?(view, "#diff-c1-1[phx-hook=Highlight][data-language=diff]")
      refute html =~ "Show diff"

      one = view |> element("#diff-c1-0") |> render()
      two = view |> element("#diff-c1-1") |> render()

      assert one =~ "+new one"
      refute one =~ "and more"
      assert two =~ "+and more"
      refute two =~ "new one"
    end)
  end

  # SNAP-16: each file the card lists shows how many lines its own part of the
  # diff adds and removes.
  test "each file shows its added and removed lines", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, _view, html} = live(conn, ~p"/c/#{snapshot_chat(pair_with_two_changes())}")

      # one.txt: one line out, one line in. two.txt: two lines in, none out.
      assert html =~ ">+1</span>"
      assert html =~ ">-1</span>"
      assert html =~ ">+2</span>"
      assert html =~ ">-0</span>"
    end)
  end

  # SNAP-10: a pair that changed nothing, and a call saved without a pair at all
  # (SNAP-7), show no files.
  test "a call that changed nothing shows no files", %{conn: conn} do
    with_empty_store(fn ->
      tree = Elia.LiveTree.create()
      on_exit(fn -> Elia.LiveTree.remove(tree) end)
      unchanged = Elia.Snapshot.record(tree, Elia.Snapshot.current(tree))

      {:ok, view, _html} = live(conn, ~p"/c/#{snapshot_chat(unchanged)}")
      refute has_element?(view, "#snapshot-c1")

      {:ok, view, _html} = live(conn, ~p"/c/#{snapshot_chat(nil)}")
      refute has_element?(view, "#snapshot-c1")
    end)
  end

  # SNAP-11: a diff longer than `max_diff` is cut on the card, with a marker
  # saying how much was left out.
  test "a diff longer than max_diff is cut on the card", %{conn: conn} do
    with_empty_store(fn ->
      previous = Application.get_env(:elia, Elia.Snapshot)
      on_exit(fn -> Application.put_env(:elia, Elia.Snapshot, previous) end)
      Application.put_env(:elia, Elia.Snapshot, max_diff: 20, timeout: 30_000)

      {:ok, _view, html} = live(conn, ~p"/c/#{snapshot_chat(pair_with_a_change())}")

      assert html =~ "more characters not shown"
    end)
  end

  # SNAP-13: the card shows the diff coloured as a diff — the file viewer's own
  # hook, named the `diff` language — so an added line, a removed line and the
  # headers are told apart by colour.
  test "the card shows its diff highlighted as a diff", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, _html} = live(conn, ~p"/c/#{snapshot_chat(pair_with_a_change())}")

      assert has_element?(view, "#diff-c1-0[phx-hook=Highlight][data-language=diff]")
    end)
  end

  # A pair of snapshots with two files changed between them: one line out and
  # one in for the first, two lines in for the second (SNAP-15, SNAP-16).
  defp pair_with_two_changes do
    tree = Elia.LiveTree.create()
    on_exit(fn -> Elia.LiveTree.remove(tree) end)
    File.write!(Path.join(tree, "one.txt"), "old one\n")
    File.write!(Path.join(tree, "two.txt"), "keep\n")
    from = Elia.Snapshot.current(tree)
    File.write!(Path.join(tree, "one.txt"), "new one\n")
    File.write!(Path.join(tree, "two.txt"), "keep\nmore\nand more\n")
    Elia.Snapshot.record(tree, from)
  end

  # A pair of snapshots with one file changed between them (SNAP-6).
  defp pair_with_a_change do
    tree = Elia.LiveTree.create()
    on_exit(fn -> Elia.LiveTree.remove(tree) end)
    File.write!(Path.join(tree, "notes.txt"), "one\n")
    from = Elia.Snapshot.current(tree)
    File.write!(Path.join(tree, "notes.txt"), "two\n")
    Elia.Snapshot.record(tree, from)
  end

  # A chat holding one `shell` call whose result carries `pair` — or no pair at
  # all, which is what a chat saved before this existed holds (SNAP-7).
  defp snapshot_chat(pair) do
    id = Agent.new_id()
    facts = if pair, do: %{snapshot: pair}, else: %{}

    :ok =
      Elia.Store.save(id, [
        Message.user("run it"),
        %Message{
          role: :assistant,
          content: [
            %{type: :tool_call, id: "c1", name: "shell", input: %{"command" => "echo hi"}}
          ]
        },
        %Message{
          role: :tool,
          content: [Message.tool_result("c1", "hi\n\n[exit: 0]", false, facts)]
        }
      ])

    id
  end

  # UI-98: a `shell` command that runs over more than one line is collapsed to
  # its first line — the ellipsis and the line count saying there is more — and
  # the whole command is one press away. A command of one line is unchanged and
  # carries no such control.
  test "a multi-line command is collapsed to its first line", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    command = "mix test\nmix precompile\nmix format"

    Elia.Store.save(id, [
      Message.user("run it"),
      %Message{
        role: :assistant,
        content: [
          %{type: :tool_call, id: "s1", name: "shell", input: %{"command" => command}},
          %{type: :tool_call, id: "s2", name: "shell", input: %{"command" => "mix test"}}
        ]
      },
      %Message{
        role: :tool,
        content: [Message.tool_result("s1", "ok\n"), Message.tool_result("s2", "ok\n")]
      }
    ])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#command-s1")
    refute has_element?(view, "#command-s1[open]")

    # Only the first line is in the summary; the rest is the block it hides.
    summary = view |> element("#command-s1 > summary") |> render()
    assert summary =~ "mix test"
    refute summary =~ "mix precompile"
    assert summary =~ "…"
    assert summary =~ "3 lines"
    full = view |> element("#command-full-s1") |> render()
    assert full =~ "mix test"
    assert full =~ "mix format"

    # A command of one line renders as it always did, with no control.
    refute has_element?(view, "#command-s2")
    card = view |> element("#items-call-s2") |> render()
    assert card =~ "mix test"
    refute card =~ "command-s2"
  end

  # UI-99: while a call awaits approval its whole command is open, so what is
  # approved can be read above the buttons.
  test "a command awaiting approval is open", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("c1", "shell", %{"command" => "mix test\nmix precompile"})
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

    # APPR-14: a new chat auto-approves every tool, so this chat is started with
    # an empty set — the command below has to wait for approval.
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "run the tests"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000

    assert has_element?(view, "#command-c1[open]")
    assert has_element?(view, "#approve-c1")

    view |> element("#approve-c1") |> render_click()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    # Once decided, the card is back to its collapsed self (UI-98).
    refute has_element?(view, "#command-c1[open]")
  end
end
