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

  # NET-28: a project's entries are every chat of it, so a test that changes them
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
    # them; NET-38: and the entries this chat names of its own, in a field with
    # a Save of its own.
    assert has_element?(view, "#network-hosts")
    assert has_element?(view, "#network-hosts-link")
    assert has_element?(view, "#chat-network-hosts")
    assert has_element?(view, "#save-chat-network-hosts")
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

  # NET-38: the entries this chat names of its own are applied when its own Save
  # is pressed; NET-36: they are the chat's alone, so the project's list is not
  # touched. NET-11: an entry that is not one of NET-7's forms changes nothing
  # and the section says which it is.
  test "the chat's own hosts are saved when Save is pressed", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)
    project = project(id)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    view
    |> element("#chat-network-hosts-form")
    |> render_submit(%{"hosts" => "API.example.com\nlocalhost:3000"})

    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network == %{mode: :allowlist, hosts: ["api.example.com", "localhost:3000"]}
    assert Elia.Projects.allowlist(project) == []
    assert has_element?(view, "#network-state", "Reaches 2 allowed hosts")

    # A page reopened on the chat shows them as the chat names them (NET-36).
    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#chat-network-hosts", "api.example.com")

    # NET-11, NET-38: an entry that can't be one is named, and nothing changes.
    view
    |> element("#chat-network-hosts-form")
    |> render_submit(%{"hosts" => "api.example.com\nnot a host"})

    assert has_element?(view, "#chat-network-hosts-error", "not a host")
    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network == %{mode: :allowlist, hosts: ["api.example.com", "localhost:3000"]}
  end

  # NET-36: the entries a chat names of its own belong to it, so applying a mode
  # leaves them as they are — switching to another mode and back loses nothing.
  test "choosing a mode keeps the chat's own entries", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    :ok = Agent.set_network(id, %{mode: :allowlist, hosts: ["localhost:3000"]})
    view |> element("#network-none") |> render_click()

    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network == %{mode: :none, hosts: ["localhost:3000"]}

    view |> element("#network-allowlist") |> render_click()
    assert %{settings: %{network: network}} = Agent.snapshot(id)
    assert network == %{mode: :allowlist, hosts: ["localhost:3000"]}
  end

  # NET-24, NET-28, CSET-7: the section shows the entries the chat's project
  # allows, one per line, and the page's Save is the numeric settings' — a
  # project's entries are changed on the project's own page (PROJ-50, PROJ-51),
  # and the chat's own by its own Save (NET-38).
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

    # Reopening the page shows the project's entries (NET-28), and none of the
    # chat's own where the chat names none (NET-36).
    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#network-hosts", "api.example.com")
    assert has_element?(view, "#chat-network-hosts", "")
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

  # NET-26 retired: the composer carries no network notice, in any mode. The
  # setting is shown and changed on the chat settings page instead.
  test "the composer shows no network notice", %{conn: conn, id: id} do
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    # NET-1: a chat that has never been saved is allowlisted, and says nothing.
    refute has_element?(view, "#network-warning")

    for network <- [
          %{mode: :none},
          %{mode: :unrestricted},
          %{mode: :allowlist, hosts: ["localhost:3000"]}
        ] do
      :ok = Agent.set_network(id, network)
      refute has_element?(view, "#network-warning")
    end
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

    # NET-32, UI-59, UI-62: one button per decision — the host for this chat,
    # for its project, or neither — and the field for an answer of the user's own
    # (ASK-4).
    assert has_element?(view, "#answer-n1-0", "Allow for chat")
    assert has_element?(view, "#answer-n1-1", "Allow for project")
    assert has_element?(view, "#answer-n1-2", "Deny")
    assert has_element?(view, "#answer-text-n1")

    # NET-32, UI-61: the card is shown in the compact view too — it is addressed
    # to the user, not a detail of the agent's work.
    render_hook(view, "set_compact_view", %{"on" => true})
    assert has_element?(view, "#answer-n1-0", "Allow for chat")
    assert has_element?(view, "#answer-text-n1")

    # NET-33, NET-36: clicking the first answers the request, and the host joins
    # the entries this chat names of its own — its project's list is untouched.
    project = project(id)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Fetched it.")]))
    view |> element("#answer-n1-0") |> render_click()

    await_status(id, :idle)
    assert Agent.network_setting(id) == %{mode: :allowlist, hosts: ["api.example.com"]}
    assert Elia.Projects.allowlist(project) == []
  end

  # NET-32, NET-33, NET-28: the project's button answers the request with the
  # host for the project, whose list every chat of it reaches from then on.
  test "the project's button allows the host for the project", %{conn: conn, id: id} do
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

    project = project(id)
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    FakeLLM.push(FakeLLM.assistant([Message.text("Fetched it.")]))
    view |> element("#answer-n1-1") |> render_click()

    await_status(id, :idle)
    assert Elia.Projects.allowlist(project) == ["api.example.com"]
    assert Agent.network_setting(id) == %{mode: :allowlist, hosts: []}
    assert Agent.network(id) == %{mode: :allowlist, hosts: ["api.example.com"]}
  end
end
