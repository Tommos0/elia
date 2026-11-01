defmodule EliaWeb.CompactionTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.{Compaction, Context, Message}

  setup do
    start_supervised!(FakeLLM)
    :ok
  end

  # The estimate as the indicator renders it (CTX-1).
  defp tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1) |> trim()}M"
  defp tokens(n) when n >= 1000, do: "#{div(n, 1000)}K"
  defp tokens(n), do: "#{n}"

  defp trim(float), do: if(float == Float.round(float), do: trunc(float), else: float)

  # The estimate as the page builds it: the chat's project's skills and
  # instructions over the request view.
  defp estimate(messages) do
    project = Elia.Projects.harness()
    {skills, _errors} = Elia.Skills.for_project(project)
    Context.build(messages, skills, Elia.Skills.project_instructions(project.folder)).total
  end

  # A chat of three turns. The first one is bulky and cold (it ages out of a
  # working set of one turn); the last two are the working set.
  defp chat_messages do
    [
      Message.user("first task: read the notes"),
      %Message{
        role: :assistant,
        content: [
          %{
            type: :reasoning,
            text: "thinking about the notes " <> String.duplicate("ponder ", 4000)
          },
          %{type: :tool_call, id: "r1", name: "read_file", input: %{"path" => "notes.txt"}}
        ]
      },
      %Message{role: :tool, content: [Message.tool_result("r1", "the notes, at length")]},
      %Message{role: :assistant, content: [Message.text("Found the notes.")]},
      Message.user("second task"),
      %Message{role: :assistant, content: [Message.text("Done with the second.")]},
      Message.user("third task"),
      %Message{role: :assistant, content: [Message.text("Done with the third.")]}
    ]
  end

  defp compacted_chat(state \\ %{}) do
    compaction =
      Map.merge(
        %{
          level: 3,
          covered: 4,
          folded: 4,
          summary: "The first turns read notes.txt.",
          options: %{working_set: 1}
        },
        state
      )

    {chat_messages(), compaction}
  end

  # COMPACT-19, COMPACT-25, UI-51, UI-53
  test "the transcript annotates what the model did and did not see", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    {messages, compaction} = compacted_chat()
    :ok = Elia.Store.save(id, messages, compaction: compaction)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # COMPACT-19: the summary is a notice at the boundary of the region it covers.
    assert has_element?(view, "#compaction-summary")
    assert has_element?(view, "#compaction-summary-text", "The first turns read notes.txt.")

    # The full history is still on screen (COMPACT-1): nothing is hidden.
    assert has_element?(view, "#transcript", "Found the notes.")
    assert has_element?(view, "#transcript", "Done with the third.")

    # COMPACT-25: the elided items say so. The first turn's reasoning block, its
    # tool card and its answer are not sent; the working set is untouched.
    assert has_element?(view, "#status-m1-0", "Summarized for the model")
    assert has_element?(view, "#status-call-r1", "Summarized for the model")
    assert has_element?(view, "#status-m3-0", "Summarized for the model")
    refute has_element?(view, "#status-m5-0")
  end

  # COMPACT-25, UI-51: the summary covers what was dropped, and says so.
  test "dropped turns covered by a summary are marked summarized", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    {messages, compaction} = compacted_chat(%{summary: "ok"})
    :ok = Elia.Store.save(id, messages, compaction: compaction)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#compaction-summary")
    assert has_element?(view, "#status-m1-0", "Summarized for the model")
  end

  # COMPACT-25, UI-51: without a summary the dropped items are plain "not sent".
  test "dropped turns with no summary are marked as not sent", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    {messages, compaction} = compacted_chat(%{summary: nil, folded: 0})
    :ok = Elia.Store.save(id, messages, compaction: compaction)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    refute has_element?(view, "#compaction-summary")
    assert has_element?(view, "#status-m1-0", "Not sent to the model")
  end

  # COMPACT-14, COMPACT-15, COMPACT-25, UI-51
  test "an elided tool result and a dropped reasoning block are marked", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    {messages, compaction} = compacted_chat(%{level: 2, covered: 4, folded: 0, summary: nil})
    :ok = Elia.Store.save(id, messages, compaction: compaction)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#status-call-r1", "Not sent to the model")
    assert has_element?(view, "#status-m1-0", "Not sent to the model")
    # The output itself is still readable in the transcript (UI-20).
    assert has_element?(view, "#items-call-r1 details summary", "Output")
  end

  # COMPACT-26, CTX-11
  test "the estimate is over the request view and shows the elided amount", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    {messages, compaction} = compacted_chat()
    :ok = Elia.Store.save(id, messages, compaction: compaction)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    state = Compaction.from_map(compaction)
    view_messages = Compaction.view(messages, state).messages
    elided = Compaction.view(messages, state).elided

    # The two figures are distinguishable, so the assertion means something.
    assert tokens(estimate(view_messages)) != tokens(estimate(messages))

    # The total is the estimate of the request view, not of the full history.
    size = view |> element("#context-size") |> render()
    assert size =~ tokens(estimate(view_messages))
    refute size =~ tokens(estimate(messages))

    view |> element("#context-indicator") |> render_click()

    assert has_element?(view, "#context-elided", "−#{tokens(elided)}")
    assert view |> element("#context-elided-badge") |> render() =~ "#{tokens(elided)}"
  end

  # COMPACT-27
  test "a changed request view resets the provider adjustment", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    {messages, compaction} = compacted_chat()
    :ok = Elia.Store.save(id, messages, compaction: compaction)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    send(
      view.pid,
      {:agent, id, {:usage, %{"input_tokens" => 90_000, "estimated_input_tokens" => 10}}}
    )

    _ = :sys.get_state(view.pid)
    view |> element("#context-indicator") |> render_click()
    assert has_element?(view, "#context-breakdown", "Provider adjustment")

    # The request view changed, so the figure that calibrated the old one goes.
    send(view.pid, {:agent, id, {:compaction, compaction}})
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#context-breakdown", "Provider adjustment")
  end

  # COMPACT-10, COMPACT-25, UI-54
  test "compact now compacts the chat and the transcript says so", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    messages =
      Enum.flat_map(1..8, fn n ->
        [
          Message.user("turn #{n} asks something"),
          %Message{
            role: :assistant,
            content: [Message.text("an answer for turn #{n} " <> String.duplicate("word ", 40))]
          }
        ]
      end)

    :ok = Elia.Store.save(id, messages)
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    refute has_element?(view, "#status-m1-0", "Not sent")
    assert has_element?(view, "#compact-button")

    view |> element("#compact-button") |> render_click()
    _ = :sys.get_state(view.pid)

    # The cold turns are dropped and the transcript says so (COMPACT-16, COMPACT-25).
    assert has_element?(view, "#status-m1-0", "Not sent to the model")
    assert has_element?(view, "#transcript", "an answer for turn 1")
  end

  # COMPACT-21, COMPACT-25, UI-52
  test "the user pins a message from the transcript", %{conn: conn} do
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    :ok = Elia.Store.save(id, chat_messages())

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#pin-m0[aria-pressed='false']", "Pin")
    view |> element("#pin-m0") |> render_click()
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pin-m0[aria-pressed='true']", "Pinned")
    assert [{0, nil}] = Agent.snapshot(id).compaction.pins

    view |> element("#pin-m0") |> render_click()
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#pin-m0[aria-pressed='false']")
    assert [] = Agent.snapshot(id).compaction.pins
  end
end
