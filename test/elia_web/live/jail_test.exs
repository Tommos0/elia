defmodule EliaWeb.JailTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    # The suite runs with the host's jail off (config/test.exs), which is what
    # the UI-68 test covers. The others want a host that has one, so the switch
    # is usable.
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    id = Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)
    %{id: id}
  end

  defp settings(conn, id), do: live(conn, ~p"/c/#{id}/settings")

  # UI-67, CSET-5: the switch sits in the Jail section, with its state written
  # out, and the chat's other settings are on the same page.
  test "the chat settings page has the jail switch, with its state in words", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#settings-jail #jail-toggle[role='switch'][aria-checked='true']")
    assert has_element?(view, "#jail-state", "Jailed")
    refute has_element?(view, "#jail-warning")

    # The controls the composer used to hold are on this page too (CSET-5).
    assert has_element?(view, "#settings-model #model-picker-button")
    assert has_element?(view, "#settings-auto-approve #auto-approve-button")
  end

  # CSET-8: the composer keeps one link to that page, carrying the model in use,
  # and no longer the picker, the auto-approve button or the switch.
  test "the composer links to the settings page instead of holding the controls", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")

    assert has_element?(view, "#chat-settings-link[href='/c/#{id}/settings']")
    assert has_element?(view, "#chat-settings-model")
    refute has_element?(view, "#model-picker-button")
    refute has_element?(view, "#auto-approve-button")
    refute has_element?(view, "#jail-toggle")
  end

  # UI-67, SESS-30, ISOL-16, CSET-4
  test "the switch turns the chat's jail off and on, and says what that means", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#jail-toggle") |> render_click()
    assert has_element?(view, "#jail-toggle[aria-checked='false']")
    assert has_element?(view, "#jail-state", "Not jailed")
    assert %{jail: false} = Agent.snapshot(id)

    # UI-67: turning it off shows that commands can then reach the secrets.
    html = render(element(view, "#jail-warning"))
    assert html =~ "settings database"
    assert html =~ "credentials"

    view |> element("#jail-toggle") |> render_click()
    assert has_element?(view, "#jail-toggle[aria-checked='true']")
    assert has_element?(view, "#jail-state", "Jailed")
    assert %{jail: true} = Agent.snapshot(id)
    refute has_element?(view, "#jail-warning")
  end

  # UI-67, SESS-30, CSET-3: the switch follows `{:jail, on?}`, so every view of
  # the chat agrees — a second tab here.
  test "every view of the chat follows the switch", %{conn: conn, id: id} do
    {:ok, first, _} = settings(conn, id)
    {:ok, second, _} = settings(conn, id)

    first |> element("#jail-toggle") |> render_click()

    assert has_element?(first, "#jail-state", "Not jailed")
    # Rendering the second view waits for the broadcast to be handled.
    render(second)
    assert has_element?(second, "#jail-state", "Not jailed")
  end

  # UI-67, STORE-25, STORE-26: the setting is saved with the chat and read back.
  test "a chat whose jail is off shows it when opened again", %{conn: conn, id: id} do
    :ok = Elia.Store.save(id, [Message.user("hi")], jail: false)

    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#jail-toggle[aria-checked='false']")
    assert has_element?(view, "#jail-state", "Not jailed")
  end

  # UI-68, ISOL-12, ISOL-20
  test "with no jail on the host the switch is disabled and says so", %{conn: conn, id: id} do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true, bwrap: "/nonexistent/bwrap")
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#jail-toggle[disabled]")
    # The chat is not shown as protected where it isn't.
    assert has_element?(view, "#jail-state", "Not jailed")
    assert has_element?(view, "#jail-unavailable", "bubblewrap is unavailable")

    # A disabled switch changes nothing.
    assert has_element?(view, "#jail-toggle[aria-checked='false']")
  end

  # CSET-9, UI-68, ISOL-17: the chat page still says where commands run, next to
  # its settings link, since that is where they run.
  test "the chat page says when its commands run unjailed", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    refute has_element?(view, "#jail-warning")

    # Turned off here (through the session, as the settings page does)...
    :ok = Agent.set_jail(id, false)

    # ...the chat page says so, without a reload.
    render(view)
    assert has_element?(view, "#jail-warning", "credentials")
    refute has_element?(view, "#jail-toggle")

    :ok = Agent.set_jail(id, true)
    render(view)
    refute has_element?(view, "#jail-warning")
  end

  # CSET-9, UI-68, ISOL-20
  test "with no jail on the host the chat page says so", %{conn: conn, id: id} do
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true, bwrap: "/nonexistent/bwrap")
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    assert has_element?(view, "#jail-unavailable")
    refute has_element?(view, "#jail-warning")
  end

  # UI-69, ISOL-17, CSET-4: the jail turned off on the settings page is the jail
  # the chat's commands run under.
  test "an approval prompt in a chat whose jail is off says the command runs unjailed", %{
    conn: conn,
    id: id
  } do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    # APPR-14: a new chat auto-approves every tool, so this chat is started with
    # an empty set — the command below has to wait for approval.
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    {:ok, settings, _html} = settings(conn, id)
    settings |> element("#jail-toggle") |> render_click()
    assert has_element?(settings, "#jail-state", "Not jailed")

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "go"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000

    assert has_element?(view, "#approve-c1")
    assert has_element?(view, "#unjailed-c1", "unjailed")

    # ISOL-19: turning the jail off loosens nothing else — the call still needs
    # approval and no tool is auto-approved.
    assert has_element?(view, "#deny-c1")
    assert %{auto_approve: []} = Agent.snapshot(id)
  end

  # UI-69: a jailed chat's prompt doesn't mention it.
  test "a jailed chat's approval prompt doesn't say unjailed", %{conn: conn, id: id} do
    FakeLLM.push(FakeLLM.assistant([FakeLLM.tool_call("c1", "shell", %{"command" => "echo hi"})]))

    FakeLLM.push(FakeLLM.assistant([Message.text("Done.")]))

    # APPR-14: a new chat auto-approves every tool, so this chat is started with
    # an empty set — the command below has to wait for approval.
    {:ok, _pid} = Agent.ensure_started(id, auto_approve: [])

    {:ok, view, _html} = live(conn, ~p"/c/#{id}")
    Agent.subscribe(id)

    view |> form("#chat-form", chat: %{text: "go"}) |> render_submit()
    assert_receive {:agent, ^id, {:status, :awaiting_approval}}, 5000

    assert has_element?(view, "#approve-c1")
    refute has_element?(view, "#unjailed-c1")
  end
end
