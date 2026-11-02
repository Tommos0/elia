defmodule EliaWeb.LogsLiveTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.Logs

  require Logger

  setup do
    Logs.clear()
    # LOG-6, LOG-8: the broadcasts that drive the page.
    Logs.subscribe()
    :ok
  end

  # Logs a line and waits until it has been broadcast, so the page (also a
  # subscriber) has it queued before we read the DOM.
  defp log!(message) do
    Logger.warning(message)
    await(message)
  end

  defp await(message) do
    assert_receive {:log_entry, %{message: received}}, 1000
    unless received =~ message, do: await(message)
  end

  # LOG-5, LOG-9
  test "lists captured entries newest first, with a count and their source", %{conn: conn} do
    log!("logs-live: first line")
    log!("logs-live: second line")

    {:ok, view, _} = live(conn, ~p"/logs")

    assert has_element?(view, "#log-count", "2 entries")
    assert has_element?(view, "#log-entries li", "logs-live: first line")
    assert has_element?(view, "#log-entries li", "logs-live: second line")
    assert has_element?(view, "#log-entries li", "warning")
    # LOG-9: the source (module and pid) is shown.
    assert has_element?(view, "#log-entries li", "EliaWeb.LogsLiveTest")
  end

  # LOG-6
  test "updates live as new entries arrive", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/logs")
    refute has_element?(view, "#log-entries li[data-level]")

    log!("logs-live: appears later")
    assert has_element?(view, "#log-entries li[data-level]", "logs-live: appears later")
  end

  # LOG-7
  test "filters by minimum level", %{conn: conn} do
    record(:info, "info line")
    record(:error, "error line")

    {:ok, view, _} = live(conn, ~p"/logs")
    assert has_element?(view, "#log-entries li", "info line")
    assert has_element?(view, "#log-entries li", "error line")

    render_change(view, "filter", %{"filter" => %{"level" => "error", "query" => ""}})
    refute has_element?(view, "#log-entries li", "info line")
    assert has_element?(view, "#log-entries li", "error line")

    render_change(view, "filter", %{"filter" => %{"level" => "all", "query" => ""}})
    assert has_element?(view, "#log-entries li", "info line")
  end

  # LOG-7
  test "filters by search text", %{conn: conn} do
    record(:info, "Connecting to the database")
    record(:info, "Serving a request")

    {:ok, view, _} = live(conn, ~p"/logs")
    assert has_element?(view, "#log-entries li", "Connecting to the database")

    render_change(view, "filter", %{"filter" => %{"level" => "all", "query" => "DATABASE"}})
    assert has_element?(view, "#log-entries li", "Connecting to the database")
    refute has_element?(view, "#log-entries li", "Serving a request")
  end

  # LOG-8
  test "clears the list from the page", %{conn: conn} do
    log!("logs-live: to be cleared")

    {:ok, view, _} = live(conn, ~p"/logs")
    assert has_element?(view, "#log-entries li", "logs-live: to be cleared")

    render_click(view, "clear")

    refute has_element?(view, "#log-entries li[data-level]")
    assert has_element?(view, "#log-entries-empty")
  end

  defp record(level, message) do
    Logs.record(%{at: DateTime.utc_now(), level: level, message: message, mfa: nil, pid: nil})
    :ok
  end
end
