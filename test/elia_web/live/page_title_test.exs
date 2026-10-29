defmodule EliaWeb.PageTitleTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, Store}
  alias Elia.LLM.Message

  test "page title follows the chat when switching", %{conn: conn} do
    a = Agent.new_id()
    b = Agent.new_id()
    :ok = Store.save(a, [Message.user("first chat")])
    :ok = Store.save(b, [Message.user("second chat")])

    {:ok, view, html} = live(conn, ~p"/c/#{a}")
    assert html =~ "Elia - first chat</title>"
    assert page_title(view) == "Elia - first chat"

    {:ok, view, _html} =
      view |> element("#chat-link-#{b}") |> render_click() |> follow_redirect(conn)

    assert page_title(view) == "Elia - second chat"

    Store.delete(a)
    Store.delete(b)
  end
end
