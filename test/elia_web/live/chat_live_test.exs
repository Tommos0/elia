defmodule EliaWeb.ChatLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  test "/ redirects to a fresh chat", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/c/" <> _id}}} = live(conn, ~p"/")
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

  test "approvals for guarded files are flagged", %{conn: conn} do
    id = Agent.new_id()
    edit = %{"old_string" => "a", "new_string" => "b"}

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("g1", "edit_file", Map.put(edit, "path", "lib/elia/harness.ex")),
        FakeLLM.tool_call("g2", "edit_file", Map.put(edit, "path", "lib/elia/agent.ex"))
      ])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("Okay.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "edit things"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000
    assert has_element?(view, "#guarded-g1")
    refute has_element?(view, "#guarded-g2")

    view |> element("#deny-g1") |> render_click()
    view |> element("#deny-g2") |> render_click()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000
    refute has_element?(view, "#guarded-g1")
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
end
