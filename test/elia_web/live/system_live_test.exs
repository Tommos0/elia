defmodule EliaWeb.SystemLiveTest do
  use EliaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # SYS-6, SYS-7, SYS-11
  test "renders the dashboard sections and header link", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/system")

    assert has_element?(view, "#system-link[href='/system']")

    for id <- ~w(system-host system-uptime tile-cpu tile-memory tile-load tile-network
                 cpu-cores memory-detail disks network vm) do
      assert has_element?(view, "##{id}"), "missing ##{id}"
    end
  end

  # SYS-2, SYS-5, SYS-7, SYS-8
  test "a refresh fills in rates and sparklines", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/system")
    refute has_element?(view, "#cpu-sparkline polyline")

    send(view.pid, :tick)
    send(view.pid, :tick)

    assert has_element?(view, "#core-0")
    assert has_element?(view, "#cpu-sparkline polyline")
    assert has_element?(view, "#memory-sparkline polyline")
    refute has_element?(view, "#network [data-unavailable]")
  end

  # LOG-10
  test "links to the Log viewer", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/system")

    assert has_element?(view, "#logs-link[href='/logs']")
  end
end
