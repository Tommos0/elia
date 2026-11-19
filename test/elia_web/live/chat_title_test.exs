defmodule EliaWeb.ChatTitleTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    %{id: id}
  end

  @first "Chat titles. I would like some mechanism to set short one sentence titles"

  # UI-74, UI-3, TITLE-1: the chat's own title is the page title and its row in
  # the list, and the row still hovers with what was asked (UI-33, STORE-10).
  test "a chat's own title is its page title and its row in the list", %{conn: conn, id: id} do
    :ok = Store.save(id, [Message.user(@first)], title: "Chat titles")

    {:ok, view, html} = live(conn, ~p"/c/#{id}")

    assert html =~ "Elia - Chat titles</title>"
    assert page_title(view) == "Elia - Chat titles"
    assert has_element?(view, "#chat-link-#{id}", "Chat titles")
    assert has_element?(view, "#chat-link-#{id}[title='#{@first}']")
  end

  # UI-74, TITLE-4, SESS-33: naming the chat updates the open page and its row
  # at once, without waiting for the turn to end (UI-6).
  test "the page title and the row follow the title as it is set", %{conn: conn, id: id} do
    :ok = Store.save(id, [Message.user(@first)])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert page_title(view) == "Elia - " <> String.slice(@first, 0, 60)

    assert {:ok, "Chat titles"} = Agent.set_title(id, "Chat titles")

    # The row follows at once: requiring the element waits for the page to take
    # the event. A title set live arrives as the assign (the layout's "Elia - "
    # prefix is added by the client), where the first render carries the whole
    # <head>.
    assert has_element?(view, "#chat-link-#{id}", "Chat titles")
    assert page_title(view) == "Chat titles"
  end

  # UI-74, TITLE-5: naming the chat reads as its own one-line summary, as a
  # spawn_task call does (UI-43), rather than as raw JSON (UI-15).
  test "the set_title card shows the title, not raw JSON", %{conn: conn, id: id} do
    :ok =
      Store.save(id, [
        Message.user("name this chat"),
        FakeLLM.assistant([FakeLLM.tool_call("t1", "set_title", %{"title" => "Chat titles"})])
      ])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#transcript", "set_title")
    assert has_element?(view, "#transcript", "Chat titles")
    refute has_element?(view, "#transcript", "\"title\":")
  end

  # TITLE-5: naming a chat has no effect on the machine, so it never needs
  # approval and is not a tool the approval popover offers (APPR-13, UI-39).
  test "the auto-approve popover doesn't offer set_title", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}/settings")

    view |> element("#auto-approve-button") |> render_click()

    assert has_element?(view, "#auto-approve-shell")
    refute has_element?(view, "#auto-approve-set_title")
  end

  # UI-96, TITLE-1: the chat page carries the chat's title in a row of its own,
  # above the context indicator (CTX-1) and below the app header.
  test "the chat page shows the title above the context indicator", %{conn: conn, id: id} do
    :ok = Store.save(id, [Message.user(@first)], title: "Chat titles")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-title", "Chat titles")
    assert has_element?(view, "#chat-title[title='Chat titles']")

    html = render(view)
    {title_at, _} = :binary.match(html, ~s(id="chat-title"))
    {indicator_at, _} = :binary.match(html, ~s(id="context-indicator"))
    assert title_at < indicator_at
  end

  # UI-96: a chat with no title of its own shows the STORE-7 derivation, and the
  # row follows the chat being named mid-turn (TITLE-4).
  test "the title row shows the derived title and follows a new one", %{conn: conn, id: id} do
    :ok = Store.save(id, [Message.user(@first)])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-title", String.slice(@first, 0, 60))

    assert {:ok, "Chat titles"} = Agent.set_title(id, "Chat titles")
    assert has_element?(view, "#chat-title", "Chat titles")
  end

  # UI-96, TITLE-3: in a sub-task chat the title row sits below the task header
  # (UI-48), and it is the chat's own title the spawn gave it.
  test "a sub-task chat's title row is below its task header", %{conn: conn, id: id} do
    parent = Agent.new_id()
    on_exit(fn -> Store.delete(parent) end)
    :ok = Store.save(parent, [Message.user("do the thing")])

    :ok =
      Store.save(id, [Message.user("on it")],
        task: %{parent_id: parent, started_at: DateTime.utc_now()},
        title: "A sub-task"
      )

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-title", "A sub-task")

    html = render(view)
    {task_at, _} = :binary.match(html, ~s(id="task-header"))
    {title_at, _} = :binary.match(html, ~s(id="chat-title"))
    assert task_at < title_at
  end
end
