defmodule EliaWeb.SessionsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.Agent
  alias Phoenix.Socket.Broadcast

  @firefox "Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0"

  defp firefox_conn, do: put_req_header(build_conn(), "user-agent", @firefox)

  # Waits until presence diffs with each of `kinds` (:joins, :leaves) have
  # arrived. The sessions view subscribed before the test did, so it has
  # received them too.
  defp await_diffs([]), do: :ok

  defp await_diffs(kinds) do
    assert_receive %Broadcast{event: "presence_diff", payload: diff}
    kinds |> Enum.reject(&(map_size(diff[&1]) > 0)) |> await_diffs()
  end

  # CLIENT-5, CLIENT-9
  test "lists the viewer's own tab", %{conn: conn} do
    {:ok, chat, _} = live(conn, ~p"/c/#{Agent.new_id()}")
    assert has_element?(chat, "#sessions-link[href='/sessions']")

    {:ok, view, _} = live(conn, ~p"/sessions")
    assert has_element?(view, "#client-sessions #this-tab")
    assert has_element?(view, "#session-count")
  end

  # CLIENT-1, CLIENT-2, CLIENT-6
  test "shows another tab's browser, IP and page", %{conn: conn} do
    id = Agent.new_id()
    {:ok, _chat, _} = live(firefox_conn(), ~p"/c/#{id}")

    {:ok, view, _} = live(conn, ~p"/sessions")
    assert has_element?(view, "#client-sessions li", "Firefox 131")
    assert has_element?(view, "#client-sessions li", "Linux")
    assert has_element?(view, "#client-sessions li", "127.0.0.1")
    assert has_element?(view, "#client-sessions a[href='/c/#{id}']", "New chat")
  end

  # CLIENT-3, CLIENT-7
  test "updates live as tabs connect and navigate", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sessions")
    EliaWeb.ClientTracker.subscribe()

    first = Agent.new_id()
    {:ok, chat, _} = live(firefox_conn(), ~p"/c/#{first}")
    await_diffs([:joins])
    assert has_element?(view, "#client-sessions a[href='/c/#{first}']")

    second = Agent.new_id()
    {:ok, _chat, _} = live_redirect(chat, to: ~p"/c/#{second}")
    await_diffs([:joins, :leaves])
    assert has_element?(view, "#client-sessions a[href='/c/#{second}']")
    refute has_element?(view, "#client-sessions a[href='/c/#{first}']")
  end
end
