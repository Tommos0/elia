defmodule EliaWeb.PushVisibilityTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Elia.LLMCase
  import Elia.PushCase

  alias Elia.{Agent, Push, Store}

  setup do
    reset_settings()
    configure(Push)
    stub_push_service()
    on_exit(&reset_push/0)
    :ok
  end

  # PUSH-14
  test "a chat page reports whether it is visible", %{conn: conn} do
    id = start_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-shell")

    render_hook(view, "visibility", %{"visible" => true})
    assert Push.Viewers.visible?(id)

    # A page in a background tab, or one that is hidden, is not a page in front
    # of the user (PUSH-13).
    render_hook(view, "visibility", %{"visible" => false})
    refute Push.Viewers.visible?(id)
  end

  # PUSH-14
  test "a page that goes away stops counting", %{conn: conn} do
    id = start_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    render_hook(view, "visibility", %{"visible" => true})
    assert Push.Viewers.visible?(id)

    GenServer.stop(view.pid)
    _ = :sys.get_state(Push.Viewers)

    refute Push.Viewers.visible?(id)
  end

  # PUSH-13
  test "a chat the user is reading is not notified, and a hidden page does not protect it", %{
    conn: conn
  } do
    receiver = store()
    id = start_chat()
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    render_hook(view, "visibility", %{"visible" => true})
    broadcast(id, :awaiting_approval)
    refute_receive {:push_request, _path, _headers, _body}, 200

    render_hook(view, "visibility", %{"visible" => false})
    broadcast(id, :running)
    broadcast(id, :idle)

    assert_receive {:push_request, "/sub/1", _headers, body}, 2_000
    assert decoded_payload(body, receiver)["url"] == "/c/" <> id
  end

  defp start_chat do
    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    :ok = Store.save(id, [])
    id
  end

  defp broadcast(id, status) do
    Phoenix.PubSub.broadcast(Elia.PubSub, Agent.activity_topic(), {:chat_status, id, status})
  end
end
