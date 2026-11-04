defmodule EliaWeb.ChatDoneTest do
  @moduledoc """
  Marking a chat done in the chat page (DONE-2, DONE-4, DONE-5, DONE-9, DONE-10;
  UI-79, UI-80).
  """
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    # SESS-29: deleting the chat stops its session too, so a session that is
    # still running can't save it back after the test (a leaked file would show
    # up in another test's `latest/0`).
    on_exit(fn -> Agent.delete(id) end)
    %{id: id}
  end

  @text "do the thing"

  defp saved(id, opts \\ []), do: Store.save(id, [Message.user(@text)], opts)

  # DONE-4, DONE-5, DONE-2, UI-79, UI-80: the toolbar's control marks the chat
  # done and the sidebar's icon for it follows, without a reload.
  test "marking the chat done from the composer toolbar", %{conn: conn, id: id} do
    :ok = saved(id)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#done-toggle[aria-pressed=false]", "Mark done")
    assert has_element?(view, "#chat-status-#{id}[data-status='idle']")

    view |> element("#done-toggle") |> render_click()

    assert has_element?(view, "#done-toggle[aria-pressed=true]", "Reopen")
    assert has_element?(view, "#chat-status-#{id}[data-status='done'][title='Done']")
    assert Store.load_done(id) == true

    # DONE-4: clicking it again reopens the chat.
    view |> element("#done-toggle") |> render_click()

    assert has_element?(view, "#done-toggle[aria-pressed=false]", "Mark done")
    assert has_element?(view, "#chat-status-#{id}[data-status='idle']")
    assert Store.load_done(id) == false
  end

  # DONE-2, UI-80: a chat saved as done shows it on first render — both in the
  # sidebar and in the page's own control.
  test "a chat saved as done shows it on first render", %{conn: conn, id: id} do
    :ok = saved(id, done: true)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-status-#{id}[data-status='done']")
    assert has_element?(view, "#done-toggle[aria-pressed=true]", "Reopen")
  end

  # DONE-5, SESS-35: the page follows the flag from anywhere, not only from its
  # own control — the model's `mark_done` (DONE-6) and another tab set it the
  # same way.
  test "the page follows a flag set outside it", %{conn: conn, id: id} do
    :ok = saved(id)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert has_element?(view, "#done-toggle[aria-pressed=false]")

    assert {:ok, true} = Agent.set_done(id, true)

    assert has_element?(view, "#done-toggle[aria-pressed=true]")
    assert has_element?(view, "#chat-status-#{id}[data-status='done']")
  end

  # DONE-8, DONE-9, SESS-36: a message continues a done chat as it would an
  # idle one, and the chat is open again from the moment the turn starts.
  test "a message continues a done chat and reopens it", %{conn: conn, id: id} do
    :ok = saved(id, done: true)
    FakeLLM.push(FakeLLM.assistant([Message.text("Carrying on.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert has_element?(view, "#chat-status-#{id}[data-status='done']")

    view |> form("#chat-form", chat: %{text: "one more thing"}) |> render_submit()

    assert has_element?(view, "#done-toggle[aria-pressed=false]", "Mark done")
    refute has_element?(view, "#chat-status-#{id}[data-status='done']")
    assert Store.load_done(id) == false
    assert has_element?(view, "#transcript", "one more thing")
  end

  # DONE-3, UI-79: a task chat's status is its task's (UI-46), so it has no
  # control to mark it done.
  test "a task chat has no done control", %{conn: conn, id: id} do
    task = %{
      parent_id: Agent.new_id(),
      title: "Add the file",
      brief: "Create child.txt.",
      started_at: DateTime.utc_now(),
      status: "done"
    }

    :ok = saved(id, task: task)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#task-header")
    assert has_element?(view, "#chat-status-#{id}[data-status='done']")
    refute has_element?(view, "#done-toggle")
  end
end
