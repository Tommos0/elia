defmodule EliaWeb.ChatMessageTimeTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  # MSGAT-5 to MSGAT-7: the transcript shows when each item was added, in
  # relative form, and keeps the text in step with the clock.
  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  defp stamped(message, minutes_ago) do
    at = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)
    %{message | meta: Map.put(message.meta, :at, at)}
  end

  defp saved(messages) do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, messages)
    id
  end

  # MSGAT-5, MSGAT-7: every item that came from a message carries the moment it
  # arrived — the user's own message, the reply, its reasoning and the tool card
  # — in a `<time>` whose datetime is the stamp and whose title is the exact
  # moment (UI-34's wording).
  test "each item shows when it was added, in relative form", %{conn: conn} do
    assistant =
      stamped(
        %Message{
          role: :assistant,
          content: [
            %{type: :reasoning, text: "Thinking about it."},
            Message.text("Hello!"),
            %{type: :tool_call, id: "c1", name: "shell", input: %{"command" => "echo hi"}}
          ]
        },
        11
      )

    messages = [
      stamped(Message.user("hi"), 12),
      assistant,
      stamped(%Message{role: :tool, content: [Message.tool_result("c1", "hi")]}, 10)
    ]

    {:ok, view, _html} = live(conn, ~p"/c/#{saved(messages)}")

    assert has_element?(view, "#at-m0", "12 minutes ago")
    assert has_element?(view, "#at-m1-0", "11 minutes ago")
    assert has_element?(view, "#at-m1-1", "11 minutes ago")
    assert has_element?(view, "#at-call-c1", "11 minutes ago")

    at = Message.at(List.first(messages))
    assert has_element?(view, "#at-m0[datetime='#{DateTime.to_iso8601(at)}']")
    assert has_element?(view, "#at-m0[title='#{Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")}']")
  end

  # MSGAT-7: a harness message that reads as a notice carries its moment too.
  test "a notice item shows when it arrived", %{conn: conn} do
    id = saved([stamped(Message.user("go"), 6), stamped(Message.harness("Stopped."), 5)])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#at-m1", "5 minutes ago")
  end

  # MSGAT-7: an item the page shows only while a turn runs — the wait before a
  # retried model call (RETRY-3, UI-86) — is stamped when it is shown.
  test "a notice shown while the turn runs carries the moment it was shown", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    # RETRY-4: a wait short enough for a test.
    {:ok, pid} = Agent.ensure_started(id, loop_opts: [step_retry: [delays_ms: [300]]])
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    FakeLLM.push(fn _request, _on_event ->
      {:error, Elia.LLM.Error.transient("Anthropic API request failed: timeout")}
    end)

    FakeLLM.push(FakeLLM.assistant([Message.text("A whole answer.")]))

    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:retry, _info}}, 5000

    assert has_element?(view, "time[id^='at-notice-']", "just now")
  end

  # MSGAT-7: an item a chat saved before stamps existed carries no time, and
  # the item itself is there as before.
  test "an item a chat saved before stamps shows no time", %{conn: conn} do
    id = saved([Message.user("hi")])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#items-m0", "hi")
    refute has_element?(view, "#at-m0")
  end

  # MSGAT-6: an item whose relative text has moved on is rendered again by the
  # page's own tick, with no reload and no action by the user.
  test "the relative text keeps up with the clock", %{conn: conn} do
    id = saved([stamped(Message.user("hi"), 0)])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert has_element?(view, "#at-m0", "just now")

    # Age the item, and the moment the page last rendered with it, without
    # rendering either — then let the page's tick render them (UI-34).
    :sys.replace_state(view.pid, fn state ->
      ago = DateTime.add(state.socket.assigns.now, -3600, :second)

      state
      |> put_in([Access.key(:socket), Access.key(:assigns), :now], ago)
      |> update_in([Access.key(:socket), Access.key(:assigns), :timed_items], fn items ->
        Map.new(items, fn {id, item} -> {id, %{item | at: ago}} end)
      end)
    end)

    send(view.pid, :tick_now)
    assert has_element?(view, "#at-m0", "1 hour ago")
  end
end
