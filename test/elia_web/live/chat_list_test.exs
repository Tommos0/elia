defmodule EliaWeb.ChatListTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store, Workspace}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # UI-4: the sidebar lists the 30 most recently started chats, and while those
  # are all the store holds there is nothing more to list, so no button (UI-84).
  test "the first page is the 30 most recent chats", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(30)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      assert has_element?(view, "#chat-link-#{newest}")
      assert has_element?(view, "#chat-link-#{hd(ids)}")
      refute has_element?(view, "#load-more-chats")
    end)
  end

  # UI-84: with more chats saved than the list shows, the button is there, below
  # the list — outside its scroll box, so it is visible without scrolling to the
  # end of the list — and pressing it is enough once, since that page is now all
  # of them.
  test "Load more chats lists the next page and goes when there is no more", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(31)
      oldest = hd(ids)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      assert has_element?(view, "#load-more-chats", "Load more chats")
      refute has_element?(view, "#chat-list #load-more-chats")
      refute has_element?(view, "#chat-link-#{oldest}")

      view |> element("#load-more-chats") |> render_click()

      assert has_element?(view, "#chat-link-#{oldest}")
      refute has_element?(view, "#load-more-chats")
    end)
  end

  # UI-84: a press lists 30 more — the same chats, one page longer (STORE-12
  # order) — and the button stays while further chats remain.
  test "each press adds a page of 30", %{conn: conn} do
    with_empty_store(fn ->
      # Oldest first, so `at(0)` is the last chat of the third page and `at(1)`
      # the first chat of the second.
      ids = save_chats(61)
      oldest = Enum.at(ids, 0)
      second_page = Enum.at(ids, 1)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")
      view |> element("#load-more-chats") |> render_click()

      assert has_element?(view, "#chat-link-#{second_page}")
      refute has_element?(view, "#chat-link-#{oldest}")
      assert has_element?(view, "#load-more-chats")

      view |> element("#load-more-chats") |> render_click()

      assert has_element?(view, "#chat-link-#{oldest}")
      refute has_element?(view, "#load-more-chats")
    end)
  end

  # UI-85: the pages the user loaded survive the refreshes the sidebar does
  # anyway — here a deletion from another chat's row (UI-65) — rather than the
  # list falling back to its first page and hiding a chat that was on screen.
  test "a refresh keeps the pages that were loaded", %{conn: conn} do
    with_empty_store(fn ->
      # 62 chats, oldest first: the first page is the newest 30, and a press
      # loads the next 30 (the chats at 2 onward), leaving the two oldest out.
      ids = save_chats(62)
      oldest = Enum.at(ids, 0)
      deleted = Enum.at(ids, 5)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")
      view |> element("#load-more-chats") |> render_click()

      # A chat from the loaded second page, deleted (UI-65).
      view |> element("#delete-chat-#{deleted}") |> render_click()

      refute has_element?(view, "#chat-link-#{deleted}")
      assert has_element?(view, "#chat-link-#{Enum.at(ids, 2)}")
      refute has_element?(view, "#chat-link-#{oldest}")
      assert has_element?(view, "#load-more-chats")
    end)
  end

  # UI-85: the size loaded lives in the browser. The server hands it over when
  # the button is pressed — the hook's job is to write it down — and a page that
  # mounts again, as opening another chat does (UI-2), takes it back from the
  # hook's event, so browsing between chats re-lists the same pages.
  test "the loaded size is handed to the browser and taken back on mount", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(61)
      oldest = Enum.at(ids, 0)
      second_page = Enum.at(ids, 1)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      # UI-85: the hook hangs off the list itself, and a `phx-hook` naming a
      # module that has no such script mounts nothing — the browser's half then
      # never runs and the list quietly starts at the first page again. That is
      # what this asserts, since it is all the fast suite can see of the client:
      # the markup resolves `.ChatPageSize` to the module it was compiled in, so
      # the name and the script have to stay in `EliaWeb.ChatList` together.
      assert has_element?(view, "#chat-list[phx-hook='EliaWeb.ChatList.ChatPageSize']")

      view |> element("#load-more-chats") |> render_click()
      assert_push_event(view, "chat_page", %{limit: 60})

      # Another view of the chat, as opening another chat gives (UI-2): the first
      # page again, until the hook hands the remembered size back.
      {:ok, other, _html} = live(conn, ~p"/c/#{newest}")
      refute has_element?(other, "#chat-link-#{second_page}")

      render_hook(other, "chat_page", %{"limit" => 60})

      assert has_element?(other, "#chat-link-#{second_page}")
      refute has_element?(other, "#chat-link-#{oldest}")

      # UI-85: a value that isn't a number, and one below the first page, are
      # ignored rather than honoured, so the list never shrinks below UI-4's 30.
      render_hook(other, "chat_page", %{"limit" => "60"})
      render_hook(other, "chat_page", %{"limit" => 10})

      refute has_element?(other, "#chat-link-#{second_page}")
      assert has_element?(other, "#chat-link-#{newest}")
    end)
  end

  # UI-85: with nothing stored the list is the first page, as before.
  test "nothing stored lists the first page", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(31)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      refute has_element?(view, "#chat-link-#{hd(ids)}")
      assert has_element?(view, "#load-more-chats")
    end)
  end

  # UI-105: the filters sit at the top of the list — above the "New chat" button
  # and the list's own scroll box — one toggle per group, and all three are
  # pressed, so nothing is hidden from a user who never presses one.
  test "the filters are at the top of the list, one per group, all on", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(2)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      assert has_element?(view, "#chat-filters")
      refute has_element?(view, "#chat-list #chat-filters")

      assert has_element?(
               view,
               "#filter-running[aria-pressed='true'][title='Running chats']" <>
                 "[aria-label='Running chats']"
             )

      assert has_element?(view, "#filter-idle[aria-pressed='true'][title='Idle chats']")
      assert has_element?(view, "#filter-done[aria-pressed='true'][title='Finished chats']")

      html = render(view)

      assert before?(html, "id=\"chat-filters\"", "id=\"new-chat\"")
      assert before?(html, "id=\"new-chat\"", "id=\"chat-list\"")
    end)
  end

  # UI-106: a toggle governs the chats of its own status (UI-59) and no others —
  # the idle filter hides the idle chat, the finished filter the done one — and
  # pressing it again lists them again, without a reload.
  test "a toggle hides the chats of its status, and pressing it again lists them", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(2)
      open = List.last(ids)
      finished = hd(ids)
      :ok = Store.save(finished, [Message.user("finished work")], done: true)

      {:ok, view, _html} = live(conn, ~p"/c/#{open}")

      assert has_element?(view, "#chat-status-#{open}[data-status='idle']")
      assert has_element?(view, "#chat-status-#{finished}[data-status='done']")

      view |> element("#filter-idle") |> render_click()

      assert has_element?(view, "#filter-idle[aria-pressed='false']")
      refute has_element?(view, "#chat-link-#{open}")
      assert has_element?(view, "#chat-link-#{finished}")

      view |> element("#filter-idle") |> render_click()

      assert has_element?(view, "#filter-idle[aria-pressed='true']")
      assert has_element?(view, "#chat-link-#{open}")

      view |> element("#filter-done") |> render_click()

      assert has_element?(view, "#filter-done[aria-pressed='false']")
      refute has_element?(view, "#chat-link-#{finished}")
      assert has_element?(view, "#chat-link-#{open}")
    end)
  end

  # UI-106: the running filter hides the chat whose turn is running, and a chat
  # that is in none of the three groups is never hidden: the same chat is listed
  # again the moment it needs the user, with the running filter still off.
  test "the running filter hides a working chat, never one that needs the user",
       %{conn: conn} do
    with_empty_store(fn ->
      open = Agent.new_id()
      busy = Agent.new_id()
      :ok = Store.save(open, [Message.user("the open chat")])
      :ok = Store.save(busy, [Message.user("go and do it")])

      {:ok, pid} = Agent.ensure_started(busy)
      on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

      # APPR-14: a new chat starts with every tool that can need approval
      # auto-approved, so the call is turned off before the turn runs.
      :ok = Agent.set_auto_approve(busy, "shell", false)

      FakeLLM.push(
        held_turn(
          self(),
          FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "ls"})])
        )
      )

      :ok = Agent.send_message(busy, "go")
      assert_receive {:model_waiting, loop}, 2_000

      {:ok, view, _html} = live(conn, ~p"/c/#{open}")
      assert has_element?(view, "#chat-status-#{busy}[data-status='working']")

      view |> element("#filter-running") |> render_click()

      assert has_element?(view, "#filter-running[aria-pressed='false']")
      refute has_element?(view, "#chat-link-#{busy}")
      assert has_element?(view, "#chat-link-#{open}")

      # APPR-3: the call needs the user, so the chat is one that needs them —
      # listed again, with the running filter still off.
      send(loop, :go)

      await_element(view, "#chat-status-#{busy}[data-status='awaiting_approval']")

      assert has_element?(view, "#chat-link-#{busy}")
      assert has_element?(view, "#filter-running[aria-pressed='false']")
    end)
  end

  # UI-107: chats saved, and every one the list holds hidden by the filters.
  test "a list the filters hide entirely says so", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(2)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      refute has_element?(view, "#chat-list", "No chats match the filters")

      view |> element("#filter-idle") |> render_click()

      assert has_element?(view, "#chat-list", "No chats match the filters")
      refute has_element?(view, "#chat-list", "No chats yet")
      refute has_element?(view, "#chat-link-#{newest}")
      refute has_element?(view, "#chat-status-#{newest}")
    end)
  end

  # UI-105, UI-107: with nothing saved in the open project the empty state is
  # the one it always was (UI-5), whatever the filters are set to — here in the
  # drawer, which is drawn on a page that keeps no list of its own (UI-91).
  test "an empty project says no chats yet, filters or not", %{conn: conn} do
    with_empty_store(fn ->
      {:ok, view, _html} = live(conn, ~p"/sessions")

      view |> element("#chats-toggle") |> render_click()
      view |> element("#drawer-filter-done") |> render_click()

      assert has_element?(view, "#drawer-filter-done[aria-pressed='false']")
      assert has_element?(view, "#chats-drawer #drawer-chat-list", "No chats yet")
      refute has_element?(view, "#chats-drawer #drawer-chat-list", "No chats match the filters")
    end)
  end

  # UI-105, UI-92: the row is drawn with the list wherever the list is, so the
  # drawer every other page opens carries it — under its own ids, and driving
  # the one list.
  test "the drawer carries the filters too", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(2)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/sessions")

      assert has_element?(view, "#drawer-chat-filters")
      assert has_element?(view, "#drawer-filter-running[aria-pressed='true']")

      view |> element("#chats-toggle") |> render_click()
      assert has_element?(view, "#chats-drawer #drawer-chat-link-#{newest}")

      view |> element("#drawer-filter-idle") |> render_click()

      assert has_element?(view, "#drawer-filter-idle[aria-pressed='false']")
      refute has_element?(view, "#drawer-chat-link-#{newest}")
    end)
  end

  # UI-108: a press hands the filters to the browser to keep, and a page that
  # mounts takes the tab's back — the server deciding, so anything that is not
  # three booleans leaves them as they are.
  test "the filters are handed to the browser and taken back", %{conn: conn} do
    with_empty_store(fn ->
      ids = save_chats(2)
      newest = List.last(ids)

      {:ok, view, _html} = live(conn, ~p"/c/#{newest}")

      view |> element("#filter-idle") |> render_click()

      assert_push_event(view, "chat_filter", %{
        "running" => true,
        "idle" => false,
        "done" => true
      })

      # Another view of the same chat, as opening another chat gives (UI-2): the
      # list is unfiltered until the hook hands the tab's filters back.
      {:ok, other, _html} = live(conn, ~p"/c/#{newest}")
      assert has_element?(other, "#chat-link-#{newest}")

      render_hook(other, "chat_filter", %{"running" => true, "idle" => false, "done" => true})

      assert has_element?(other, "#filter-idle[aria-pressed='false']")
      refute has_element?(other, "#chat-link-#{newest}")

      # A value that isn't a boolean, and a key missing, are ignored.
      render_hook(other, "chat_filter", %{"running" => "false", "idle" => false, "done" => true})
      render_hook(other, "chat_filter", %{"running" => true})

      assert has_element?(other, "#filter-idle[aria-pressed='false']")
      refute has_element?(other, "#chat-link-#{newest}")
    end)
  end

  # A model call that holds a turn open until the test lets it go, so the chat
  # is really running one while the list is watched (SESS-4, LOOP) — and then
  # ends with `message`, so what the turn does next is the test's to choose.
  defp held_turn(test_pid, message) do
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

  # The list follows a chat's status (UI-6), so what it shows lands a moment
  # after the change: rendering the page again is what drains the event.
  defp await_element(view, selector, tries \\ 200)

  defp await_element(_view, selector, 0), do: flunk("#{selector} never showed")

  defp await_element(view, selector, tries) do
    if has_element?(view, selector) do
      true
    else
      Process.sleep(10)
      await_element(view, selector, tries - 1)
    end
  end

  # True when `first` appears before `second` in `html`.
  defp before?(html, first, second) do
    a = :binary.match(html, first)
    b = :binary.match(html, second)

    assert match?({_, _}, a), "#{first} is not in the list's markup"
    assert match?({_, _}, b), "#{second} is not in the list's markup"

    {a_at, _} = a
    {b_at, _} = b
    a_at < b_at
  end

  # N chats, oldest first, so the list's pages can be named (STORE-12 order).
  defp save_chats(n) do
    for _ <- 1..n do
      id = Agent.new_id()
      :ok = Elia.Store.save(id, [Message.user("where I left off")])
      id
    end
  end

  # A store of its own, so the sidebar's pages are the only chats in it. The
  # same helper as `chat_live_test.exs`, which keeps its own.
  defp with_empty_store(fun) do
    root = Path.join(Workspace.root(), "chat-list-#{Agent.new_id()}")
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
end
