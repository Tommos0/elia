defmodule EliaWeb.ChatSettingsLive do
  use EliaWeb, :live_view

  alias Elia.{Agent, LLM}
  alias Elia.LLM.Compaction

  # CSET-1: `/c/<id>/settings` opens that chat's settings page; a chat id that
  # isn't valid goes home, as the chat itself does (UI-2).
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if Elia.Store.valid_id?(id),
      do: mount_chat(id, socket),
      else: {:ok, push_navigate(socket, to: ~p"/")}
  end

  defp mount_chat(id, socket) do
    # CSET-4: the same session the chat page uses, so a change made here applies
    # to the chat at once. Starting it writes no chat file (CSET-1).
    {:ok, _pid} = Agent.ensure_started(id)

    if connected?(socket) do
      Agent.subscribe(id)
      Elia.Skills.subscribe()
    end

    snapshot = Agent.snapshot(id)
    {skills, _errors} = Elia.Skills.for_project(snapshot.project)

    socket =
      socket
      |> assign(
        session_id: id,
        # TITLE-1: the chat's own title when it has one, else the derivation
        # from its first user message (STORE-7).
        page_title: Elia.Store.chat_title(id),
        project: snapshot.project,
        selection: LLM.selection(snapshot.selection),
        context_window: LLM.context_window(snapshot.selection),
        auto_approve: snapshot.auto_approve,
        # The auto-approve popover (UI-38): open on the settings page only.
        auto_approve_open: false,
        approvable_tools: approvable_tools(skills),
        # UI-67, UI-68: this chat's jail setting (ISOL-16) and whether the host
        # has a jail at all (ISOL-12, ISOL-20).
        jail: snapshot.jail,
        jail_available: Elia.Shell.jailed?(),
        # LIMIT-1, LIMIT-6: the chat's turn limits and the form that sets them.
        limits: snapshot.limits,
        limits_form: limits_form(snapshot.limits),
        # COMPACT-30: the chat's compaction options and the form that sets them.
        compaction: snapshot.compaction,
        compaction_form: compaction_form(snapshot.compaction),
        # CSET-7: the message of a rejected value, shown until the next change.
        settings_error: nil,
        # The model picker's own state (MODEL-9 to MODEL-13).
        picker_open: false,
        model_query: "",
        search_form: to_form(%{"q" => ""}, as: :model_search),
        # provider key => :loading | {:ok, models} | {:error, message}
        catalogs: %{}
      )
      |> stream(:models, [])

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-10 sm:px-6">
          <.link
            navigate={~p"/c/#{@session_id}"}
            id="chat-settings-back"
            class="flex items-center gap-1.5 text-sm text-base-content/60 transition hover:text-base-content"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to chat
          </.link>

          <h1 id="chat-settings-title" class="mt-3 text-2xl font-semibold tracking-tight">
            {@page_title}
          </h1>
          <%!-- CSET-2: the chat's own facts, which the chat page doesn't show. --%>
          <p
            id="chat-settings-project"
            class="mt-1 flex items-center gap-1.5 text-sm text-base-content/60"
          >
            <.icon name="hero-rectangle-stack" class="size-4 shrink-0" />
            <span>Project</span>
            <.link navigate={~p"/projects"} class="font-medium text-base-content hover:underline">
              {@project.name}
            </.link>
          </p>

          <p
            :if={@settings_error}
            id="settings-error"
            class="mt-4 flex items-start gap-2 rounded-lg bg-error/10 px-3 py-2 text-xs text-error"
          >
            <.icon name="hero-exclamation-triangle" class="mt-px size-4 shrink-0" />
            <span class="break-words">{@settings_error}</span>
          </p>

          <h2 class="mt-8 text-xs font-medium uppercase tracking-wider text-base-content/50">
            Settings for this chat
          </h2>
          <p class="mt-1 text-xs text-base-content/50">
            These belong to this chat alone. Nothing here is shared with another chat.
          </p>

          <div class="mt-4 space-y-4">
            <%!-- CSET-5: Model (MODEL-9 to MODEL-13) --%>
            <section
              id="settings-model"
              class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
            >
              <h2 class="font-medium">Model</h2>
              <p class="mt-0.5 text-xs text-base-content/50">
                Which provider and model this chat talks to. A new turn uses it.
              </p>
              <div class="mt-4">
                <.model_picker
                  selection={@selection}
                  open={@picker_open}
                  search_form={@search_form}
                  streams={@streams}
                />
              </div>
            </section>

            <%!-- CSET-5: Auto-approve (UI-38 to UI-42) --%>
            <section
              id="settings-auto-approve"
              class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
            >
              <h2 class="font-medium">Auto-approve</h2>
              <p class="mt-0.5 text-xs text-base-content/50">
                Tools this chat runs without asking you each time. A tool that denies a
                call by policy is still refused.
              </p>
              <div class="mt-4">
                <.auto_approve_picker
                  open={@auto_approve_open}
                  tools={@approvable_tools}
                  enabled={@auto_approve}
                />
              </div>
            </section>

            <%!-- CSET-5: Jail (UI-67, UI-68, ISOL-16) --%>
            <section
              id="settings-jail"
              class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
            >
              <h2 class="font-medium">Jail</h2>
              <p class="mt-0.5 text-xs text-base-content/50">
                Whether this chat's commands run in a bubblewrap jail holding the workspace
                and the toolchain, and nothing else.
              </p>
              <div class="mt-4">
                <.jail_toggle on={@jail} available={@jail_available} />
              </div>
            </section>

            <%!-- CSET-7: one form with one Save holds every numeric setting on the
            page — the turn's limits below and the context options after them — so
            the save is all or nothing, and an accepted one goes back to the chat
            (CSET-11). --%>
            <.form for={%{}} id="settings-form" phx-submit="save_settings" class="space-y-4">
              <%!-- CSET-5, LIMIT-6: the turn's limits --%>
              <section
                id="settings-limits"
                class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
              >
                <h2 class="font-medium">Limits</h2>
                <p class="mt-0.5 text-xs text-base-content/50">
                  How far one turn may go before Elia stops. Leave a field empty for the
                  default: limits apply from the next turn.
                </p>

                <div class="mt-4 space-y-3">
                  <div class="flex flex-wrap gap-4">
                    <label class="flex-1 basis-40">
                      <span class="text-xs font-medium text-base-content/70">Steps per turn</span>
                      <input
                        type="text"
                        inputmode="numeric"
                        id="limit-steps"
                        name="limits[max_steps]"
                        value={@limits_form["max_steps"]}
                        placeholder="100"
                        class="mt-1 w-full rounded-xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                      />
                      <span class="mt-1 block text-[11px] text-base-content/40">
                        Empty: the loop's own default, 100 steps.
                      </span>
                    </label>
                    <label class="flex-1 basis-40">
                      <span class="text-xs font-medium text-base-content/70">
                        Time budget (minutes)
                      </span>
                      <input
                        type="text"
                        inputmode="decimal"
                        id="limit-minutes"
                        name="limits[max_minutes]"
                        value={@limits_form["max_minutes"]}
                        placeholder="none"
                        class="mt-1 w-full rounded-xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                      />
                      <span class="mt-1 block text-[11px] text-base-content/40">
                        Empty: no time budget. Time spent waiting for your approval doesn't
                        count.
                      </span>
                    </label>
                  </div>
                </div>

                <%!-- CSET-7, LIMIT-6: an on/off setting is a switch (UI-42, UI-67): it
                applies the moment it is clicked, and says its state in words. --%>
                <div class="mt-3 rounded-xl bg-base-200/50 px-3 py-2">
                  <.switch
                    id="limit-pause"
                    on={@limits.pause_on_limit}
                    click="toggle_limit_pause"
                    label="Pause at a limit"
                  />
                  <p class="mt-1 text-[11px] text-base-content/50">
                    Off: a turn that reaches a limit stops with an error. On: it pauses, and you
                    can continue it with a fresh budget or fail it.
                  </p>
                  <p id="limits-state" class="mt-2 text-xs text-base-content/50">
                    {limits_state(@limits)}
                  </p>
                </div>
              </section>

              <%!-- CSET-5, COMPACT-30: this chat's compaction options --%>
              <section
                id="settings-context"
                class="rounded-2xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm"
              >
                <h2 class="font-medium">Context</h2>
                <p class="mt-0.5 text-xs text-base-content/50">
                  What this chat sends the model once it grows long. The transcript always keeps
                  the whole conversation; only what the model is sent is reduced.
                </p>

                <div class="mt-4 space-y-3">
                  <div class="flex flex-wrap gap-4">
                    <label class="flex-1 basis-40">
                      <span class="text-xs font-medium text-base-content/70">Budget (tokens)</span>
                      <input
                        type="text"
                        inputmode="numeric"
                        id="compaction-budget"
                        name="compaction[budget]"
                        value={@compaction_form["budget"]}
                        class="mt-1 w-full rounded-xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                      />
                    </label>
                    <label class="flex-1 basis-40">
                      <span class="text-xs font-medium text-base-content/70">
                        Fraction of the window (%)
                      </span>
                      <input
                        type="text"
                        inputmode="numeric"
                        id="compaction-fraction"
                        name="compaction[fraction]"
                        value={@compaction_form["fraction"]}
                        class="mt-1 w-full rounded-xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                      />
                    </label>
                  </div>

                  <div class="flex flex-wrap gap-4">
                    <label class="flex-1 basis-40">
                      <span class="text-xs font-medium text-base-content/70">
                        Target (% of the trigger)
                      </span>
                      <input
                        type="text"
                        inputmode="numeric"
                        id="compaction-target"
                        name="compaction[target_fraction]"
                        value={@compaction_form["target_fraction"]}
                        class="mt-1 w-full rounded-xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                      />
                    </label>
                    <label class="flex-1 basis-40">
                      <span class="text-xs font-medium text-base-content/70">
                        Working set (turns)
                      </span>
                      <input
                        type="text"
                        inputmode="numeric"
                        id="compaction-working-set"
                        name="compaction[working_set]"
                        value={@compaction_form["working_set"]}
                        class="mt-1 w-full rounded-xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm outline-none transition focus:border-primary focus:bg-base-100"
                      />
                      <span class="mt-1 block text-[11px] text-base-content/40">
                        The most recent turns kept as they are.
                      </span>
                    </label>
                  </div>

                  <p id="compaction-trigger" class="text-xs text-base-content/50">
                    {compaction_trigger_note(@compaction, @context_window)}
                  </p>
                </div>

                <%!-- CSET-7, COMPACT-30: automatic compaction is a switch. --%>
                <div class="mt-3 rounded-xl bg-base-200/50 px-3 py-2">
                  <.switch
                    id="compaction-auto"
                    on={compaction_options(@compaction).auto}
                    click="toggle_compaction_auto"
                    label="Compact automatically"
                  />
                  <p class="mt-1 text-[11px] text-base-content/50">
                    Off: nothing is reduced until you press Compact below.
                  </p>
                </div>

                <%!-- UI-54, COMPACT-10, CSET-12: compact this chat now, on demand. The
                transcript is where the result shows, so the button goes back to the
                chat. --%>
                <div class="mt-3 flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    id="compact-button"
                    phx-click="compact"
                    title="Elide the older turns of this chat's context now"
                    class="group flex items-center gap-1.5 rounded-lg border border-base-300 px-2.5 py-1 text-xs text-base-content/70 transition hover:border-base-content/20 hover:text-base-content"
                  >
                    <.icon
                      name="hero-archive-box-arrow-down"
                      class="size-3.5 shrink-0 opacity-70"
                    />
                    <span class="font-medium">Compact</span>
                  </button>
                  <span class="text-[11px] text-base-content/50">
                    Elides this chat's older turns now, whatever the trigger.
                  </span>
                </div>
              </section>

              <%!-- CSET-7, CSET-11: the page's one Save, for every numeric setting
              above. --%>
              <div class="flex flex-wrap items-center justify-end gap-3">
                <span class="text-xs text-base-content/50">
                  Saves this chat's limits and context options.
                </span>
                <button
                  type="submit"
                  id="save-settings"
                  class="flex h-9 items-center gap-1.5 rounded-xl bg-primary px-4 text-sm font-medium text-primary-content transition hover:brightness-110"
                >
                  Save
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :on, :boolean, required: true
  attr :label, :string, required: true
  attr :click, :string, required: true

  # CSET-7: a setting that is on or off is a switch, like the jail one (UI-67),
  # so it applies at once and says its state in words (UI-42).
  defp switch(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <button
        type="button"
        id={@id}
        phx-click={@click}
        role="switch"
        aria-checked={to_string(@on)}
        class={[
          "group inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition",
          @on && "border-primary/50 bg-primary/5 text-primary",
          !@on && "border-base-300 text-base-content/70 hover:border-base-content/20"
        ]}
      >
        <span class="font-medium">{@label}</span>
        <span id={"#{@id}-state"} class="font-medium">{if @on, do: "On", else: "Off"}</span>
      </button>
    </div>
    """
  end

  attr :on, :boolean, required: true
  attr :available, :boolean, required: true

  # UI-67, UI-68: the chat's jail switch. A host with no jail (ISOL-12, ISOL-20)
  # can't protect a chat, so the switch is disabled and says so rather than
  # claiming it does.
  defp jail_toggle(assigns) do
    assigns = assign(assigns, :jailed, assigns.on and assigns.available)

    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <button
        type="button"
        id="jail-toggle"
        phx-click="toggle_jail"
        role="switch"
        aria-checked={to_string(@jailed)}
        disabled={!@available}
        title={jail_title(@jailed, @available)}
        class={[
          "group flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition disabled:cursor-not-allowed",
          @jailed && "border-primary/50 bg-primary/5 text-primary",
          !@jailed && @available &&
            "border-warning/50 bg-warning/5 text-warning hover:border-warning/70",
          !@available && "border-base-300 text-base-content/40"
        ]}
      >
        <.icon
          name={if @jailed, do: "hero-lock-closed", else: "hero-lock-open"}
          class="size-3.5 shrink-0 opacity-70"
        />
        <span class="font-medium">Jail</span>
        <span id="jail-state" class="font-medium">{jail_state(@jailed)}</span>
      </button>
      <span :if={!@available} id="jail-unavailable" class="text-xs text-base-content/50">
        This host has no jail (bubblewrap is unavailable), so commands run unjailed.
      </span>
      <span :if={@available and !@on} id="jail-warning" class="text-xs text-warning">
        Commands run unjailed: they can read the settings database and your credentials.
      </span>
    </div>
    """
  end

  defp jail_state(true), do: "Jailed"
  defp jail_state(false), do: "Not jailed"

  defp jail_title(true, _available),
    do: "Commands run in a jail holding the workspace and the toolchain, and nothing else"

  defp jail_title(false, true), do: "Commands run unjailed, on the whole machine"
  defp jail_title(false, false), do: "This host has no jail, so commands run unjailed"

  attr :open, :boolean, required: true
  attr :tools, :list, required: true
  attr :enabled, :list, required: true

  # UI-38, UI-39
  defp auto_approve_picker(assigns) do
    ~H"""
    <div class="relative inline-block max-w-full">
      <button
        type="button"
        id="auto-approve-button"
        phx-click="toggle_auto_approve_picker"
        aria-haspopup="true"
        aria-expanded={to_string(@open)}
        class={[
          "group flex items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition",
          @open && "border-primary/50 bg-primary/5",
          !@open &&
            "border-base-300 text-base-content/70 hover:border-base-content/20 hover:text-base-content"
        ]}
      >
        <.icon name="hero-shield-check" class="size-3.5 shrink-0 opacity-70" />
        <span class="font-medium">Auto-approve</span>
        <span
          :if={@enabled != []}
          id="auto-approve-count"
          class="rounded-full bg-warning/20 px-1.5 text-[11px] font-medium tabular-nums text-warning"
        >
          {length(@enabled)}
        </span>
      </button>

      <div
        :if={@open}
        id="auto-approve"
        phx-click-away="close_auto_approve_picker"
        phx-window-keydown="close_auto_approve_picker"
        phx-key="Escape"
        class="absolute top-full left-0 z-30 mt-2 w-[min(22rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl shadow-base-content/5 motion-safe:animate-[picker-in_120ms_ease-out]"
      >
        <p class="border-b border-base-300 px-3 py-2 text-xs text-base-content/60">
          Auto-approved tools run in this chat without asking.
        </p>
        <ul class="max-h-72 overflow-y-auto py-1">
          <li :for={tool <- @tools} class="px-1">
            <button
              type="button"
              id={"auto-approve-#{tool.name}"}
              phx-click="toggle_auto_approve"
              phx-value-tool={tool.name}
              role="switch"
              aria-checked={to_string(tool.name in @enabled)}
              class="flex w-full items-center gap-3 rounded-lg px-2 py-1.5 text-left text-sm transition hover:bg-base-200"
            >
              <.icon name={tool_icon(tool.name)} class="size-4 shrink-0 text-base-content/60" />
              <span class="min-w-0 flex-1 truncate font-medium">{tool.name}</span>
              <span
                id={"auto-approve-state-#{tool.name}"}
                class={[
                  "text-xs font-medium",
                  tool.name in @enabled && "text-warning",
                  tool.name not in @enabled && "text-base-content/50"
                ]}
              >
                {if tool.name in @enabled, do: "On", else: "Off"}
              </span>
              <span class={[
                "relative h-5 w-9 shrink-0 rounded-full transition",
                tool.name in @enabled && "bg-warning",
                tool.name not in @enabled && "bg-base-300"
              ]}>
                <span class={[
                  "absolute top-0.5 size-4 rounded-full bg-base-100 shadow transition-all",
                  tool.name in @enabled && "left-[1.125rem]",
                  tool.name not in @enabled && "left-0.5"
                ]} />
              </span>
            </button>
          </li>
          <li :if={@tools == []} class="px-3 py-2 text-xs text-base-content/40">
            No tools need approval
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp tool_icon("shell"), do: "hero-command-line"
  defp tool_icon(name) when name in ~w(read_file write_file edit_file), do: "hero-document-text"
  defp tool_icon("spawn_task"), do: "hero-rectangle-stack"
  defp tool_icon(_name), do: "hero-wrench-screwdriver"

  attr :selection, :map, required: true
  attr :open, :boolean, required: true
  attr :search_form, :any, required: true
  attr :streams, :any, required: true

  defp model_picker(assigns) do
    ~H"""
    <div class="relative inline-block max-w-full">
      <button
        type="button"
        id="model-picker-button"
        phx-click={if @open, do: "close_picker", else: "open_picker"}
        aria-haspopup="listbox"
        aria-expanded={to_string(@open)}
        class={[
          "group flex max-w-full items-center gap-1.5 rounded-lg border px-2.5 py-1 text-xs transition",
          @open && "border-primary/50 bg-primary/5",
          !@open &&
            "border-base-300 text-base-content/70 hover:border-base-content/20 hover:text-base-content"
        ]}
      >
        <.provider_badge provider={@selection.provider} id="selected-provider" />
        <span id="selected-model" class="truncate font-medium">{@selection.name}</span>
        <.icon
          name="hero-chevron-up-down"
          class="size-3.5 shrink-0 opacity-60 transition group-hover:opacity-100"
        />
      </button>

      <div
        :if={@open}
        id="model-picker"
        phx-click-away="close_picker"
        phx-window-keydown="close_picker"
        phx-key="Escape"
        class="absolute top-full left-0 z-30 mt-2 flex max-h-[28rem] w-[min(28rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl shadow-base-content/5 motion-safe:animate-[picker-in_120ms_ease-out]"
      >
        <.form
          for={@search_form}
          id="model-search-form"
          phx-change="search_models"
          phx-submit="search_models"
          class="border-b border-base-300 p-2"
        >
          <label class="flex items-center gap-2 rounded-lg bg-base-200/60 px-2.5 focus-within:ring-1 focus-within:ring-primary/50">
            <.icon name="hero-magnifying-glass" class="size-4 shrink-0 text-base-content/40" />
            <input
              type="text"
              id="model-search"
              name={@search_form[:q].name}
              value={@search_form[:q].value}
              placeholder="Search models…"
              autocomplete="off"
              phx-debounce="120"
              phx-mounted={JS.focus()}
              class="h-9 w-full bg-transparent text-sm outline-none"
            />
          </label>
        </.form>
        <ul id="model-list" phx-update="stream" role="listbox" class="flex-1 overflow-y-auto py-1">
          <li :for={{dom_id, entry} <- @streams.models} id={dom_id}>
            <.model_entry entry={entry} selection={@selection} />
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :selection, :map, required: true

  defp model_entry(%{entry: %{kind: :header}} = assigns) do
    ~H"""
    <div
      id={"group-#{@entry.provider}"}
      class="sticky top-0 z-10 flex items-center gap-2 border-b border-base-300/60 bg-base-100/95 px-3 py-2 backdrop-blur [li:not(:first-child)>&]:mt-1 [li:not(:first-child)>&]:border-t"
    >
      <.provider_badge provider={@entry.provider} />
      <span class="truncate text-[11px] text-base-content/50">{provider_route(@entry.provider)}</span>
      <span :if={@entry.count} class="ml-auto text-[11px] tabular-nums text-base-content/40">
        {@entry.count}
      </span>
    </div>
    <%= case @entry.status do %>
      <% :loading -> %>
        <div class="flex items-center gap-2 px-3 py-2 text-xs text-base-content/50">
          <.icon name="hero-arrow-path" class="size-3.5 motion-safe:animate-spin" /> Loading models…
        </div>
      <% :no_key -> %>
        <.link
          navigate={~p"/settings"}
          id={"add-key-#{@entry.provider}"}
          class="mx-2 mb-1 flex items-center gap-2 rounded-lg px-2 py-2 text-xs text-primary transition hover:bg-primary/10"
        >
          <.icon name="hero-key" class="size-3.5" /> Add an API key in Settings
          <.icon name="hero-arrow-right" class="ml-auto size-3.5" />
        </.link>
      <% {:error, message} -> %>
        <div
          id={"catalog-error-#{@entry.provider}"}
          class="mx-2 mb-1 flex items-start gap-2 rounded-lg bg-error/10 px-2 py-2 text-xs text-error"
        >
          <.icon name="hero-exclamation-triangle" class="mt-px size-3.5 shrink-0" />
          <span class="break-words">{message}</span>
        </div>
      <% :empty -> %>
        <p class="px-3 py-2 text-xs text-base-content/40">No matching models</p>
      <% _ -> %>
    <% end %>
    """
  end

  defp model_entry(assigns) do
    assigns =
      assign(assigns,
        selected?:
          assigns.selection.provider == assigns.entry.provider and
            assigns.selection.model == assigns.entry.model
      )

    ~H"""
    <button
      type="button"
      role="option"
      aria-selected={to_string(@selected?)}
      phx-click="select_model"
      phx-value-provider={@entry.provider}
      phx-value-model={@entry.model}
      phx-value-name={@entry.name}
      class={[
        "group mx-1 flex w-[calc(100%-0.5rem)] items-center gap-3 rounded-lg px-2 py-1.5 text-left transition",
        @selected? && "bg-primary/10",
        !@selected? && "hover:bg-base-200"
      ]}
    >
      <div class="min-w-0 flex-1">
        <p class={["truncate text-sm", @selected? && "font-medium text-primary"]}>{@entry.name}</p>
        <p class="flex min-w-0 items-center gap-1.5">
          <.provider_badge provider={@entry.provider} size="xs" />
          <span class="truncate font-mono text-[11px] text-base-content/40">{@entry.model}</span>
        </p>
      </div>
      <div class="shrink-0 text-right text-[11px] leading-tight text-base-content/50">
        <p :if={@entry.context_length}>{format_context(@entry.context_length)}</p>
        <p :if={@entry.prompt_price}>
          {format_price(@entry.prompt_price)} / {format_price(@entry.completion_price)}
        </p>
      </div>
      <.icon
        name="hero-check"
        class={["size-4 shrink-0 text-primary", !@selected? && "invisible"]}
      />
    </button>
    """
  end

  defp provider_route("anthropic"), do: "Direct from the Anthropic API"
  defp provider_route("openrouter"), do: "Many vendors, routed via OpenRouter"
  defp provider_route(_key), do: ""

  defp format_context(tokens) when tokens >= 1_000_000,
    do: "#{Float.round(tokens / 1_000_000, 1) |> trim_float()}M ctx"

  defp format_context(tokens) when tokens >= 1000, do: "#{div(tokens, 1000)}K ctx"
  defp format_context(tokens), do: "#{tokens} ctx"

  defp format_tokens(tokens) when tokens >= 1_000_000,
    do: "#{Float.round(tokens / 1_000_000, 1) |> trim_float()}M"

  defp format_tokens(tokens) when tokens >= 1000, do: "#{div(tokens, 1000)}K"
  defp format_tokens(tokens), do: "#{tokens}"

  defp format_price(nil), do: "?"
  defp format_price(price) when price == 0, do: "free"
  defp format_price(price) when price < 0.1, do: "$#{Float.round(price, 3) |> trim_float()}"
  defp format_price(price), do: "$#{Float.round(price, 2) |> trim_float()}"

  defp trim_float(float) do
    if float == Float.round(float), do: trunc(float), else: float
  end

  # LIMIT-6: the settings as they stand, and what reaching a limit does.
  defp limits_state(limits) do
    steps = if limits.max_steps, do: "#{limits.max_steps} steps", else: "the default 100 steps"

    time =
      if limits.max_minutes,
        do: "a budget of #{limits.max_minutes} minutes",
        else: "no time budget"

    at_limit =
      if limits.pause_on_limit do
        "reaching either pauses the turn for you to continue or fail"
      else
        "reaching either ends the turn with an error"
      end

    "This chat runs at most #{steps} per turn, with #{time}; #{at_limit}."
  end

  # COMPACT-30: the trigger these values give for the chat's model window, or
  # that there is none to compute one from (COMPACT-6, COMPACT-7).
  defp compaction_trigger_note(compaction, context_window) do
    options = compaction_options(compaction)

    case Compaction.trigger(context_window && context_window.context_length, options) do
      nil ->
        "No context window is known for the selected model, so nothing is compacted automatically."

      trigger ->
        "This chat compacts when the request passes #{format_tokens(trigger)} tokens, " <>
          "reducing it to #{format_tokens(round(trigger * options.target_fraction))}."
    end
  end

  ## Forms

  # LIMIT-6: what the form shows. An empty field is a limit this chat doesn't
  # set, so the loop's own default applies (LIMIT-1). `pause_on_limit` is its own
  # switch (CSET-7).
  defp limits_form(limits) do
    %{
      "max_steps" => blank_to_empty(limits.max_steps),
      "max_minutes" => blank_to_empty(limits.max_minutes)
    }
  end

  # COMPACT-30: the effective options, with the fractions shown as percentages.
  # Whether automatic compaction is on is the section's switch (CSET-7).
  defp compaction_form(compaction) do
    options = compaction_options(compaction)

    %{
      "budget" => Integer.to_string(options.budget),
      "fraction" => format_percent(options.fraction),
      "target_fraction" => format_percent(options.target_fraction),
      "working_set" => Integer.to_string(options.working_set)
    }
  end

  # The chat's compaction options, defaults included (COMPACT-9).
  defp compaction_options(compaction), do: Compaction.options(compaction.options)

  defp blank_to_empty(nil), do: ""
  defp blank_to_empty(value), do: to_string(value)

  defp format_percent(fraction) when is_number(fraction),
    do: fraction |> Kernel.*(100) |> Float.round(2) |> trim_float() |> to_string()

  defp format_percent(fraction), do: to_string(fraction)

  # A number from a field: an empty field is "no limit" (nil), and anything that
  # isn't a number is passed on so it is rejected with a message (LIMIT-7).
  defp parse_number(nil), do: nil

  defp parse_number(value) do
    case value |> to_string() |> String.trim() do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {integer, ""} ->
            integer

          _ ->
            case Float.parse(trimmed) do
              {float, ""} -> float
              _ -> trimmed
            end
        end
    end
  end

  # CSET-7: a rejected save keeps the values as they were typed, so the user can
  # correct the one that isn't a number.
  defp submitted_limits_form(params) do
    %{
      "max_steps" => to_string(params["max_steps"] || ""),
      "max_minutes" => to_string(params["max_minutes"] || "")
    }
  end

  # COMPACT-30: the submitted compaction options, or the message for the first
  # value that isn't one.
  defp compaction_changes(params) do
    with {:ok, budget} <-
           positive_integer(params["budget"], "The budget must be a whole number of tokens"),
         {:ok, fraction} <-
           percent(params["fraction"], "The fraction of the window must be a percentage"),
         {:ok, target} <-
           percent(params["target_fraction"], "The target must be a percentage of the trigger"),
         {:ok, working_set} <-
           positive_integer(
             params["working_set"],
             "The working set must be a whole number of turns"
           ) do
      {:ok,
       %{
         budget: budget,
         fraction: fraction,
         target_fraction: target,
         working_set: working_set
       }}
    end
  end

  defp positive_integer(value, message) do
    case parse_number(value) do
      integer when is_integer(integer) and integer > 0 -> {:ok, integer}
      _ -> {:error, "#{message} above 0."}
    end
  end

  defp percent(value, message) do
    case parse_number(value) do
      number when is_number(number) and number > 0 and number <= 100 -> {:ok, number / 100}
      _ -> {:error, "#{message} above 0 and at most 100."}
    end
  end

  @doc "DOM id of a model in the picker (ids contain `/`, `:` and `.`)."
  def model_dom_id(provider, model),
    do: "models-m-#{provider}-#{Base.url_encode64(model, padding: false)}"

  ## Events

  @impl true
  # UI-67, SESS-30: turn this chat's jail on or off. The switch follows the
  # session's broadcast, so every view of the chat stays in sync.
  def handle_event("toggle_jail", _params, socket) do
    Agent.set_jail(socket.assigns.session_id, not socket.assigns.jail)
    {:noreply, socket}
  end

  def handle_event("toggle_auto_approve", %{"tool" => tool}, socket) do
    set_auto_approve(socket, tool, tool not in socket.assigns.auto_approve)
  end

  # UI-40, APPR-11: the chat's "Always allow" button also turns auto-approval on.
  def handle_event("always_allow", %{"tool" => tool}, socket) do
    set_auto_approve(socket, tool, true)
  end

  def handle_event("toggle_auto_approve_picker", _params, socket) do
    {:noreply, assign(socket, auto_approve_open: !socket.assigns.auto_approve_open)}
  end

  def handle_event("close_auto_approve_picker", _params, socket) do
    {:noreply, assign(socket, auto_approve_open: false)}
  end

  # CSET-7, CSET-11: the page's one Save sets every numeric setting at once — the
  # turn limits (LIMIT-6, LIMIT-7) and the compaction options (COMPACT-30) — or
  # changes nothing and names the first value that isn't one. `pause_on_limit`
  # and automatic compaction are the switches above (CSET-7), so they aren't part
  # of the form. A save the chat accepts goes back to the chat, where the
  # settings show up (CSET-4).
  def handle_event("save_settings", params, socket) do
    limit_params = params["limits"] || %{}
    compaction_params = params["compaction"] || %{}

    limits = %{
      max_steps: parse_number(limit_params["max_steps"]),
      max_minutes: parse_number(limit_params["max_minutes"])
    }

    with {:ok, limits} <- Elia.Limits.validate(limits),
         {:ok, options} <- compaction_changes(compaction_params) do
      :ok = Agent.set_limits(socket.assigns.session_id, limits)
      :ok = Agent.set_compaction(socket.assigns.session_id, options)
      {:noreply, push_navigate(socket, to: ~p"/c/#{socket.assigns.session_id}")}
    else
      {:error, message} ->
        {:noreply, reject_settings(socket, limit_params, compaction_params, message)}
    end
  end

  # CSET-12, COMPACT-10, UI-54: compact this chat now, whatever the trigger, and
  # go back to the chat, where the transcript shows what was elided. A chat that
  # is mid-turn stays here with the error.
  def handle_event("compact", _params, socket) do
    case Agent.compact(socket.assigns.session_id) do
      :ok ->
        {:noreply, push_navigate(socket, to: ~p"/c/#{socket.assigns.session_id}")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Elia is working; try again in a moment.")}
    end
  end

  # LIMIT-6, CSET-7: whether reaching a limit pauses the turn (LIMIT-4).
  def handle_event("toggle_limit_pause", _params, socket) do
    Agent.set_limits(socket.assigns.session_id, %{
      pause_on_limit: not socket.assigns.limits.pause_on_limit
    })

    {:noreply, socket}
  end

  # COMPACT-30: automatic compaction for this chat (COMPACT-9).
  def handle_event("toggle_compaction_auto", _params, socket) do
    auto = not compaction_options(socket.assigns.compaction).auto
    :ok = Agent.set_compaction(socket.assigns.session_id, %{auto: auto})
    {:noreply, socket}
  end

  def handle_event("open_picker", _params, socket) do
    catalogs =
      for info <- LLM.providers(), LLM.api_key(info.key) != nil, into: %{} do
        case socket.assigns.catalogs[info.key] do
          {:ok, _} = loaded -> {info.key, loaded}
          _ -> {info.key, :loading}
        end
      end

    socket =
      Enum.reduce(catalogs, socket, fn
        {key, :loading}, socket -> start_async(socket, {:catalog, key}, fn -> LLM.models(key) end)
        _loaded, socket -> socket
      end)

    socket
    |> assign(
      picker_open: true,
      catalogs: catalogs,
      model_query: "",
      search_form: to_form(%{"q" => ""}, as: :model_search)
    )
    |> stream_models()
    |> noreply()
  end

  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, picker_open: false)}
  end

  def handle_event("search_models", %{"model_search" => %{"q" => query}}, socket) do
    socket
    |> assign(model_query: query, search_form: to_form(%{"q" => query}, as: :model_search))
    |> stream_models()
    |> noreply()
  end

  def handle_event("select_model", %{"provider" => key, "model" => model} = params, socket) do
    case Agent.select_model(socket.assigns.session_id, key, model, params["name"]) do
      {:ok, selection} ->
        socket
        |> assign(selection: selection, context_window: LLM.context_window(selection))
        |> assign(picker_open: false)
        |> noreply()

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_async({:catalog, key}, result, socket) do
    catalog =
      case result do
        {:ok, {:ok, models}} -> {:ok, models}
        {:ok, {:error, message}} -> {:error, message}
        {:exit, reason} -> {:error, "Could not load models: #{Exception.format_exit(reason)}"}
      end

    socket
    |> assign(
      catalogs: Map.put(socket.assigns.catalogs, key, catalog),
      context_window: LLM.context_window(socket.assigns.selection)
    )
    |> stream_models()
    |> noreply()
  end

  @impl true
  def handle_info({:agent, _id, event}, socket), do: {:noreply, apply_event(event, socket)}

  # PROJ-24: a skills reload carries Elia's own skills; a chat in another project
  # re-resolves that project's skills instead.
  def handle_info({:skills_reloaded, skills}, socket) do
    {skills, _instructions} = project_skills(socket.assigns.project, skills)
    {:noreply, assign(socket, approvable_tools: approvable_tools(skills))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # CSET-3: every control follows the chat's own events, so a change made on the
  # chat page or in another tab shows up here too.
  defp apply_event({:model, selection}, socket) do
    socket
    |> assign(selection: selection, context_window: LLM.context_window(selection))
    |> stream_models()
  end

  defp apply_event({:auto_approve, names}, socket), do: assign(socket, auto_approve: names)
  defp apply_event({:jail, on?}, socket), do: assign(socket, jail: on?)

  defp apply_event({:limits, limits}, socket),
    do: assign(socket, limits: limits, limits_form: limits_form(limits))

  defp apply_event({:compaction, compaction}, socket),
    do: assign(socket, compaction: compaction, compaction_form: compaction_form(compaction))

  # The chat's other events (deltas, tool status, tasks) have nothing to say on
  # this page.
  defp apply_event(_event, socket), do: socket

  # CSET-11: a rejected save changes nothing and leaves the user on the page,
  # with the message and the values as they were typed, so they can be corrected
  # (CSET-7).
  defp reject_settings(socket, limit_params, compaction_params, message) do
    assign(socket,
      settings_error: message,
      limits_form: Map.merge(socket.assigns.limits_form, submitted_limits_form(limit_params)),
      compaction_form: Map.merge(socket.assigns.compaction_form, compaction_params)
    )
  end

  defp noreply(socket), do: {:noreply, socket}

  defp set_auto_approve(socket, tool, on?) do
    case Agent.set_auto_approve(socket.assigns.session_id, tool, on?) do
      :ok ->
        {:noreply, socket}

      {:error, :not_approvable} ->
        {:noreply, put_flash(socket, :error, "#{tool} never asks for approval.")}
    end
  end

  # UI-38: tools the user can auto-approve: those that can need approval (APPR-13).
  defp approvable_tools(skills) do
    skills
    |> Elia.Skills.tools()
    |> Enum.filter(&(&1.approval != :never))
    |> Enum.sort_by(& &1.name)
  end

  defp project_skills(%{harness?: true} = project, broadcast_skills),
    do: {broadcast_skills, Elia.Skills.project_instructions(project.folder)}

  defp project_skills(project, _broadcast_skills) do
    {skills, _errors} = Elia.Skills.for_project(project)
    {skills, Elia.Skills.project_instructions(project.folder)}
  end

  # Rebuilds the picker list: a header per provider, then its matching models.
  defp stream_models(%{assigns: %{picker_open: false}} = socket), do: socket

  defp stream_models(socket) do
    query = socket.assigns.model_query |> String.trim() |> String.downcase()

    entries =
      Enum.flat_map(LLM.providers(), fn info ->
        header = %{id: "g-#{info.key}", kind: :header, provider: info.key, name: info.name}

        case socket.assigns.catalogs[info.key] do
          nil ->
            [Map.merge(header, %{status: :no_key, count: nil})]

          {:ok, models} ->
            matches = Enum.filter(models, &model_matches?(&1, query))
            status = if matches == [], do: :empty, else: :ok

            count =
              if query == "", do: length(models), else: "#{length(matches)}/#{length(models)}"

            [Map.merge(header, %{status: status, count: count})] ++
              Enum.map(matches, &model_entry_data(info.key, &1))

          other ->
            [Map.merge(header, %{status: other, count: nil})]
        end
      end)

    stream(socket, :models, entries, reset: true)
  end

  defp model_matches?(_model, ""), do: true

  defp model_matches?(model, query) do
    String.contains?(String.downcase(model.name), query) or
      String.contains?(String.downcase(model.id), query)
  end

  defp model_entry_data(key, model) do
    "models-" <> id = model_dom_id(key, model.id)

    %{
      id: id,
      kind: :model,
      provider: key,
      model: model.id,
      name: model.name,
      context_length: model[:context_length],
      prompt_price: model[:prompt_price],
      completion_price: model[:completion_price]
    }
  end
end
