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

  # DONE-4, UI-79, UI-97: the done control is one entry of the composer
  # toolbar's chat menu, so the menu is opened before it is used.
  defp open_menu(view), do: view |> element("#chat-menu-button") |> render_click()

  # DONE-4, DONE-5, DONE-2, UI-79, UI-80: the menu's control marks the chat done
  # and the sidebar's icon for it follows, without a reload.
  test "marking the chat done from the composer toolbar", %{conn: conn, id: id} do
    :ok = saved(id)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    open_menu(view)

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
    open_menu(view)

    assert has_element?(view, "#chat-status-#{id}[data-status='done']")
    assert has_element?(view, "#done-toggle[aria-pressed=true]", "Reopen")
  end

  # DONE-5, SESS-35: the page follows the flag from anywhere, not only from its
  # own control — the model's `mark_done` (DONE-6) and another tab set it the
  # same way.
  test "the page follows a flag set outside it", %{conn: conn, id: id} do
    :ok = saved(id)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    open_menu(view)
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
    open_menu(view)
    assert has_element?(view, "#chat-status-#{id}[data-status='done']")

    view |> form("#chat-form", chat: %{text: "one more thing"}) |> render_submit()

    assert has_element?(view, "#done-toggle[aria-pressed=false]", "Mark done")
    refute has_element?(view, "#chat-status-#{id}[data-status='done']")
    assert Store.load_done(id) == false
    assert has_element?(view, "#transcript", "one more thing")
  end

  # DONE-3, DONE-4, UI-46, UI-79: a task chat has the same control as any other
  # chat, and using it is the chat's own bookkeeping — its task header keeps
  # saying what the task did.
  test "a task chat has the done control too", %{conn: conn, id: id} do
    task = %{parent_id: Agent.new_id(), started_at: DateTime.utc_now()}

    :ok = saved(id, task: task, title: "Add the file")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    open_menu(view)

    # UI-46, UI-48, DONE-2: a task chat's status is its own chat's — `idle` until
    # it is marked done — in the row and in the header alike.
    assert has_element?(view, "#task-header")
    assert has_element?(view, "#task-header-status[data-status='idle']")
    assert has_element?(view, "#chat-status-#{id}[data-status='idle']")
    assert has_element?(view, "#done-toggle[aria-pressed=false]", "Mark done")

    view |> element("#done-toggle") |> render_click()

    assert has_element?(view, "#done-toggle[aria-pressed=true]", "Reopen")
    assert has_element?(view, "#chat-status-#{id}[data-status='done'][title='Done']")
    assert Store.load_done(id) == true
    # UI-48: and the header follows it, since it is the same status.
    assert has_element?(view, "#task-header-status[data-status='done']")

    # DONE-4: clicking it again reopens the chat, and its status is back.
    view |> element("#done-toggle") |> render_click()

    assert has_element?(view, "#done-toggle[aria-pressed=false]", "Mark done")
    assert has_element?(view, "#chat-status-#{id}[data-status='idle']")
    assert Store.load_done(id) == false
    # DONE-3, STORE-16, SUBTASK-33: nothing about the task changes but the result
    # its end saved (SUBTASK-9, SUBTASK-13), and it carries no status for the
    # flag to touch. Its title is its chat's own (STORE-32, TITLE-3).
    assert %{parent_id: parent_id, started_at: started_at, result: result} =
             Store.load_task(id)

    assert parent_id == task.parent_id
    assert started_at == task.started_at
    assert %{"task_id" => ^id, "summary" => _summary} = result
    refute Map.has_key?(Store.load_task(id), :status)
    assert Elia.Store.chat_title(id) == "Add the file"
  end
end
