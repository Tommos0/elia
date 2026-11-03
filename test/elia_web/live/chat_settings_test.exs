defmodule EliaWeb.ChatSettingsTest do
  use EliaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elia.{Agent, FakeLLM, Store}
  alias Elia.LLM.Message

  setup do
    start_supervised!(FakeLLM)
    # The suite runs with the host's jail off (config/test.exs); these tests want
    # a host that has one, so the switch is usable (UI-68 covers the other case).
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)

    id = Agent.new_id()
    on_exit(fn -> Store.delete(id) end)

    # Selecting a model remembers it as the app's default (MODEL-15), and the
    # settings store is shared by the whole suite, so put it back.
    previous_model = Elia.Settings.get(:model)
    on_exit(fn -> if previous_model, do: Elia.Settings.put(:model, previous_model) end)

    %{id: id}
  end

  defp settings(conn, id), do: live(conn, ~p"/c/#{id}/settings")

  # Every limit field, so a submit doesn't carry a leftover value from the form.
  defp limits(max_steps \\ "", max_minutes \\ "") do
    %{max_steps: max_steps, max_minutes: max_minutes}
  end

  # Every compaction field, for the same reason.
  defp compaction(budget \\ "150000", fraction \\ "80", target \\ "50", working_set \\ "6") do
    %{budget: budget, fraction: fraction, target_fraction: target, working_set: working_set}
  end

  defp submit_compaction(view, params) do
    view |> element("#compaction-form") |> render_submit(%{"compaction" => params})
  end

  # CSET-1, UI-2
  test "a chat id that isn't valid goes home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/c/bad!id/settings")
  end

  # CSET-1, CSET-2, UI-3: the page shows the chat's own facts, and opening it
  # starts no turn.
  test "the page shows the chat and its project", %{conn: conn, id: id} do
    :ok = Store.save(id, [Message.user("Add a settings page")])
    {:ok, view, _html} = settings(conn, id)

    assert page_title(view) =~ "Add a settings page"
    assert has_element?(view, "#chat-settings-title", "Add a settings page")
    assert has_element?(view, "#chat-settings-back[href='/c/#{id}']")
    assert has_element?(view, "#chat-settings-project", "Elia")

    assert Agent.snapshot(id).status == :idle
  end

  test "opening the page of a chat that hasn't started writes no chat file", %{conn: conn, id: id} do
    refute Store.exists?(id)
    {:ok, _view, _html} = settings(conn, id)
    refute Store.exists?(id)
  end

  # CSET-5: one section per kind of setting, each with the control the composer
  # used to hold (UI-38, UI-67, MODEL-9) plus the ones it never showed.
  test "the page has a section per kind of setting", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#settings-model #model-picker-button")
    assert has_element?(view, "#settings-auto-approve #auto-approve-button")
    assert has_element?(view, "#settings-jail #jail-toggle")
    assert has_element?(view, "#settings-limits #limits-form")
    assert has_element?(view, "#settings-limits #limit-pause[role='switch']")
    assert has_element?(view, "#settings-context #compaction-form")
    assert has_element?(view, "#settings-context #compaction-auto[role='switch']")
  end

  # CSET-3: every control follows the chat's own events, so a change made
  # elsewhere shows up here.
  test "a change made in another view of the chat shows up here", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    {:ok, _} = Agent.select_model(id, "openrouter", "vendor/model", "Vendor Model")
    :ok = Agent.set_jail(id, false)
    :ok = Agent.set_limits(id, %{max_steps: 7, pause_on_limit: true})
    :ok = Agent.set_compaction(id, %{auto: false})

    render(view)
    assert has_element?(view, "#selected-model", "Vendor Model")
    assert has_element?(view, "#jail-state", "Not jailed")
    assert has_element?(view, "#limit-steps[value='7']")
    assert has_element?(view, "#limit-pause[aria-checked='true']")
    assert has_element?(view, "#compaction-auto[aria-checked='false']")
  end

  # CSET-4: a change made here applies to the chat at once, and starts nothing.
  test "changes apply to the chat's session", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#jail-toggle") |> render_click()
    assert Agent.snapshot(id).jail == false

    view |> element("#limit-pause") |> render_click()
    assert Agent.snapshot(id).limits.pause_on_limit == true

    view |> form("#limits-form", limits: limits("12", "5")) |> render_submit()
    assert %{max_steps: 12, max_minutes: 5} = Agent.snapshot(id).limits

    assert Agent.snapshot(id).status == :idle
    assert Agent.snapshot(id).messages == []
  end

  # CSET-6, STORE-27, STORE-28: an empty chat isn't written to disk by a change
  # made here; the value lives in the session and is saved with the first
  # message.
  test "a change on a chat with no messages is saved with its first message", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#jail-toggle") |> render_click()
    view |> element("#limit-pause") |> render_click()
    view |> form("#limits-form", limits: limits("5")) |> render_submit()

    assert %{max_steps: 5, pause_on_limit: true} = Agent.snapshot(id).limits
    refute Store.exists?(id)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))
    Agent.subscribe(id)
    :ok = Agent.send_message(id, "hi")
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    assert Store.exists?(id)
    assert Store.load_jail(id) == false
    assert %{max_steps: 5, pause_on_limit: true} = Store.load_limits(id)
  end

  # LIMIT-6: the section shows what the chat runs with and what a limit does.
  test "the Limits section shows the chat's limits and what reaching one does", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    # LIMIT-1: nothing set yet, so the loop's own default applies.
    assert has_element?(view, "#limit-steps[value='']")
    assert has_element?(view, "#limit-minutes[value='']")
    assert has_element?(view, "#limit-pause[aria-checked='false']")
    assert has_element?(view, "#limit-pause-state", "Off")
    assert has_element?(view, "#limits-state", "the default 100 steps")
    assert has_element?(view, "#limits-state", "no time budget")
    assert has_element?(view, "#limits-state", "ends the turn with an error")

    view |> form("#limits-form", limits: limits("25", "10")) |> render_submit()
    view |> element("#limit-pause") |> render_click()

    assert has_element?(view, "#limit-steps[value='25']")
    assert has_element?(view, "#limit-minutes[value='10']")
    assert has_element?(view, "#limit-pause[aria-checked='true']")
    assert has_element?(view, "#limit-pause-state", "On")
    assert has_element?(view, "#limits-state", "25 steps")
    assert has_element?(view, "#limits-state", "10 minutes")
    assert has_element?(view, "#limits-state", "pauses the turn")
    refute has_element?(view, "#settings-error")
  end

  # LIMIT-6, LIMIT-7: clearing a field goes back to the default.
  test "an empty field clears a limit", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)
    :ok = Agent.set_limits(id, %{max_steps: 25})
    render(view)

    view |> form("#limits-form", limits: limits()) |> render_submit()

    assert Agent.snapshot(id).limits == %{
             max_steps: nil,
             max_minutes: nil,
             pause_on_limit: false
           }

    assert has_element?(view, "#limits-state", "the default 100 steps")
  end

  # CSET-7, LIMIT-7
  test "a value that isn't a limit is rejected and changes nothing", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    for bad <- ~w(abc 0 -3 1001 2.5) do
      view |> form("#limits-form", limits: limits(bad)) |> render_submit()

      assert has_element?(view, "#settings-error")
      assert Agent.snapshot(id).limits.max_steps == nil
      # CSET-7: the typed value stays, so it can be corrected.
      assert has_element?(view, "#limit-steps[value='#{bad}']")
    end

    view |> form("#limits-form", limits: limits("", "0")) |> render_submit()
    assert has_element?(view, "#settings-error")
    assert Agent.snapshot(id).limits.max_minutes == nil

    # A good value clears the message.
    view |> form("#limits-form", limits: limits("3")) |> render_submit()
    refute has_element?(view, "#settings-error")
    assert Agent.snapshot(id).limits.max_steps == 3
  end

  # COMPACT-30: the section shows this chat's compaction options, as percentages,
  # and the trigger they give for the model's window.
  test "the Context section shows the chat's compaction options", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#compaction-auto[aria-checked='true']")
    assert has_element?(view, "#compaction-auto-state", "On")
    assert has_element?(view, "#compaction-budget[value='150000']")
    assert has_element?(view, "#compaction-fraction[value='80']")
    assert has_element?(view, "#compaction-target[value='50']")
    assert has_element?(view, "#compaction-working-set[value='6']")
    assert has_element?(view, "#compaction-trigger")
  end

  # COMPACT-30, COMPACT-9
  test "the Context section sets the chat's options", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    view
    |> form("#compaction-form", compaction: compaction("20000", "70", "40", "3"))
    |> render_submit()

    assert %{budget: 20_000, fraction: 0.7, target_fraction: 0.4, working_set: 3} =
             Agent.snapshot(id).compaction.options

    assert has_element?(view, "#compaction-budget[value='20000']")
    assert has_element?(view, "#compaction-fraction[value='70']")
    assert has_element?(view, "#compaction-target[value='40']")
    assert has_element?(view, "#compaction-working-set[value='3']")
    refute has_element?(view, "#settings-error")

    # COMPACT-9: automatic compaction can be turned off for this chat, and the
    # other values are left as they are.
    view |> element("#compaction-auto") |> render_click()

    assert Agent.snapshot(id).compaction.options.auto == false
    assert has_element?(view, "#compaction-auto[aria-checked='false']")
    assert has_element?(view, "#compaction-auto-state", "Off")
    assert has_element?(view, "#compaction-budget[value='20000']")

    # And back on.
    view |> element("#compaction-auto") |> render_click()

    assert Agent.snapshot(id).compaction.options.auto == true
    assert has_element?(view, "#compaction-auto[aria-checked='true']")
  end

  # CSET-7, COMPACT-30: a value that isn't one is rejected and changes nothing.
  test "an invalid Context value is rejected and changes nothing", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    for bad <- ~w(150 0 abc) do
      submit_compaction(view, %{"fraction" => bad})

      assert has_element?(view, "#settings-error")
      refute Agent.snapshot(id).compaction.options[:fraction]
      # CSET-7: the typed value stays, and the others with it.
      assert has_element?(view, "#compaction-fraction[value='#{bad}']")
      assert has_element?(view, "#compaction-budget[value='150000']")
    end

    submit_compaction(view, compaction("0", "80"))
    assert has_element?(view, "#settings-error")
    refute Agent.snapshot(id).compaction.options[:budget]

    submit_compaction(view, compaction("150000", "80", "50", "half"))
    assert has_element?(view, "#settings-error")
    refute Agent.snapshot(id).compaction.options[:working_set]

    # A good value clears the message.
    submit_compaction(view, compaction())
    refute has_element?(view, "#settings-error")
    assert Agent.snapshot(id).compaction.options.fraction == 0.8
  end
end
