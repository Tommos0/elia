defmodule EliaWeb.TaskUITest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    parent = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> Enum.each([parent, child], &Store.delete/1) end)
    %{parent: parent, child: child}
  end

  @input %{"title" => "Add the file", "brief" => "Create child.txt.\nCommit it."}

  defp save_parent(parent, input \\ @input, call_id \\ "s1") do
    on_exit(fn -> Store.delete(parent) end)

    Store.save(parent, [
      Message.user("delegate this"),
      FakeLLM.assistant([FakeLLM.tool_call(call_id, "spawn_task", input)])
    ])
  end

  # The child chat's task metadata, as `spawn_task` writes it (STORE-16): it
  # carries no status of its own — the chat's status is the chat's (UI-46) — and
  # a file an earlier version wrote is given a `status` key here to be read past.
  defp save_child(child, parent, task_overrides \\ %{}, save_opts \\ []) do
    on_exit(fn -> Store.delete(child) end)

    task =
      Map.merge(
        %{
          parent_id: parent,
          parent_call_id: "s1",
          title: "Add the file",
          brief: "Create child.txt.\nCommit it.",
          started_at: DateTime.utc_now(),
          start_commit: "abc",
          result: %{
            "task_id" => child,
            "summary" => "Made child.txt",
            "commit" => "0123456789abcdef",
            "files" => ["child.txt"]
          }
        },
        task_overrides
      )

    Store.save(child, [Message.user("preamble")], Keyword.merge([task: task], save_opts))
  end

  defp topic_send(id, event),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.topic(id), {:agent, id, event})

  defp activity_send(id, status),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})

  # UI-47, UI-59: the row a listed chat shows, once the page has caught up with
  # the event it follows. The page's own copy of a status event is sent in the
  # same broadcast as the test's, so an assertion right after one races it.
  defp await_status(view, id, status, tries \\ 100)

  defp await_status(_view, id, status, 0),
    do: flunk("#chat-status-#{id} never showed #{status}")

  defp await_status(view, id, status, tries) do
    if has_element?(view, "#chat-status-#{id}[data-status='#{status}']") do
      :ok
    else
      Process.sleep(50)
      await_status(view, id, status, tries - 1)
    end
  end

  # UI-44: the same, for the card of the call that started the child.
  defp await_card_status(view, call_id, status, tries \\ 100)

  defp await_card_status(_view, call_id, status, 0),
    do: flunk("#task-status-#{call_id} never showed #{status}")

  defp await_card_status(view, call_id, status, tries) do
    if has_element?(view, "#task-status-#{call_id}[data-status='#{status}']") do
      :ok
    else
      Process.sleep(50)
      await_card_status(view, call_id, status, tries - 1)
    end
  end

  # UI-43
  test "a spawn_task call shows its title and brief instead of raw JSON", %{
    conn: conn,
    parent: parent
  } do
    save_parent(parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#transcript", "Add the file")
    assert has_element?(view, "#task-brief-s1", "Create child.txt.")
    refute has_element?(view, "#task-brief-s1[open]")
    refute has_element?(view, "#transcript", "\"brief\"")
    # No child yet: no card.
    refute has_element?(view, "#task-card-s1")

    # The brief is open while the call waits for approval.
    topic_send(parent, {:tool_status, "s1", :awaiting_approval})
    assert has_element?(view, "#task-brief-s1[open]")
    assert has_element?(view, "#approve-s1")
  end

  # UI-44
  test "the card links to the child and shows the status the child's own row does", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{}, done: true)

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#task-card-s1")
    assert has_element?(view, "#task-link-s1[href='/c/#{child}']")
    # UI-44, UI-46, UI-80: the card shows the child chat's own status — here the
    # `done` its chat is marked with (DONE-2) — which is the status its row in
    # the sidebar carries, from the same derivation.
    assert has_element?(view, "#task-status-s1[data-status='done']")
    assert has_element?(view, "#chat-status-#{child}[data-status='done']")
  end

  # UI-44, UI-49, SESS-19, SESS-35
  test "the card follows the child's own status, live, as its row does", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent)

    # DONE-1, DONE-4: a session of the child's own, so its chat can be marked
    # done the way the user or `mark_done` would (DONE-6).
    {:ok, pid} = Agent.ensure_started(child)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#task-status-s1[data-status='idle']")
    assert has_element?(view, "#chat-status-#{child}[data-status='idle']")

    # SESS-35: the chat's done flag is announced on the activity topic, so the
    # parent's card learns the child was marked done without waiting for a
    # reload — and shows what the child's row shows (UI-44, UI-49).
    assert {:ok, true} = Agent.set_done(child, true)
    await_status(view, child, "done")
    await_card_status(view, "s1", "done")

    # DONE-9: a message continues a done chat, which reopens it; the card and
    # the row follow that too.
    assert {:ok, false} = Agent.set_done(child, false)
    await_status(view, child, "idle")
    await_card_status(view, "s1", "idle")
  end

  # UI-44, UI-46, UI-47, UI-58
  test "the card follows the child's status events and flags what needs the user", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent)

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    assert has_element?(view, "#task-card-s1")

    activity_send(child, :running)
    assert has_element?(view, "#task-status-s1[data-status='working']")
    assert has_element?(view, "#chat-status-#{child}[data-status='working']")
    refute has_element?(view, "#task-awaiting-s1")

    activity_send(child, :awaiting_approval)
    assert has_element?(view, "#task-awaiting-s1")
    assert has_element?(view, "#task-status-s1[data-status='awaiting_approval']")

    activity_send(child, :paused)
    assert has_element?(view, "#task-paused-s1")
    assert has_element?(view, "#task-status-s1[data-status='paused']")

    activity_send(child, :idle)
    refute has_element?(view, "#task-awaiting-s1")
    refute has_element?(view, "#task-paused-s1")
    assert has_element?(view, "#task-status-s1[data-status='idle']")
  end

  # UI-44, SUBTASK-2: a child started while the page is open gets its card as
  # soon as its own chat speaks, without a reload.
  test "a child started after the page opened gets its card", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#task-card-s1")

    # The child's chat is saved when its first turn starts (STORE-2), which is
    # what its card reads: its chat, and the task metadata that names its parent.
    save_child(child, parent)
    activity_send(child, :running)

    assert has_element?(view, "#task-link-s1[href='/c/#{child}']")
    assert has_element?(view, "#task-status-s1[data-status='working']")
  end

  # UI-45, UI-46
  test "a task chat's row in the sidebar is the row any chat has", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    orphan = Agent.new_id()
    lost = Agent.new_id()
    on_exit(fn -> Enum.each([orphan, lost], &Store.delete/1) end)

    save_parent(parent)
    save_child(child, parent, %{title: "Nested task"}, done: true)
    save_child(lost, parent, %{title: "Lost task", parent_call_id: "s2"})
    save_child(orphan, "parent-not-listed", %{title: "Orphan task"})

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    # UI-64: each row is a flex container holding the link and its delete
    # button, so the link is a descendant of the list rather than its child.
    assert has_element?(view, "#chat-list #chat-link-#{parent}")
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{child}", "Nested task")
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{lost}", "Lost task")
    # Oldest first.
    html = render(view)
    [before_lost, _] = String.split(html, "id=\"chat-link-#{lost}\"")
    assert before_lost =~ "id=\"chat-link-#{child}\""

    # An orphan stays at the top level.
    assert has_element?(view, "#chat-list #chat-link-#{orphan}", "Orphan task")
    refute has_element?(view, "#chat-children-#{parent} #chat-link-#{orphan}")

    # UI-46: a task chat's row carries the status any chat's row carries, from
    # the same derivation — `done` for the one whose chat is marked done (DONE-2,
    # UI-80), and `idle` for the ones that are neither done nor running.
    assert has_element?(view, "#chat-status-#{parent}[data-status='idle']")
    assert has_element?(view, "#chat-status-#{child}[data-status='done']")
    assert has_element?(view, "#chat-status-#{lost}[data-status='idle']")
    assert has_element?(view, "#chat-status-#{orphan}[data-status='idle']")

    # …and it follows its own events the way any chat's row does (SESS-19).
    activity_send(lost, :running)
    assert has_element?(view, "#chat-status-#{lost}[data-status='working']")
  end

  # UI-47, SESS-19
  test "a chat awaiting approval is shown in the sidebar, live", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{}, done: true)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#chat-status-#{child}[data-status='awaiting_approval']")

    activity_send(child, :awaiting_approval)

    assert has_element?(
             view,
             "#chat-link-#{child} #chat-status-#{child}[data-status='awaiting_approval'][title='Needs approval']"
           )

    refute has_element?(view, "#chat-status-#{parent}[data-status='awaiting_approval']")

    # UI-59: waiting for the user comes first; with that over, the row reads the
    # chat's own status again — `done`, since this chat is marked done.
    activity_send(child, :idle)
    refute has_element?(view, "#chat-status-#{child}[data-status='awaiting_approval']")
    assert has_element?(view, "#chat-status-#{child}[data-status='done']")
  end

  # UI-47: right on first render
  test "a chat that is already awaiting approval is flagged when the page opens", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    # UI-47, SESS-19: the page follows the activity topic, and the registry it
    # reads on mount is set between the chat's own status event and that
    # broadcast (`Elia.Agent.Session.set_status/2`), so this waits for the event
    # the page itself follows rather than the chat's, which comes first.
    Agent.subscribe_activity()

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    # APPR-14: a new chat auto-approves every tool, so this chat is started with
    # an empty set — the command below has to wait for approval.
    {:ok, _pid} =
      Agent.ensure_started(child, loop_opts: [llm: %{provider: FakeLLM}], auto_approve: [])

    :ok = Agent.send_message(child, "run it")
    assert_receive {:chat_status, ^child, :awaiting_approval}, 5000

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    assert has_element?(view, "#chat-status-#{child}[data-status='awaiting_approval']")

    :ok = Agent.deny(child, "c1")
    assert_receive {:chat_status, ^child, :idle}, 5000
    # UI-47: the page's own copy of that event is sent in the same broadcast, so
    # a single render is not enough to see it — wait for the row it renders.
    await_status(view, child, "idle")
  end

  # UI-72, STORE-31, INTR-2, INTR-3: a turn a restart cut short is flagged in the
  # chat list, before the chat is opened.
  test "a chat whose turn a restart cut short is flagged until its session runs", %{
    conn: conn,
    parent: parent
  } do
    save_parent(parent)
    cut = Agent.new_id()
    on_exit(fn -> Store.delete(cut) end)

    # The app stopped mid-turn: the chat still carries the turn it was running.
    Store.save(cut, [Message.user("run it")],
      turn: %{id: "turn-1", started_at: DateTime.utc_now()}
    )

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(
             view,
             "#chat-status-#{cut}[data-status='interrupted'][title='Interrupted: the app restarted during the turn']"
           )

    # INTR-3: starting a session for the chat clears its record, and every page
    # that isn't showing it hears that on the activity topic.
    activity_send(cut, :idle)

    assert has_element?(view, "#chat-status-#{cut}[data-status='idle']")
    refute has_element?(view, "#chat-status-#{cut}[data-status='interrupted']")
  end

  # UI-72, INTR-3: because the open chat's session starts as the page mounts, the
  # record is already gone when the page lists the chats.
  test "opening an interrupted chat clears its flag", %{conn: conn} do
    cut = Agent.new_id()
    on_exit(fn -> Store.delete(cut) end)

    Store.save(cut, [Message.user("run it")],
      turn: %{id: "turn-1", started_at: DateTime.utc_now()}
    )

    {:ok, view, _html} = live(conn, ~p"/c/#{cut}")

    assert has_element?(view, "#chat-status-#{cut}[data-status='idle']")
    refute has_element?(view, "#chat-status-#{cut}[data-status='interrupted']")
  end

  # UI-59: an ordinary chat shows its activity, live.
  test "an ordinary chat is idle, then working while its turn runs", %{
    conn: conn,
    parent: parent
  } do
    save_parent(parent)
    other = Agent.new_id()
    on_exit(fn -> Store.delete(other) end)
    :ok = Store.save(other, [Message.user("hello")])

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#chat-status-#{other}[data-status='idle'][title='Idle']")

    activity_send(other, :running)
    assert has_element?(view, "#chat-status-#{other}[data-status='working'][title='Working']")

    activity_send(other, :idle)
    assert has_element?(view, "#chat-status-#{other}[data-status='idle']")
    refute has_element?(view, "#chat-status-#{other}[data-status='working']")
  end

  # UI-59, SESS-28: right on first render, from the registry.
  test "a chat already running is shown as working when the page opens", %{
    conn: conn,
    parent: parent
  } do
    save_parent(parent)
    running = Agent.new_id()
    on_exit(fn -> Store.delete(running) end)
    :ok = Store.save(running, [Message.user("hi")])

    test_pid = self()

    # A model call that blocks keeps the turn (and so the session) running.
    FakeLLM.push(fn _request, _on_event ->
      send(test_pid, {:blocking_model_call, self()})

      receive do
        :release ->
          {:ok,
           %{
             message: FakeLLM.assistant([Message.text("done")]),
             stop_reason: :end_turn,
             model: "fake",
             usage: %{}
           }}
      end
    end)

    {:ok, pid} = Agent.ensure_started(running, loop_opts: [llm: %{provider: FakeLLM}])
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)
    # SESS-19: the page follows the activity topic, so this waits for the same
    # event the page does rather than the chat's own, which is broadcast first.
    Agent.subscribe_activity()

    :ok = Agent.send_message(running, "go")
    assert_receive {:blocking_model_call, loop}, 5000
    assert running in Agent.running()

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    assert has_element?(view, "#chat-status-#{running}[data-status='working']")

    # The sidebar follows the status to idle when the turn ends (SESS-19).
    send(loop, :release)
    assert_receive {:chat_status, ^running, :idle}, 5000
    await_status(view, running, "idle")
  end

  # UI-48
  test "a task chat shows who it belongs to, its brief and its own status", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{}, done: true)

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")

    assert has_element?(view, "#task-header")
    assert has_element?(view, "#task-parent-link[href='/c/#{parent}']", "delegate this")
    # UI-48, UI-46: the header shows the chat's own status — the `done` this chat
    # is marked with (DONE-2, UI-80) — and not a status of its task's.
    assert has_element?(view, "#task-header-status[data-status='done']")
    assert has_element?(view, "#task-header-brief", "Create child.txt.")
    # UI-48: what the task ended with is in its metadata (SUBTASK-9), not in the
    # header, which shows the chat's own status.
    refute has_element?(view, "#task-result")
    refute has_element?(view, "#task-header", "Made child.txt")
  end

  # UI-48, SESS-19
  test "the task chat's header follows its own status", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{result: nil})

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")
    assert has_element?(view, "#task-header-status[data-status='idle']")

    # UI-48, UI-59: the header reads the same status its own row does, so the
    # chat's own events — its turn running, its turn paused at a limit
    # (SESS-27) — move both.
    activity_send(child, :running)
    assert has_element?(view, "#task-header-status[data-status='working']")
    assert has_element?(view, "#chat-status-#{child}[data-status='working']")

    activity_send(child, :paused)
    assert has_element?(view, "#task-header-status[data-status='paused']")

    activity_send(child, :idle)
    assert has_element?(view, "#task-header-status[data-status='idle']")
  end

  # UI-46, UI-72, INTR-2: a task chat whose turn a restart cut short reads
  # `interrupted` in the list, exactly as any other chat's row does.
  test "a task chat whose turn was cut short is flagged in the sidebar", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{result: nil})

    # The app stopped mid-turn: the chat still carries the turn it was running
    # (STORE-30, STORE-31).
    Store.save(child, [Message.user("preamble")],
      task: Store.load_task(child),
      turn: %{id: "turn-1", started_at: DateTime.utc_now()}
    )

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#chat-status-#{child}[data-status='interrupted']")
  end

  # UI-50 (retired), STORE-16, SUBTASK-34
  test "a saved task status is ignored: the row and the header show the chat's own", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    # A file an earlier version wrote: the task metadata carries a `status`, which
    # `Elia.Store.load_task/1` drops. Its other keys are read as before, so the
    # chat is still this parent's sub-task (SUBTASK-34).
    save_child(child, parent, %{status: "cancelled"})

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{child}", "Add the file")
    refute has_element?(view, "#chat-status-#{child}[data-status='cancelled']")
    assert has_element?(view, "#chat-status-#{child}[data-status='idle']")

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")

    assert has_element?(view, "#task-header")
    refute has_element?(view, "#task-header-status[data-status='cancelled']")
    assert has_element?(view, "#task-header-status[data-status='idle']")
  end

  # UI-48, SESS-20
  test "the task header shows the chat's own status, not its task's result", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{result: nil})

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")
    refute has_element?(view, "#task-result")
    assert has_element?(view, "#task-header-status[data-status='idle']")

    # SUBTASK-33, SESS-18: the result a task ends with (SUBTASK-9) is saved into
    # its metadata and reaches this chat's page. It says nothing about the
    # header's status, which is the chat's own (UI-48).
    task = Store.load_task(child)

    result = %{
      "task_id" => child,
      "summary" => "Need input",
      "commit" => nil,
      "files" => []
    }

    topic_send(child, {:task, Map.put(task, :result, result)})

    assert has_element?(view, "#task-header-brief", "Create child.txt.")
    assert has_element?(view, "#task-header-status[data-status='idle']")
    refute has_element?(view, "#task-header", "Need input")

    # DONE-2, UI-80: marking the chat itself done is what the header shows.
    assert {:ok, true} = Agent.set_done(child, true)
    assert has_element?(view, "#task-header-status[data-status='done']")
  end

  # UI-48
  test "an ordinary chat has no task header", %{conn: conn, parent: parent} do
    save_parent(parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#task-header")
  end

  # UI-57, UI-58: a child paused at a limit, right on first render.
  test "a turn already paused at a limit is shown when the page opens", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{result: nil})

    push_repeating_tool_call(1)

    {:ok, pid} =
      Agent.ensure_started(child,
        loop_opts: [llm: %{provider: FakeLLM}, max_steps: 1, pause_on_limit: true]
      )

    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    # UI-58, SESS-19: the page reads the registry on mount, and that is set
    # between the chat's own status event and the activity one, so this waits
    # for the event the page itself follows.
    Agent.subscribe_activity()
    :ok = Agent.send_message(child, "go")
    assert_receive {:chat_status, ^child, :paused}, 5000

    # UI-58: the sidebar and the parent's card are flagged on first render.
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    assert has_element?(view, "#chat-status-#{child}[data-status='paused'][title='Paused']")
    assert has_element?(view, "#task-card-s1 #task-paused-s1")

    # UI-57: the banner is there on first render too, with both decisions.
    {:ok, child_view, _html} = live(conn, ~p"/c/#{child}")
    assert has_element?(child_view, "#pause-banner")
    assert has_element?(child_view, "#pause-message", "Step limit reached (1 steps).")
    assert has_element?(child_view, "#resume-button")
    assert has_element?(child_view, "#fail-button")

    :ok = Agent.stop(child)
  end

  # UI-57, SESS-27
  test "the pause banner follows the chat's status", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{result: nil})

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")
    refute has_element?(view, "#pause-banner")

    topic_send(child, {:status, :paused})
    topic_send(child, {:paused, "Step limit reached (2 steps)."})

    assert has_element?(view, "#pause-banner")
    assert has_element?(view, "#pause-message", "Step limit reached (2 steps).")

    # The buttons ask the session to continue or fail (SESS-27); a chat that
    # isn't paused refuses both, harmlessly.
    render_click(view, "resume", %{})
    render_click(view, "fail_task", %{})

    topic_send(child, {:status, :running})
    refute has_element?(view, "#pause-banner")
  end

  # UI-58, SESS-19
  test "a paused child is flagged in the sidebar and on the parent's card", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{result: nil})

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#task-paused-s1")
    refute has_element?(view, "#chat-status-#{child}[data-status='paused']")

    # UI-58, SESS-19: the child's own turn paused at a limit, which is a status
    # of its chat — the card and its row both read it.
    activity_send(child, :paused)

    assert has_element?(view, "#task-card-s1 #task-paused-s1")
    assert has_element?(view, "#chat-status-#{child}[data-status='paused'][title='Paused']")

    activity_send(child, :running)
    refute has_element?(view, "#task-paused-s1")
    refute has_element?(view, "#chat-status-#{child}[data-status='paused']")
  end

  # Scripts the model to call a tool that needs no approval `times` times, so
  # only the step limit ends (or pauses) the turn.
  defp push_repeating_tool_call(times) do
    fun = fn _request, _on_event ->
      message = FakeLLM.assistant([FakeLLM.tool_call("c", "read_file", %{"path" => "mix.exs"})])
      {:ok, %{message: message, stop_reason: :tool_use, model: "fake", usage: %{}}}
    end

    for _ <- 1..times, do: FakeLLM.push(fun)
  end
end
