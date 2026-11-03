defmodule EliaWeb.AutoApproveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    %{id: id}
  end

  defp open_popover(view), do: view |> element("#auto-approve-button") |> render_click()

  defp settings(conn, id), do: live(conn, ~p"/c/#{id}/settings")

  # UI-38, CSET-5
  test "the chat settings page has an auto-approve button that opens and closes a popover", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(
             view,
             "#settings-auto-approve #auto-approve-button[aria-expanded='false']"
           )

    refute has_element?(view, "#auto-approve-count")
    refute has_element?(view, "#auto-approve")

    open_popover(view)
    assert has_element?(view, "#auto-approve-button[aria-expanded='true']")
    assert has_element?(view, "#auto-approve")

    view |> element("#auto-approve") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#auto-approve")

    open_popover(view)
    render_click(view, "close_auto_approve_picker", %{})
    refute has_element?(view, "#auto-approve")

    open_popover(view)
    open_popover(view)
    refute has_element?(view, "#auto-approve")
  end

  # UI-39, APPR-13
  test "the popover lists only tools that can need approval", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)
    open_popover(view)

    for tool <- ~w(shell read_file write_file edit_file) do
      assert has_element?(view, "#auto-approve-#{tool}[role='switch'][aria-checked='false']")
    end

    for tool <- ~w(run_tests reload_skills) do
      refute has_element?(view, "#auto-approve-#{tool}")
    end

    assert has_element?(view, "#auto-approve", "without asking")
  end

  # UI-38, UI-39, APPR-8
  test "switching a tool on and off updates the switch and the count", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)
    open_popover(view)

    view |> element("#auto-approve-shell") |> render_click()
    assert has_element?(view, "#auto-approve-shell[aria-checked='true']")
    assert has_element?(view, "#auto-approve-write_file[aria-checked='false']")
    assert has_element?(view, "#auto-approve-count", "1")
    assert %{auto_approve: ["shell"]} = Agent.snapshot(id)

    view |> element("#auto-approve-write_file") |> render_click()
    assert has_element?(view, "#auto-approve-count", "2")

    view |> element("#auto-approve-shell") |> render_click()
    view |> element("#auto-approve-write_file") |> render_click()
    assert has_element?(view, "#auto-approve-shell[aria-checked='false']")
    refute has_element?(view, "#auto-approve-count")
    assert %{auto_approve: []} = Agent.snapshot(id)
  end

  # UI-39, SESS-16, CSET-3: a switch moved on one view of the chat (its settings
  # page, here in two tabs) shows up on the other.
  test "every view of the chat follows the switch", %{conn: conn, id: id} do
    {:ok, first, _} = settings(conn, id)
    {:ok, second, _} = settings(conn, id)
    open_popover(first)
    open_popover(second)

    first |> element("#auto-approve-shell") |> render_click()

    assert has_element?(first, "#auto-approve-shell[aria-checked='true']")
    # Rendering the second view waits for the broadcast to be handled.
    render(second)
    assert has_element?(second, "#auto-approve-shell[aria-checked='true']")
    assert has_element?(second, "#auto-approve-count", "1")
  end

  # UI-38, APPR-12
  test "a chat that already auto-approves tools shows them when opened", %{conn: conn, id: id} do
    :ok = Elia.Store.save(id, [Message.user("hi")], auto_approve: ["edit_file"])

    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#auto-approve-count", "1")

    open_popover(view)
    assert has_element?(view, "#auto-approve-edit_file[aria-checked='true']")
    assert has_element?(view, "#auto-approve-shell[aria-checked='false']")
  end

  # CSET-4, APPR-8: auto-approval set on the settings page applies to the chat.
  test "an auto-approved call shows no approval buttons and runs", %{conn: conn, id: id} do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))
    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

    {:ok, chat, _html} = live(conn, ~p"/c/#{id}")
    {:ok, view, _html} = settings(conn, id)
    Agent.subscribe(id)
    open_popover(view)
    view |> element("#auto-approve-shell") |> render_click()

    chat |> form("#chat-form", chat: %{text: "go"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    html = render(chat)
    assert html =~ "All done."
    refute_received {:agent, ^id, {:status, :awaiting_approval}}
    refute has_element?(chat, "#approve-c1")
    refute has_element?(chat, "#always-allow-c1")
  end

  # UI-42
  test "each switch says On or Off in text", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)
    open_popover(view)
    assert has_element?(view, "#auto-approve-state-shell", "Off")

    view |> element("#auto-approve-shell") |> render_click()
    assert has_element?(view, "#auto-approve-state-shell", "On")
    assert has_element?(view, "#auto-approve-state-write_file", "Off")

    view |> element("#auto-approve-shell") |> render_click()
    assert has_element?(view, "#auto-approve-state-shell", "Off")
  end

  # UI-40, APPR-11
  test "Always allow approves the call and later calls of the tool", %{conn: conn, id: id} do
    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo one"})])
    )

    FakeLLM.push(
      FakeLLM.assistant([FakeLLM.tool_call("c2", "shell", %{"command" => "echo two"})])
    )

    FakeLLM.push(FakeLLM.assistant([Message.text("All done.")]))

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    {:ok, settings, _html} = settings(conn, id)
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "go"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000
    assert has_element?(view, "#approve-c1")
    assert has_element?(view, "#always-allow-c1")

    view |> element("#always-allow-c1") |> render_click()
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    html = render(view)
    assert html =~ "All done."
    # c2 was approved automatically, so it never asked.
    refute_received {:agent, ^id, {:tool_status, "c2", :awaiting_approval}}

    # The settings page shows it, without a reload.
    render(settings)
    assert has_element?(settings, "#auto-approve-count", "1")

    open_popover(settings)
    assert has_element?(settings, "#auto-approve-shell[aria-checked='true']")
  end
end
