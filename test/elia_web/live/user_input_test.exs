defmodule EliaWeb.UserInputTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    Agent.subscribe(id)
    on_exit(fn -> Store.delete(id) end)
    %{id: id}
  end

  # ASK-2, SESS-7: a question is a tool call in the history, so a chat reopened
  # later shows it.
  defp save_question(id, input \\ nil) do
    input = input || %{"question" => "Which jail?", "options" => ["Jailed", "Not jailed"]}

    Store.save(id, [
      Message.user("set it up"),
      FakeLLM.assistant([FakeLLM.tool_call("q1", "ask_user", input)])
    ])
  end

  defp topic_send(id, event),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.topic(id), {:agent, id, event})

  defp activity_send(id, status),
    do: Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})

  defp ask_question(_id, input \\ nil) do
    input = input || %{"question" => "Which jail?", "options" => ["Jailed", "Not jailed"]}
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("q1", "ask_user", input)]))
    :ok
  end

  # UI-75: the card is the question, and its options become buttons while the
  # call waits for the answer.
  test "the question card shows the question and its options", %{conn: conn, id: id} do
    save_question(id)
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#transcript", "Which jail?")
    # UI-75: the question, not the raw input.
    refute has_element?(view, "#transcript", "\"options\"")
    # Not put to the user (yet): no buttons, no field.
    refute has_element?(view, "#answer-q1")

    topic_send(id, {:tool_status, "q1", :awaiting_input})

    assert has_element?(view, "#answer-q1-0", "Jailed")
    assert has_element?(view, "#answer-q1-1", "Not jailed")
    assert has_element?(view, "#answer-text-q1")
    assert has_element?(view, "#transcript", "Needs your answer")

    # ASK-3, UI-16: once answered, the badge says so and the buttons are gone.
    topic_send(id, {:tool_status, "q1", :answered})

    assert has_element?(view, "#transcript", "Answered")
    refute has_element?(view, "#answer-q1-0")
  end

  # UI-75, ASK-4, ASK-6
  test "clicking an option answers the question", %{conn: conn, id: id} do
    ask_question(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("Jailed it is.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    view |> form("#chat-form", chat: %{text: "ask me"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_input}}, 5000
    assert has_element?(view, "#answer-q1-1", "Not jailed")

    view |> element("#answer-q1-1") |> render_click()

    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    # ASK-5, UI-20: the answer the model was given stays visible.
    assert has_element?(view, "#output-q1", "Not jailed")
    assert has_element?(view, "#transcript", "Jailed it is.")
    refute has_element?(view, "#answer-q1-1")
  end

  # ASK-4, UI-75
  test "the text field answers the question in the user's own words", %{conn: conn, id: id} do
    ask_question(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("Right.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    view |> form("#chat-form", chat: %{text: "ask me"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_input}}, 5000

    view |> form("#answer-form-q1", answer: "Neither, use the sandbox") |> render_submit()

    assert_receive {:agent, ^id, {:status, :idle}}, 5000
    assert has_element?(view, "#output-q1", "Neither, use the sandbox")
  end

  # UI-76, UI-59, ASK-10: a chat waiting for an answer says so, and is never
  # shown as idle.
  test "the sidebar shows a chat that is waiting for an answer", %{conn: conn, id: id} do
    other = Agent.new_id()
    on_exit(fn -> Store.delete(other) end)

    ask_question(other)
    {:ok, _pid} = Agent.ensure_started(other)
    Agent.subscribe(other)
    :ok = Agent.send_message(other, "ask")
    assert_receive {:agent, ^other, {:status, :awaiting_input}}, 5000

    # Right on first render, from `Agent.awaiting_input/0`.
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert has_element?(view, "#chat-status-#{other}[data-status='awaiting_input']")
    assert has_element?(view, "#chat-status-#{other}[title='Needs your answer']")

    # And it follows the status live.
    activity_send(other, :idle)
    assert has_element?(view, "#chat-status-#{other}[data-status='idle']")
  end

  # ASK-9, UI-44: a parent's card says its child is waiting for an answer.
  test "a parent's task card says the child is waiting for an answer", %{conn: conn} do
    parent = Agent.new_id()
    child = Agent.new_id()
    on_exit(fn -> Enum.each([parent, child], &Store.delete/1) end)

    Store.save(parent, [
      Message.user("delegate this"),
      FakeLLM.assistant([
        FakeLLM.tool_call("s1", "spawn_task", %{"title" => "Add the file", "brief" => "Do it."})
      ])
    ])

    Store.save(child, [Message.user("go")],
      task: %{
        parent_id: parent,
        parent_call_id: "s1",
        title: "Add the file",
        brief: "Do it.",
        started_at: DateTime.utc_now(),
        status: "running"
      }
    )

    {:ok, view, _html} = live(conn, ~p"/c/#{parent}")
    assert has_element?(view, "#task-card-s1")
    refute has_element?(view, "#task-input-s1")

    activity_send(child, :awaiting_input)

    assert has_element?(view, "#task-input-s1", "Waiting for your answer in the task chat")
    assert has_element?(view, "#task-status-s1")
  end

  # ASK-10, UI-61, UI-62
  test "the compact view keeps the card and names the wait", %{conn: conn, id: id} do
    ask_question(id)
    FakeLLM.push(FakeLLM.assistant([Message.text("Ok.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    view |> element("#view-toggle") |> render_click()

    view |> form("#chat-form", chat: %{text: "ask me"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_input}}, 5000

    # The question card is addressed to the user, so the compact view keeps it.
    assert has_element?(view, "#answer-q1-0")
    assert has_element?(view, "#work-summary", "Waiting for your answer.")

    # ... and offers the way back to the full view.
    view |> element("#work-summary-review") |> render_click()
    assert has_element?(view, "#answer-q1-0")
  end
end
