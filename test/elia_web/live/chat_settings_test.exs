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
    # settings store is shared by the whole suite, so put it back — or drop it
    # again, so a chat that selects one doesn't leave every later test on that
    # provider.
    previous_model = Elia.Settings.get(:model)

    on_exit(fn ->
      if previous_model,
        do: Elia.Settings.put(:model, previous_model),
        else: Elia.Settings.delete(:model)
    end)

    %{id: id}
  end

  defp settings(conn, id), do: live(conn, ~p"/c/#{id}/settings")

  # Every limit field, so a submit doesn't carry a leftover value from the form.
  defp limits(max_steps \\ "", max_minutes \\ "", max_tokens \\ "") do
    %{max_steps: max_steps, max_minutes: max_minutes, max_tokens: max_tokens}
  end

  # Every compaction field, for the same reason.
  defp compaction(budget \\ "150000", fraction \\ "80", target \\ "50", working_set \\ "6") do
    %{budget: budget, fraction: fraction, target_fraction: target, working_set: working_set}
  end

  # CSET-7, CSET-11: the page's one form and one Save. The group a test doesn't
  # name keeps the values the form shows, so a submit carries a whole, valid set.
  # An accepted save returns `{:error, {:live_redirect, …}}`, a rejected one the
  # page.
  defp submit_settings(view, params) do
    view |> form("#settings-form", params) |> render_submit()
  end

  defp submit_limits(view, max_steps, max_minutes \\ ""),
    do: submit_settings(view, %{limits: limits(max_steps, max_minutes)})

  defp submit_compaction(view, params), do: submit_settings(view, %{compaction: params})

  # CSET-11: an accepted save goes back to that chat.
  defp assert_saved(view, params, id) do
    assert {:error, {:live_redirect, %{to: to}}} = submit_settings(view, params)
    assert to == "/c/#{id}"
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
    assert has_element?(view, "#settings-form #settings-limits #limit-steps")
    assert has_element?(view, "#settings-form #settings-limits #limit-tokens")
    assert has_element?(view, "#settings-limits #limit-pause[role='switch']")
    assert has_element?(view, "#settings-form #settings-context #compaction-budget")
    assert has_element?(view, "#settings-context #compaction-auto[role='switch']")
    # CSET-5, UI-54: the Compact button, which used to sit in the composer.
    assert has_element?(view, "#settings-context #compact-button")
  end

  # CSET-7: every numeric setting is set in one form with one Save — the limits
  # and the context options alike.
  test "the page has one form with one Save for every numeric setting", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)
    document = view |> render() |> LazyHTML.from_fragment()

    assert has_element?(view, "#settings-form #limit-steps")
    assert has_element?(view, "#settings-form #limit-minutes")
    assert has_element?(view, "#settings-form #limit-tokens")
    assert has_element?(view, "#settings-form #compaction-budget")
    assert has_element?(view, "#settings-form #compaction-fraction")
    assert has_element?(view, "#settings-form #compaction-target")
    assert has_element?(view, "#settings-form #compaction-working-set")
    assert has_element?(view, "#settings-form #save-settings")

    assert length(LazyHTML.to_tree(LazyHTML.query(document, "form#settings-form"))) == 1

    assert length(LazyHTML.to_tree(LazyHTML.query(document, "button[type='submit']"))) == 1
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

  # CSET-4, CSET-7, CSET-11: a change made here applies to the chat at once, and
  # an accepted save goes back to it. Nothing here starts a turn.
  test "changes apply to the chat's session", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    view |> element("#jail-toggle") |> render_click()
    assert Agent.snapshot(id).jail == false

    # LIMIT-9: pausing is on by default, so the click turns it off.
    view |> element("#limit-pause") |> render_click()
    assert Agent.snapshot(id).limits.pause_on_limit == false

    saved = %{limits: limits("12", "5", "500000"), compaction: compaction("20000", "70")}
    assert_saved(view, saved, id)

    assert %{max_steps: 12, max_minutes: 5, max_tokens: 500_000} = Agent.snapshot(id).limits
    assert %{budget: 20_000, fraction: 0.7} = Agent.snapshot(id).compaction.options

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
    assert_saved(view, %{limits: limits("5", "", "900"), compaction: compaction()}, id)

    # LIMIT-9: pausing is on by default, so what the click set is the off value
    # — a value that isn't the default, and so the one the file carries
    # (STORE-27).
    assert %{max_steps: 5, max_tokens: 900, pause_on_limit: false} = Agent.snapshot(id).limits
    refute Store.exists?(id)

    FakeLLM.push(FakeLLM.assistant([Message.text("Hello!")]))
    Agent.subscribe(id)
    :ok = Agent.send_message(id, "hi")
    assert_receive {:agent, ^id, {:status, :idle}}, 5000

    assert Store.exists?(id)
    assert Store.load_jail(id) == false

    # STORE-27, STORE-28, LIMIT-2: the token budget is saved and loaded like the
    # others.
    assert %{max_steps: 5, max_tokens: 900, pause_on_limit: false} = Store.load_limits(id)
  end

  # LIMIT-6: the section shows what the chat runs with and what a limit does.
  test "the Limits section shows the chat's limits and what reaching one does", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    # LIMIT-1, LIMIT-9, LIMIT-12: nothing set yet, so the loop's own default
    # applies — 100 steps, no time budget, no token budget — and pausing is on.
    assert has_element?(view, "#limit-steps[value='']")
    assert has_element?(view, "#limit-minutes[value='']")
    assert has_element?(view, "#limit-tokens[value='']")
    assert has_element?(view, "#limit-pause[aria-checked='true']")
    assert has_element?(view, "#limit-pause-state", "On")
    assert has_element?(view, "#settings-limits", "On (the default)")
    assert has_element?(view, "#settings-limits", "no token budget")
    assert has_element?(view, "#limits-state", "the default 100 steps")
    assert has_element?(view, "#limits-state", "no time budget")
    assert has_element?(view, "#limits-state", "no token budget")
    assert has_element?(view, "#limits-state", "pauses the turn")

    assert_saved(view, %{limits: limits("25", "10", "500000")}, id)
    # CSET-11: the save went back to the chat, so the page is opened again.
    {:ok, view, _html} = settings(conn, id)

    # LIMIT-9: turning pausing off keeps the old ending (LOOP-3) ...
    view |> element("#limit-pause") |> render_click()

    assert has_element?(view, "#limit-pause[aria-checked='false']")
    assert has_element?(view, "#limit-pause-state", "Off")
    assert has_element?(view, "#limits-state", "ends the turn with an error")

    # ... and turning it back on pauses.
    view |> element("#limit-pause") |> render_click()

    assert has_element?(view, "#limit-steps[value='25']")
    assert has_element?(view, "#limit-minutes[value='10']")
    assert has_element?(view, "#limit-tokens[value='500000']")
    assert has_element?(view, "#limit-pause[aria-checked='true']")
    assert has_element?(view, "#limit-pause-state", "On")
    assert has_element?(view, "#limits-state", "25 steps")
    assert has_element?(view, "#limits-state", "10 minutes")
    # LIMIT-12: a count the page says the way the context indicator does.
    assert has_element?(view, "#limits-state", "500K tokens")
    assert has_element?(view, "#limits-state", "pauses the turn")
    refute has_element?(view, "#settings-error")
  end

  # LIMIT-6, LIMIT-7: clearing a field goes back to the default.
  test "an empty field clears a limit", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)
    :ok = Agent.set_limits(id, %{max_steps: 25, max_tokens: 900})
    render(view)

    assert_saved(view, %{limits: limits()}, id)

    assert Agent.snapshot(id).limits == %{
             max_steps: nil,
             max_minutes: nil,
             max_tokens: nil,
             pause_on_limit: true
           }

    {:ok, view, _html} = settings(conn, id)
    assert has_element?(view, "#limits-state", "the default 100 steps")
    assert has_element?(view, "#limits-state", "no token budget")
  end

  # CSET-7, LIMIT-7
  test "a value that isn't a limit is rejected and changes nothing", %{conn: conn, id: id} do
    {:ok, view, _html} = settings(conn, id)

    for bad <- ~w(abc 0 -3 1001 2.5) do
      submit_limits(view, bad)

      assert has_element?(view, "#settings-error")
      assert Agent.snapshot(id).limits.max_steps == nil
      # CSET-7: the typed value stays, so it can be corrected.
      assert has_element?(view, "#limit-steps[value='#{bad}']")
    end

    submit_limits(view, "", "0")
    assert has_element?(view, "#settings-error")
    assert Agent.snapshot(id).limits.max_minutes == nil

    # LIMIT-7, LIMIT-12: the token budget must be a whole number above 0 too ...
    for bad <- ~w(abc 0 -3 2.5) do
      submit_settings(view, %{limits: limits("", "", bad)})

      assert has_element?(view, "#settings-error")
      assert Agent.snapshot(id).limits.max_tokens == nil
      assert has_element?(view, "#limit-tokens[value='#{bad}']")
    end

    # CSET-11: a good value is accepted, and the save goes back to the chat.
    assert_saved(view, %{limits: limits("3")}, id)
    assert Agent.snapshot(id).limits.max_steps == 3

    # ... and, unlike the other two, it has no upper bound: a count far above
    # the step limit's cap is taken as it is.
    {:ok, view, _html} = settings(conn, id)
    assert_saved(view, %{limits: limits("", "", "1000000000")}, id)
    assert Agent.snapshot(id).limits.max_tokens == 1_000_000_000
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

    assert_saved(view, %{compaction: compaction("20000", "70", "40", "3")}, id)

    assert %{budget: 20_000, fraction: 0.7, target_fraction: 0.4, working_set: 3} =
             Agent.snapshot(id).compaction.options

    # CSET-11: the save went back to the chat, so the page is opened again.
    {:ok, view, _html} = settings(conn, id)

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

    # CSET-7, CSET-11: a good value is accepted, and the save goes back to the
    # chat.
    assert_saved(view, %{compaction: compaction()}, id)
    assert Agent.snapshot(id).compaction.options.fraction == 0.8
  end

  # CSET-7, CSET-11: the save is all or nothing — a value that isn't one in
  # either section saves neither — and a rejected save stays on the page with
  # the message and the values as typed.
  test "a rejected save changes neither the limits nor the context options", %{
    conn: conn,
    id: id
  } do
    {:ok, view, _html} = settings(conn, id)

    # Valid limits, an invalid context option: the limits are not saved either.
    refute match?(
             {:error, _},
             submit_settings(view, %{limits: limits("7"), compaction: %{budget: "0"}})
           )

    assert has_element?(view, "#settings-error")
    assert Agent.snapshot(id).limits.max_steps == nil
    refute Agent.snapshot(id).compaction.options[:budget]
    # The typed values stay, in both sections.
    assert has_element?(view, "#limit-steps[value='7']")
    assert has_element?(view, "#compaction-budget[value='0']")

    # And the other way round: an invalid limit saves no context option.
    refute match?(
             {:error, _},
             submit_settings(view, %{limits: limits("nope"), compaction: compaction()})
           )

    assert has_element?(view, "#settings-error")
    assert Agent.snapshot(id).limits.max_steps == nil
    refute Agent.snapshot(id).compaction.options[:fraction]
  end

  # CSET-11, UI-54, CSET-12: the Compact button is on the page (in the Context
  # section) and compacts the chat, then goes back to it.
  test "Compact compacts the chat and goes back to it", %{conn: conn, id: id} do
    :ok = Store.save(id, chat_with_cold_turns())
    {:ok, view, _html} = settings(conn, id)

    assert has_element?(view, "#settings-context #compact-button")

    # CSET-12: the button compacts and returns to the chat.
    assert {:error, {:live_redirect, %{to: to}}} =
             view |> element("#compact-button") |> render_click()

    assert to == "/c/#{id}"
    # COMPACT-10: the cold turns were elided on the spot.
    assert Agent.snapshot(id).compaction.covered > 0
  end

  # CSET-12, UI-54: a chat that is mid-turn stays on the page with the error,
  # rather than going to a chat that can't be compacted yet.
  test "Compact on a chat that is working stays on the page and says so", %{
    conn: conn,
    id: id
  } do
    {:ok, pid} = Agent.ensure_started(id)
    on_exit(fn -> DynamicSupervisor.terminate_child(Elia.Agent.Supervisor, pid) end)

    FakeLLM.push(fn _request, _on_event ->
      Process.sleep(5_000)

      {:ok,
       %{
         message: FakeLLM.assistant([Message.text("late")]),
         stop_reason: :end_turn,
         model: "fake",
         usage: %{}
       }}
    end)

    Agent.subscribe(id)
    :ok = Agent.send_message(id, "go")
    assert_receive {:agent, ^id, {:status, :running}}, 2_000

    {:ok, view, _html} = settings(conn, id)

    html = view |> element("#compact-button") |> render_click()

    # It stays on the page (no redirect) and flashes the error (UI-54).
    assert is_binary(html)
    assert html =~ "Elia is working"
    assert has_element?(view, "#settings-context #compact-button")
  end

  # A chat of several turns, so the older ones are cold and can be elided
  # (COMPACT-12).
  defp chat_with_cold_turns do
    Enum.flat_map(1..8, fn n ->
      [
        Message.user("turn #{n} asks something"),
        %Message{
          role: :assistant,
          content: [Message.text("an answer for turn #{n} " <> String.duplicate("word ", 40))]
        }
      ]
    end)
  end
end
