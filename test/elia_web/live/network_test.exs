defmodule EliaWeb.NetworkTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.Agent

  setup do
    # The suite runs with the host's jail off (config/test.exs), which is what
    # the NET-25 test covers. The others want a host that has one, so the
    # controls are usable — a limit is built where the jail is (NET-20).
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    %{id: id}
  end

  defp settings(conn, id), do: live(conn, ~p"/c/#{id}/settings")

  # NET-22: the Network section has one control per mode, the chat's current mode
  # marked, and a line saying what applies in words.
  test "the settings page has the Network section, with its state in words", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#settings-network")

    for mode <- ~w(unrestricted allowlist none) do
      assert has_element?(view, "#network-#{mode}")
    end

    assert has_element?(view, "#network-unrestricted[aria-pressed='true']")
    assert has_element?(view, "#network-state", "Reaches the whole network")

    # NET-24: the host list is what allowlist mode shows.
    refute has_element?(view, "#network-hosts")
  end

  # NET-23: choosing a mode applies it at the moment it is clicked, like a
  # switch rather than the page's one Save.
  test "choosing a mode applies it and the state says so", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#network-none") |> render_click()

    assert has_element?(view, "#network-none[aria-pressed='true']")
    assert has_element?(view, "#network-state", "Reaches nothing at all")
    assert %{settings: %{network: %{mode: :none}}} = Agent.snapshot(id)

    view |> element("#network-allowlist") |> render_click()

    assert has_element?(view, "#network-allowlist[aria-pressed='true']")
    assert has_element?(view, "#network-state", "Reaches nothing yet")
    assert has_element?(view, "#network-hosts")
    assert %{settings: %{network: %{mode: :allowlist}}} = Agent.snapshot(id)

    view |> element("#network-unrestricted") |> render_click()

    assert has_element?(view, "#network-state", "Reaches the whole network")
    assert %{settings: %{network: %{mode: :unrestricted}}} = Agent.snapshot(id)
  end

  # NET-24, NET-23, CSET-7: the field holds the chat's entries, a half-typed list
  # survives applying a mode, and the page's own Save keeps the list.
  test "the host list is the page's to save, and a mode click doesn't lose it", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#network-allowlist") |> render_click()
    assert has_element?(view, "#network-hosts")

    # A half-typed list is kept while another mode is applied (NET-23).
    view |> form("#settings-form", %{network: %{hosts: "api.example.com\n"}}) |> render_change()
    view |> element("#network-none") |> render_click()
    view |> element("#network-allowlist") |> render_click()
    assert has_element?(view, "#network-hosts", "api.example.com")

    # CSET-11: an accepted save goes back to the chat.
    assert {:error, {:live_redirect, %{to: to}}} =
             view
             |> form("#settings-form", %{
               network: %{hosts: "api.example.com\n*.example.org:443\n"}
             })
             |> render_submit()

    assert to == "/c/#{id}"

    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network.hosts == ["api.example.com", "*.example.org:443"]

    # Reopening the page shows the chat's entries in the field (NET-24).
    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#network-hosts", "api.example.com")
    assert has_element?(view, "#network-hosts", "*.example.org:443")
  end

  # NET-11: a list holding an entry that isn't one of NET-7's forms changes
  # nothing, and the page shows the message for it (CSET-7).
  test "a host list with an entry that isn't one saves nothing", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#network-allowlist") |> render_click()

    view
    |> form("#settings-form", %{network: %{hosts: "api.example.com\nnot a host\n"}})
    |> render_submit()

    # A rejected save stays on the page, and the message names the entry.
    assert has_element?(view, "#settings-error", "not a host")
    assert has_element?(view, "#settings-error", "is not a host")

    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network.hosts == []
  end

  # NET-3, CSET-3: the section follows `{:settings, settings}`, so every view of
  # the chat agrees — a second tab here.
  test "every view of the chat follows the setting", %{conn: conn, id: id} do
    {:ok, first, _} = settings(conn, id)
    {:ok, second, _} = settings(conn, id)

    first |> element("#network-none") |> render_click()

    assert has_element?(first, "#network-state", "Reaches nothing at all")
    assert has_element?(second, "#network-state", "Reaches nothing at all")
  end

  # NET-25, UI-68: where the limit can't be built — here the host's jail is off —
  # the section says so and its controls are disabled, rather than showing a chat
  # as limited where it is not.
  test "a host that can't limit a network says so and disables the controls", %{
    conn: conn,
    id: id
  } do
    Application.put_env(:elia, Elia.Shell, jail: false)

    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#network-unavailable")
    assert has_element?(view, "#network-unrestricted[disabled]")
    assert has_element?(view, "#network-allowlist[disabled]")
    assert has_element?(view, "#network-none[disabled]")

    # The chat's setting is untouched, and the section says what applies rather
    # than showing it as limited where it isn't.
    assert %{settings: %{network: %{mode: :unrestricted}}} = Agent.snapshot(id)
    assert has_element?(view, "#network-state", "Reaches the whole network")
  end

  # NET-26, UI-100: the chat page says when the chat's network is limited, beside
  # its jail warning, and shows nothing there when it is unrestricted.
  test "the chat page says when the chat's network is limited", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    refute has_element?(view, "#network-warning")

    :ok = Agent.set_network(id, %{mode: :allowlist, hosts: ["api.example.com"]})
    assert has_element?(view, "#network-warning", "Allowlisted hosts")

    :ok = Agent.set_network(id, %{mode: :none})
    assert has_element?(view, "#network-warning", "No network")

    :ok = Agent.set_network(id, %{mode: :unrestricted})
    refute has_element?(view, "#network-warning")
  end
end
