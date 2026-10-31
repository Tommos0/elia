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

  defp save_child(child, parent, overrides \\ %{}) do
    on_exit(fn -> Store.delete(child) end)

    task =
      Map.merge(
        %{
          parent_id: parent,
          parent_call_id: "s1",
          title: "Add the file",
          brief: "Create child.txt.\nCommit it.",
          started_at: DateTime.utc_now(),
          status: "done",
          start_commit: "abc",
          result: %{
            "status" => "done",
            "summary" => "Made child.txt",
            "commit" => "0123456789abcdef",
            "files" => ["child.txt"],
            "questions" => ["Rename it?"]
          }
        },
        overrides
      )

    Store.save(child, [Message.user("preamble")], task: task)
  end

  defp topic_send(id, event),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.topic(id), {:agent, id, event})

  defp activity_send(id, status),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})

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
  test "the card links to the child and shows its status after a reload", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent)

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#task-card-s1")
    assert has_element?(view, "#task-link-s1[href='/c/#{child}']")
    assert has_element?(view, "#task-status-s1[data-status='done']")
  end

  # UI-44, SUBTASK-7
  test "the card follows subtask events and flags a child waiting for approval", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#task-card-s1")

    topic_send(parent, {:subtask, "s1", child, "running"})
    assert has_element?(view, "#task-link-s1[href='/c/#{child}']")
    assert has_element?(view, "#task-status-s1[data-status='running']")
    refute has_element?(view, "#task-awaiting-s1")

    activity_send(child, :awaiting_approval)
    assert has_element?(view, "#task-awaiting-s1")

    activity_send(child, :running)
    refute has_element?(view, "#task-awaiting-s1")

    topic_send(parent, {:subtask, "s1", child, "failed"})
    assert has_element?(view, "#task-status-s1[data-status='failed']")
  end

  # UI-45, UI-46
  test "the sidebar nests task chats under their parent with a status icon", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    orphan = Agent.new_id()
    lost = Agent.new_id()
    on_exit(fn -> Enum.each([orphan, lost], &Store.delete/1) end)

    save_parent(parent)
    save_child(child, parent, %{title: "Nested task"})
    save_child(lost, parent, %{title: "Lost task", status: "running", parent_call_id: "s2"})
    save_child(orphan, "parent-not-listed", %{title: "Orphan task", status: "failed"})

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")

    assert has_element?(view, "#chat-list > #chat-link-#{parent}")
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{child}", "Nested task")
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{lost}", "Lost task")
    # Oldest first.
    html = render(view)
    [before_lost, _] = String.split(html, "id=\"chat-link-#{lost}\"")
    assert before_lost =~ "id=\"chat-link-#{child}\""

    # An orphan stays at the top level.
    assert has_element?(view, "#chat-list > #chat-link-#{orphan}", "Orphan task")
    refute has_element?(view, "#chat-children-#{parent} #chat-link-#{orphan}")
    # Ordinary chats have no status icon.
    refute has_element?(view, "#chat-task-status-#{parent}")

    assert has_element?(view, "#chat-task-status-#{child}[data-status='done']")
    assert has_element?(view, "#chat-task-status-#{lost}[data-status='interrupted']")
    assert has_element?(view, "#chat-task-status-#{orphan}[data-status='failed']")
  end

  # UI-47, SESS-19
  test "a chat awaiting approval is badged in the sidebar, live", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#chat-approval-#{child}")

    activity_send(child, :awaiting_approval)

    assert has_element?(
             view,
             "#chat-link-#{child} #chat-approval-#{child}[title='Needs approval']"
           )

    refute has_element?(view, "#chat-approval-#{parent}")

    activity_send(child, :idle)
    refute has_element?(view, "#chat-approval-#{child}")
  end

  # UI-47: right on first render
  test "a chat that is already awaiting approval is badged when the page opens", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    Agent.subscribe(child)

    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))
    {:ok, _pid} = Agent.ensure_started(child, loop_opts: [llm: %{provider: FakeLLM}])
    :ok = Agent.send_message(child, "run it")
    assert_receive {:agent, ^child, {:status, :awaiting_approval}}, 5000

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    assert has_element?(view, "#chat-approval-#{child}")

    :ok = Agent.deny(child, "c1")
    assert_receive {:agent, ^child, {:status, :idle}}, 5000
    _ = render(view)
    refute has_element?(view, "#chat-approval-#{child}")
  end

  # UI-48
  test "a task chat shows who it belongs to, its brief and its result", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent)

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")

    assert has_element?(view, "#task-header")
    assert has_element?(view, "#task-parent-link[href='/c/#{parent}']", "delegate this")
    assert has_element?(view, "#task-header-status[data-status='done']")
    assert has_element?(view, "#task-header-brief", "Create child.txt.")
    assert has_element?(view, "#task-result", "Made child.txt")
    assert has_element?(view, "#task-result", "01234567")
    refute has_element?(view, "#task-result", "0123456789")
    assert has_element?(view, "#task-result", "child.txt")
    assert has_element?(view, "#task-result", "Rename it?")
  end

  # UI-48
  test "a task chat without a result yet shows no result, and a lost one is interrupted", %{
    conn: conn,
    parent: parent,
    child: child
  } do
    save_parent(parent)
    save_child(child, parent, %{status: "running", result: nil})

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")

    assert has_element?(view, "#task-header-status[data-status='interrupted']")
    refute has_element?(view, "#task-result")
  end

  # UI-48, SESS-20
  test "the task header follows task events", %{conn: conn, parent: parent, child: child} do
    save_parent(parent)
    save_child(child, parent, %{status: "done", result: nil})

    {:ok, view, _html} = live(conn, ~p"/c/#{child}")
    refute has_element?(view, "#task-result")

    task = Store.load_task(child)
    result = %{"status" => "blocked", "summary" => "Need input", "files" => [], "questions" => []}
    topic_send(child, {:task, %{task | status: "blocked", result: result}})

    assert has_element?(view, "#task-header-status[data-status='blocked']")
    assert has_element?(view, "#task-result", "Need input")
  end

  # UI-48
  test "an ordinary chat has no task header", %{conn: conn, parent: parent} do
    save_parent(parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#task-header")
  end

  # UI-49
  test "the sidebar refreshes when a task starts", %{conn: conn, parent: parent, child: child} do
    save_parent(parent)
    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    refute has_element?(view, "#chat-link-#{child}")

    save_child(child, parent, %{status: "running", result: nil})
    topic_send(parent, {:subtask, "s1", child, "running"})
    assert has_element?(view, "#chat-children-#{parent} #chat-link-#{child}")
  end
end
