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
end
