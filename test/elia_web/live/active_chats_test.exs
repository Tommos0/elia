defmodule EliaWeb.ActiveChatsTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store, Terminal, Workspace}
  alias Elia.LLM.Message

  # The header's active chats control (`specs/active-chats.md`, ACTIVE-1 to
  # ACTIVE-7): the count of the chats needing the user, the menu of the active
  # chats of every project, and what the page follows while it is open. The list
  # is read from the store, so each test gives itself a store of its own
  # (`with_empty_store/1`) rather than reading the chats the suite shares.

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # ACTIVE-1, ACTIVE-6: the control is on a page that keeps no chat list of its
  # own, with no count while no chat needs the user, and the menu it opens says
  # no chat is active.
  test "the header carries the control, and the menu says no chat is active", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#active-chats-toggle")
      assert has_element?(view, "#active-chats-toggle[aria-expanded='false']")
      refute has_element?(view, "#active-chats-count")
      refute has_element?(view, "#active-chats-menu")

      view |> element("#active-chats-toggle") |> render_click()

      assert has_element?(view, "#active-chats-menu")
      assert has_element?(view, "#active-chats-empty")
      assert has_element?(view, "#active-chats-toggle[aria-expanded='true']")
    end)
  end

  # ACTIVE-2, ACTIVE-3, ACTIVE-5: the count of the chats no turn is running in,
  # and the menu's rows — the active chats of every project, newest first, each
  # with its project and its status. A chat marked done is in neither.
  test "the count is the chats no turn is running in, and the menu lists them", %{conn: conn} do
    with_empty_store(fn ->
      idle = save_chat("Fix the deploy")
      interrupted = save_chat("Carry this on", turn: %{id: "t1", started_at: DateTime.utc_now()})
      done = save_chat("Finished work", done: true)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      # ACTIVE-2, ACTIVE-3: the two that are open and idle, not the done one.
      assert has_element?(view, "#active-chats-count", "2")

      view |> element("#active-chats-toggle") |> render_click()

      assert has_element?(view, "#active-chat-#{idle}[href='/c/#{idle}']")
      assert has_element?(view, "#active-chat-#{interrupted}")
      refute has_element?(view, "#active-chat-#{done}")

      # STORE-12: newest first.
      assert before?(render(view), "Carry this on", "Fix the deploy")

      # ACTIVE-5: what each row names — the chat, the project it belongs to and
      # the status the chat list draws for it.
      assert has_element?(view, "#active-chat-#{idle}", "Elia")
      assert has_element?(view, "#active-chats-status-#{idle}[data-status='idle']")
      assert has_element?(view, "#active-chats-status-#{interrupted}[data-status='interrupted']")
    end)
  end

  # ACTIVE-3, ACTIVE-7: a chat whose turn is running is listed without being
  # counted, and counted again when its turn ends.
  test "a turn running is listed and not counted, and the count comes back", %{conn: conn} do
    with_empty_store(fn ->
      id = save_chat("Run the suite")
      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#active-chats-count", "1")
      view |> element("#active-chats-toggle") |> render_click()
      assert has_element?(view, "#active-chats-status-#{id}[data-status='idle']")

      {:ok, _pid} = Agent.ensure_started(id)
      FakeLLM.push(held_turn(self()))
      :ok = Agent.send_message(id, "go")
      assert_receive {:model_waiting, loop}, 2000

      # ACTIVE-3: the turn is running, so the chat is listed and not counted.
      await_element(view, "#active-chats-status-#{id}[data-status='working']")
      await_gone(view, "#active-chats-count")
      assert has_element?(view, "#active-chat-#{id}")

      # The turn ends: the chat is idle, so it needs the user again.
      send(loop, :go)
      await_element(view, "#active-chats-count", "1")
      await_element(view, "#active-chats-status-#{id}[data-status='idle']")
    end)
  end

  # ACTIVE-3, ACTIVE-7: a tool call that waits for the user counts its chat
  # again, and the count follows the turn that is running while it waits.
  test "a tool call awaiting approval counts the chat again", %{conn: conn} do
    with_empty_store(fn ->
      id = save_chat("Deploy the fix")
      {:ok, view, _html} = live(conn, ~p"/sessions")
      view |> element("#active-chats-toggle") |> render_click()
      assert has_element?(view, "#active-chats-count", "1")

      {:ok, _pid} = Agent.ensure_started(id)
      # APPR-14: a new chat starts with every tool that can need approval
      # auto-approved, so the call is turned off before the turn runs.
      :ok = Agent.set_auto_approve(id, "shell", false)

      tool_call = FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "ls"})])
      FakeLLM.push(held_turn(self(), tool_call))
      :ok = Agent.send_message(id, "go")
      assert_receive {:model_waiting, loop}, 2000

      await_element(view, "#active-chats-status-#{id}[data-status='working']")
      await_gone(view, "#active-chats-count")

      # APPR-3: the call needs the user, so the chat does again.
      send(loop, :go)
      await_element(view, "#active-chats-status-#{id}[data-status='awaiting_approval']")
      await_element(view, "#active-chats-count", "1")
      assert has_element?(view, "#active-chat-#{id}")
    end)
  end

  # ACTIVE-4: the newest 50 active chats are listed, the rest counted, and the
  # count is over every active chat rather than only the ones listed.
  test "the menu lists 50 active chats and counts the rest", %{conn: conn} do
    with_empty_store(fn ->
      ids = for n <- 1..51, do: save_chat("Chat #{n}")
      newest = List.last(ids)
      oldest = hd(ids)

      {:ok, view, _html} = live(conn, ~p"/sessions")
      assert has_element?(view, "#active-chats-count", "51")

      view |> element("#active-chats-toggle") |> render_click()

      assert has_element?(view, "#active-chats-more", "and 1 more")
      assert has_element?(view, "#active-chat-#{newest}")
      refute has_element?(view, "#active-chat-#{oldest}")

      # `data-row-chat` is one per row, so this counts the rows the menu drew
      # (the rows carry ids of their own, ACTIVE-8).
      assert render(view) |> String.split("data-row-chat=") |> length() == 51
    end)
  end

  # ACTIVE-5: the control opens and closes the menu and never navigates, a
  # backdrop or the Escape key closes it (UI-36), and a row follows to its chat.
  test "the control toggles the menu, closes on a backdrop or Escape, and a row navigates", %{
    conn: conn
  } do
    with_empty_store(fn ->
      id = save_chat("Deploy the fix")
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view |> element("#active-chats-toggle") |> render_click()
      assert has_element?(view, "#active-chats-menu")

      # Opening it again closes it, and the page is still the page it was.
      view |> element("#active-chats-toggle") |> render_click()
      refute has_element?(view, "#active-chats-menu")
      assert has_element?(view, "#session-count")
      refute_redirected(view)

      view |> element("#active-chats-toggle") |> render_click()
      view |> element("#active-chats-backdrop") |> render_click()
      refute has_element?(view, "#active-chats-menu")
      refute has_element?(view, "#active-chats-backdrop")

      view |> element("#active-chats-toggle") |> render_click()
      render_keydown(view, "close_active_chats", %{"key" => "Escape"})
      refute has_element?(view, "#active-chats-menu")

      view |> element("#active-chats-toggle") |> render_click()
      view |> element("#active-chat-#{id}") |> render_click()
      assert_redirect(view, "/c/#{id}")
    end)
  end

  # ACTIVE-7, ACTIVE-2, SESS-48: the count and the menu follow the chats while
  # the page is open — a chat marked done leaves them, one reopened comes back,
  # and a chat deleted leaves.
  test "a chat marked done, reopened or deleted follows while the page is open", %{conn: conn} do
    with_empty_store(fn ->
      # A message, so the chat's done flag is written with it (SESS-35).
      id = save_chat("Fix the deploy", messages: [Message.user("hi")])
      {:ok, view, _html} = live(conn, ~p"/sessions")
      view |> element("#active-chats-toggle") |> render_click()
      assert has_element?(view, "#active-chats-count", "1")

      {:ok, _pid} = Agent.ensure_started(id)

      # DONE-1, DONE-2: marked done, so it is not active any more.
      {:ok, true} = Agent.set_done(id, true)
      await_gone(view, "#active-chats-count")
      refute has_element?(view, "#active-chat-#{id}")

      # DONE-9: reopened, so it is active again.
      {:ok, false} = Agent.set_done(id, false)
      await_element(view, "#active-chats-count", "1")
      assert has_element?(view, "#active-chat-#{id}")

      # SESS-48: deleted, so it leaves the list without a reload.
      :ok = Agent.delete(id)
      await_gone(view, "#active-chats-count")
      refute has_element?(view, "#active-chat-#{id}")
      assert has_element?(view, "#active-chats-empty")
    end)
  end

  # ACTIVE-8, ACTIVE-9, ACTIVE-10: a row of the header's menu is a chat's own
  # row — the shared one (EliaWeb.ChatRowMenu), whose menu a long press opens —
  # in the markup and shut from the first render, under the control's own ids,
  # with the two entries a chat row's menu has in the same order (UI-103, UI-64).
  # The rename is the header's own: pressing an entry posts the name alone, the
  # state says which row, and the row shows the new title (TITLE-8, ACTIVE-7).
  test "a row of the menu carries the shared menu, and renames that chat", %{conn: conn} do
    with_empty_store(fn ->
      first = save_chat("First chat")
      second = save_chat("Second chat")

      {:ok, view, _html} = live(conn, ~p"/sessions")
      view |> element("#active-chats-toggle") |> render_click()

      # ACTIVE-8: the row is the shared one — the hook that opens its menu on a
      # long press, a right-click or the keyboard — and the menu is in the row's
      # markup from the first render, shut, and never patched by the server.
      assert has_element?(
               view,
               "#active-chat-row-#{second}[phx-hook='EliaWeb.ChatRowMenu.ChatRowMenu']" <>
                 "[data-row-chat='#{second}']"
             )

      assert has_element?(
               view,
               "#active-chat-row-#{second} > #active-chat-row-menu-#{second}[style='display: none']"
             )

      assert has_element?(view, "#active-chat-row-menu-#{second}[phx-update='ignore']")

      # ACTIVE-9: Rename first, then the done entry (UI-109), then the delete
      # entry (UI-64), under the control's own ids.
      assert has_element?(
               view,
               "#active-chat-row-menu-#{second} #active-rename-chat-#{second}",
               "Rename"
             )

      assert has_element?(
               view,
               "#active-delete-chat-#{second}[aria-label='Delete chat']" <>
                 "[data-confirm*='Second chat']"
             )

      # ACTIVE-10: Rename puts the box in that row — the chat's title in it, all
      # of it selected and focused by the hook — and the row's link is not
      # rendered while it is there.
      view |> element("#active-rename-chat-#{second}") |> render_click()

      assert has_element?(
               view,
               "#active-chat-row-#{second} > #active-rename-form-#{second}" <>
                 " > #active-chat-rename-#{second}[value='Second chat']"
             )

      refute has_element?(view, "#active-chat-rename-#{first}")
      refute has_element?(view, "#active-chat-#{second}")

      view
      |> form("#active-rename-form-#{second}", %{"title" => "  Named from the header  "})
      |> render_submit()

      # TITLE-8: the name is the chat's own title from then on, and the row the
      # menu lists shows it — the list was read again (ACTIVE-7).
      assert has_element?(view, "#active-chat-#{second}", "Named from the header")
      assert Elia.Store.load_title(second) == "Named from the header"
      assert Elia.Store.title_by(second) == "user"

      # ACTIVE-10: the Cancel button leaves the row as it was, saving nothing,
      # and so does a name that is blank once trimmed (TITLE-2).
      view |> element("#active-rename-chat-#{second}") |> render_click()
      view |> element("#active-cancel-rename-#{second}") |> render_click()
      assert has_element?(view, "#active-chat-#{second}", "Named from the header")

      view |> element("#active-rename-chat-#{second}") |> render_click()
      view |> form("#active-rename-form-#{second}", %{"title" => "   "}) |> render_submit()

      assert has_element?(view, "#active-chat-#{second}", "Named from the header")
      assert Elia.Store.load_title(second) == "Named from the header"

      # A cancel with no row being renamed (a stale client) is nothing to do.
      render_hook(view, "active_cancel_rename", %{})
      refute has_element?(view, "#active-chat-rename-#{second}")
      assert has_element?(view, "#active-chat-#{second}")
    end)
  end

  # ACTIVE-9, ACTIVE-12, UI-109, UI-110: the header's rows carry the chat list's
  # done entry, and choosing it marks the chat done — a chat whose session isn't
  # running, on a page that is not its own — after which the row leaves the menu,
  # which lists the chats that aren't done (ACTIVE-2), and the count follows
  # (ACTIVE-3).
  test "a row's done entry marks the chat done, and the row leaves the menu",
       %{conn: conn} do
    with_empty_store(fn ->
      # A chat with something said in it — the flag a row shows is saved with
      # the chat, and an empty one is saved with its first message (SESS-35,
      # STORE-34).
      idle = save_chat("Plant the tree", messages: [Message.user("Plant the tree")])
      on_exit(fn -> Agent.delete(idle) end)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#active-chats-count", "1")
      view |> element("#active-chats-toggle") |> render_click()

      assert has_element?(
               view,
               "#active-chat-row-menu-#{idle} #active-done-chat-#{idle}",
               "Mark as done"
             )

      refute Agent.live?(idle)
      view |> element("#active-done-chat-#{idle}") |> render_click()

      assert Store.load_done(idle) == true
      refute has_element?(view, "#active-chat-#{idle}")
      refute has_element?(view, "#active-chats-count")
      assert has_element?(view, "#active-chats-empty")
    end)
  end

  # ACTIVE-10: the header's box is the header's own. A page with both copies of
  # a chat's row — a chat page, whose sidebar lists the same chat — renames the
  # chat in the row the box was opened in, and the other shows the chat as it
  # was (UI-104).
  test "the header's box is its own, not the chat list's row's", %{conn: conn} do
    with_empty_store(fn ->
      open = save_chat("The chat the page shows")
      other = save_chat("The other chat")

      {:ok, view, _html} = live(conn, ~p"/c/#{open}")

      # The header's own menu, and a rename started in it.
      view |> element("#active-chats-toggle") |> render_click()
      view |> element("#active-rename-chat-#{other}") |> render_click()

      assert has_element?(view, "#active-chat-rename-#{other}")
      # The sidebar's row of the same chat is not being renamed: its link is
      # there, and its own input is not.
      assert has_element?(view, "#chat-link-#{other}")
      refute has_element?(view, "#chat-rename-#{other}")

      # The name typed in the header's box renames that chat: the header's row
      # shows it (ACTIVE-10) and the chat's own title is the name from then on
      # (TITLE-8). The sidebar's row of the same chat keeps its link rather than
      # a box of its own — what is renamed is the chat, and which row a box is in
      # is each copy's own (UI-104, ACTIVE-10).
      view
      |> form("#active-rename-form-#{other}", %{"title" => "Renamed from the header"})
      |> render_submit()

      assert has_element?(view, "#active-chat-#{other}", "Renamed from the header")
      assert has_element?(view, "#chat-link-#{other}")
      refute has_element?(view, "#chat-rename-#{other}")
      assert Elia.Store.load_title(other) == "Renamed from the header"
    end)
  end

  # ACTIVE-11, UI-64, UI-65, ACTIVE-7: the delete entry of the header's menu —
  # the chat list's own event (UI-64) — deletes the chat, and the row leaves the
  # menu without a reload. Deleting the chat the page shows leaves for `/chats`
  # (UI-77).
  test "the menu's delete entry deletes the chat, and the row leaves", %{conn: conn} do
    with_empty_store(fn ->
      open = save_chat("The chat the page shows")
      other = save_chat("The other chat")

      {:ok, view, _html} = live(conn, ~p"/c/#{open}")
      view |> element("#active-chats-toggle") |> render_click()
      assert has_element?(view, "#active-chat-#{other}")

      view |> element("#active-delete-chat-#{other}") |> render_click()

      # UI-65, SESS-29: the chat is gone, and its row left the menu.
      await_gone(view, "#active-chat-#{other}")
      refute Elia.Store.exists?(other)
      refute_redirected(view)
      assert has_element?(view, "#active-chat-#{open}")

      # UI-65, UI-77: deleting the chat the page shows leaves the chat page.
      view |> element("#active-delete-chat-#{open}") |> render_click()
      assert_redirect(view, "/chats")
    end)
  end

  # ACTIVE-13, TERM-41: a row whose chat has a terminal running shows the
  # terminal mark, and drops it when that terminal ends; a row whose chat has
  # none shows nothing.
  @tag skip: if(Terminal.available?(), do: false, else: "tmux is not installed")
  test "a row marks a chat whose terminal is running", %{conn: conn} do
    with_empty_store(fn ->
      marked = save_chat("Has a terminal")
      plain = save_chat("Has none")
      on_exit(fn -> Agent.delete(marked) end)

      assert {:ok, _pid} = Terminal.start(marked, command: "sleep 30", jail: false)

      {:ok, view, _html} = live(conn, ~p"/sessions")
      view |> element("#active-chats-toggle") |> render_click()

      assert has_element?(view, "#active-chats-terminal-#{marked}[data-terminal='running']")
      refute has_element?(view, "#active-chats-terminal-#{plain}")

      assert {:ok, _status} = Terminal.stop(marked)
      refute has_element?(view, "#active-chats-terminal-#{marked}")
    end)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # A store of its own, so nothing else in the suite is listed with these chats.
  defp with_empty_store(fun) do
    root = Path.join(Workspace.root(), "active-chats-#{Agent.new_id()}")
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

  defp save_chat(title, opts \\ []) do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    messages = Keyword.get(opts, :messages, [])

    :ok =
      Store.save(
        id,
        messages,
        opts |> Keyword.drop([:messages]) |> Keyword.merge(title: title)
      )

    id
  end

  # A model call that holds a turn open until the test lets it go, so the chat
  # is really running one while the page is watched (SESS-4, LOOP) — and then
  # ends with `message`, so what the turn does next is the test's to choose.
  defp held_turn(test_pid, message \\ FakeLLM.assistant([Message.text("Done.")])) do
    fn _request, _on_event ->
      send(test_pid, {:model_waiting, self()})

      receive do
        :go -> :ok
      end

      {:ok,
       %{
         message: message,
         stop_reason: if(Message.tool_calls(message) == [], do: :end_turn, else: :tool_use),
         model: "fake",
         usage: %{}
       }}
    end
  end

  # The page follows the activity topic (ACTIVE-7), so what it shows lands a
  # moment after the change: rendering it again is what drains the event.
  defp await_element(view, selector, text \\ nil, tries \\ 200)

  defp await_element(_view, selector, text, 0),
    do: flunk("#{selector} never showed #{inspect(text)}")

  defp await_element(view, selector, text, tries) do
    if has_element?(view, selector, text) do
      true
    else
      Process.sleep(10)
      await_element(view, selector, text, tries - 1)
    end
  end

  defp await_gone(view, selector, tries \\ 200)

  defp await_gone(_view, selector, 0), do: flunk("#{selector} never went away")

  defp await_gone(view, selector, tries) do
    if has_element?(view, selector) do
      Process.sleep(10)
      await_gone(view, selector, tries - 1)
    else
      true
    end
  end

  # True when `first` appears before `second` in `html`.
  defp before?(html, first, second) do
    [left | _rest] = String.split(html, second)
    left =~ first
  end
end
