defmodule EliaWeb.CompactViewTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # UI-60: the toggle exists, carries the state and flips it.
  test "the view toggle switches between the full and compact views", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    assert has_element?(view, "#view-toggle[aria-pressed='false'][phx-hook$='ViewToggle']")
    assert has_element?(view, "#view-toggle", "Focus")

    view |> element("#view-toggle") |> render_click()
    assert has_element?(view, "#view-toggle[aria-pressed='true']")

    view |> element("#view-toggle") |> render_click()
    assert has_element?(view, "#view-toggle[aria-pressed='false']")
  end

  # UI-60: the choice stored in the browser is applied when the hook reports it.
  test "a stored compact choice is applied", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/c/#{Agent.new_id()}")

    render_hook(view, "set_compact_view", %{"on" => true})
    assert has_element?(view, "#view-toggle[aria-pressed='true']")
  end

  # UI-61: the compact view keeps the direct messages and hides tool calls,
  # reasoning and the per-item metadata.
  test "the compact view hides tool calls, reasoning and item metadata", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    Elia.Store.save(id, [
      Message.user("please read it"),
      %Message{
        role: :assistant,
        content: [
          %{type: :reasoning, text: "I should read the file"},
          %{type: :tool_call, id: "r1", name: "read_file", input: %{"path" => "notes.txt"}},
          Message.text("All read.")
        ]
      },
      %Message{role: :tool, content: [Message.tool_result("r1", "contents")]}
    ])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # The full view shows everything.
    assert has_element?(view, "#items-call-r1")
    assert has_element?(view, "#transcript .reasoning-text", "I should read the file")
    assert has_element?(view, "#pin-m0")

    view |> element("#view-toggle") |> render_click()

    # The compact view keeps the direct messages...
    assert has_element?(view, "#items-m0", "please read it")
    assert has_element?(view, "#transcript .markdown", "All read.")
    # ...and drops the tool call, the reasoning and the metadata.
    refute has_element?(view, "#items-call-r1")
    refute has_element?(view, "#transcript .reasoning-text")
    refute has_element?(view, "#pin-m0")

    # Switching back restores them.
    view |> element("#view-toggle") |> render_click()
    assert has_element?(view, "#items-call-r1")
    assert has_element?(view, "#pin-m0")
  end

  # UI-62: while a turn runs the compact view names the step, refreshed every
  # second, and cleared when the turn ends.
  test "the compact view summarizes the current step once a second", %{conn: conn} do
    id = Agent.new_id()
    test_pid = self()

    FakeLLM.push(fn _request, on_event ->
      on_event.({:reasoning_delta, "Let me think"})
      send(test_pid, {:streamed, self()})
      receive do: (:finish -> :ok)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("Done.")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # Off by default: no summary line.
    refute has_element?(view, "#work-summary")

    view |> element("#view-toggle") |> render_click()
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "think about it"}) |> render_submit()
    assert_receive {:streamed, llm}, 5000
    _ = :sys.get_state(view.pid)

    # The one-second tick names the step the turn is on.
    send(view.pid, :tick_work_summary)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#work-summary", "Thinking.")

    send(llm, :finish)
    assert_receive {:agent, ^id, {:status, :idle}}, 5000
    refute has_element?(view, "#work-summary")

    # An idle chat is left alone: the tick stops the one-second timer.
    send(view.pid, :tick_work_summary)
    _ = :sys.get_state(view.pid)
    refute :sys.get_state(view.pid).socket.assigns.work_ticking
  end

  # UI-62: a call that waits for approval is named in the summary, which offers
  # a way into the full view, where the buttons are.
  test "the summary points at the waiting approval and offers Review", %{conn: conn} do
    id = Agent.new_id()

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo from-shell"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    view |> element("#view-toggle") |> render_click()
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "say something"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000

    # The compact view hides the card and its buttons...
    refute has_element?(view, "#approve-c1")
    # ...while the summary says what waits and lets the user into the full view.
    assert has_element?(view, "#work-summary", "echo from-shell")
    assert has_element?(view, "#work-summary-review")

    view |> element("#work-summary-review") |> render_click()
    assert has_element?(view, "#approve-c1")

    view |> element("#approve-c1") |> render_click()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000
  end
end
