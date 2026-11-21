defmodule EliaWeb.NetworkTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    # The suite runs with the host's jail off (config/test.exs), which is what
    # the NET-25 test covers. The others want a host that has one, so the
    # controls are usable — a limit is built where the jail is (NET-20).
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    start_supervised!(FakeLLM)

    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)
    %{id: id}
  end

  defp settings(conn, id), do: live(conn, ~p"/c/#{id}/settings")

  # The LiveView, not this test process, is the subscriber, so the session's
  # state is polled here rather than awaited on a message.
  defp await_status(id, status) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    wait(id, status, deadline)
  end

  defp wait(id, status, deadline) do
    if Agent.snapshot(id).status == status do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "chat never reached #{status}"
      Process.sleep(20)
      wait(id, status, deadline)
    end
  end

  # NET-28: the entries are the chat's project's, so a test that changes them
  # puts them back.
  defp project(id), do: Agent.snapshot(id).project

  # NET-22: the Network section has one control per mode, the chat's current mode
  # marked, and a line saying what applies in words. NET-1: a chat that has never
  # been saved starts allowlisted.
  test "the settings page has the Network section, with its state in words", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#settings-network")

    for mode <- ~w(unrestricted allowlist none) do
      assert has_element?(view, "#network-#{mode}")
    end

    assert has_element?(view, "#network-allowlist[aria-pressed='true']")
    assert has_element?(view, "#network-state", "Reaches nothing yet")

    # NET-24: allowlist mode shows the project's entries and where to change
    # them.
    assert has_element?(view, "#network-hosts")
    assert has_element?(view, "#network-hosts-link")
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

  # NET-24, NET-28, CSET-7: the section shows the entries the chat's project
  # allows, one per line, and the page's Save stores the mode alone — the
  # entries are changed on the projects page (PROJ-50).
  test "the section shows the project's entries, and the save keeps the mode", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)
    view |> element("#network-allowlist") |> render_click()

    project = project(id)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)
    {:ok, _project} = Elia.Projects.set_allowlist(project, ["api.example.com"])

    # The next render of the section reads them again — a settings event here.
    Agent.set_network(id, %{mode: :allowlist})
    assert has_element?(view, "#network-hosts", "api.example.com")

    # CSET-11: an accepted save goes back to the chat, with the mode it holds.
    assert {:error, {:live_redirect, %{to: to}}} =
             view |> form("#settings-form", %{}) |> render_submit()

    assert to == "/c/#{id}"
    assert %{settings: %{network: %{mode: :allowlist}}} = Agent.snapshot(id)

    # Reopening the page shows the project's entries, not the chat's (NET-28).
    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#network-hosts", "api.example.com")
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
  # as limited where it is not. NET-1: such a chat starts unrestricted rather
  # than allowlisted.
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

  # NET-26, NET-28, UI-100: the chat page says when the chat's network is
  # limited, beside its jail warning, naming the project whose allowlist the
  # chat reaches, and shows nothing there when it is unrestricted.
  test "the chat page says when the chat's network is limited", %{conn: conn, id: id} do
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])
    project = project(id)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)
    {:ok, _project} = Elia.Projects.set_allowlist(project, ["api.example.com"])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # NET-1: a chat that has never been saved is allowlisted, so the warning is
    # there from the first render.
    assert has_element?(view, "#network-warning", "Allowlisted")
    assert has_element?(view, "#network-warning", project.name)

    :ok = Agent.set_network(id, %{mode: :none})
    assert has_element?(view, "#network-warning", "No network")

    :ok = Agent.set_network(id, %{mode: :unrestricted})
    refute has_element?(view, "#network-warning")
  end

  # NET-32: the request is a card in the transcript that names the host and the
  # reason, with a button per decision beside the field for an answer of the
  # user's own — as a question's card is (UI-75). NET-31: the turn waits on it.
  test "the host request is a card with its buttons", %{conn: conn, id: id} do
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    FakeLLM.push(
      FakeLLM.assistant([
        FakeLLM.tool_call("n1", "request_network_host", %{
          "host" => "api.example.com",
          "reason" => "curl could not reach it"
        })
      ])
    )

    :ok = Agent.send_message(id, "fetch the price")
    await_status(id, :awaiting_input)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # The card names the host and the reason, not the raw input.
    assert has_element?(view, "#transcript", "api.example.com")
    assert has_element?(view, "#transcript", "curl could not reach it")
    refute has_element?(view, "#transcript", "\"reason\"")

    # NET-32, UI-59, UI-62: one button per decision, and the field for an answer
    # of the user's own (ASK-4).
    assert has_element?(view, "#answer-n1-0", "Allow")
    assert has_element?(view, "#answer-n1-1", "Don't allow")
    assert has_element?(view, "#answer-text-n1")

    # NET-32, UI-61: the card is shown in the compact view too — it is addressed
    # to the user, not a detail of the agent's work.
    render_hook(view, "set_compact_view", %{"on" => true})
    assert has_element?(view, "#answer-n1-0", "Allow")
    assert has_element?(view, "#answer-text-n1")

    # NET-33: clicking Allow answers the request, the host joins the chat's
    # project's list, and the card is answered.
    project = project(id)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Fetched it.")]))
    view |> element("#answer-n1-0") |> render_click()

    await_status(id, :idle)
    assert Elia.Projects.allowlist(project) == ["api.example.com"]
  end
end
