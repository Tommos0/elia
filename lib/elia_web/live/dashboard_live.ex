defmodule EliaWeb.DashboardLive do
  @moduledoc """
  The dashboard at `/` (DASH): where you left off, what needs you, recent chats,
  your projects, the machine's health and the deploy state. It renders a page
  and nothing else — it starts no session, creates no chat and writes nothing
  (DASH-1); opening a chat is one tap away, through `/chats` (UI-77) or a chat
  row.

  The chat lists follow the registry (`Elia.Agent.awaiting_approval/0`,
  `paused/0`, `running/0`, SESS-19) the way the sidebar does, so the same
  indicator shows the same thing on both pages (UI-59, `EliaWeb.ChatStatus`).
  """
  use EliaWeb, :live_view

  alias Elia.{Agent, Deploy, Projects, Store, SystemStats}
  alias EliaWeb.{ChatStatus, TimeAgo}

  # DASH-8, DASH-10, DASH-11: how often each card refreshes while connected.
  @stats_tick :timer.seconds(2)
  @time_tick :timer.minutes(1)
  @deploy_tick :timer.seconds(10)
  # DASH-7: how many recent chats the card lists.
  @recent 8
  # DASH-5: how many interrupted chats are listed before "and N more".
  @interrupted_rows 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Agent.subscribe_activity()
      :timer.send_interval(@stats_tick, :stats)
      :timer.send_interval(@time_tick, :tick)
      :timer.send_interval(@deploy_tick, :deploy)
    end

    {:ok,
     socket
     |> assign(page_title: "Home", prev: nil, deploy: Deploy.status())
     |> refresh()
     |> update_stats(sample())}
  end

  # DASH-8: a turn that starts, ends or begins waiting for approval arrives here
  # (SESS-19), and the lists are rebuilt from the store and the registry, so a
  # chat that appeared or changed is right without a reload.
  @impl true
  def handle_info({:chat_status, _id, _status}, socket), do: {:noreply, refresh(socket)}

  def handle_info(:stats, socket), do: {:noreply, update_stats(socket, sample())}

  def handle_info(:deploy, socket), do: {:noreply, assign(socket, deploy: Deploy.status())}

  # DASH-3, DASH-7: the relative times, refreshed every minute (UI-34).
  def handle_info(:tick, socket), do: {:noreply, assign(socket, now: DateTime.utc_now())}

  defp update_stats(socket, sample) do
    cpu = SystemStats.cpu_usage(socket.assigns.prev && socket.assigns.prev.cpu, sample.cpu)
    mem_pct = sample.memory && sample.memory.used / sample.memory.total * 100

    assign(socket, prev: sample, stats: sample, cpu: cpu, mem_pct: mem_pct)
  end

  # SYS-1, DASH-10: where the metrics are read from. `SystemStats.sample/1` takes
  # the procfs root (it is overridable for tests), and so is this: a root whose
  # files are missing is what makes each section read "Unavailable".
  defp proc_root, do: Application.get_env(:elia, :proc_root, "/proc")

  defp sample, do: SystemStats.sample(proc_root())

  # DASH-3, DASH-5, DASH-7, DASH-9: everything the cards list, rebuilt from the
  # store, the projects file and the registry.
  defp refresh(socket) do
    chats = Store.list(1000)
    projects = Projects.list()
    names = project_names(projects)
    awaiting = Agent.awaiting_approval()
    paused = Agent.paused()
    running = Agent.running()
    resume = Store.latest()
    {attention, more} = attention_rows(chats, awaiting, paused, names)

    assign(socket,
      now: DateTime.utc_now(),
      chats: chats,
      projects: projects,
      names: names,
      resume: resume,
      resume_status: resume && status_of(resume, awaiting, paused, running),
      resume_project: resume && Map.get(names, resume.project_id, "Elia"),
      recent: Enum.map(Enum.take(chats, @recent), &row(&1, names, awaiting, paused, running)),
      attention: attention,
      attention_more: more,
      default_project: Projects.default(),
      # UI-47, UI-58, UI-59: what the registry says about every chat, kept live.
      awaiting: awaiting,
      paused: paused,
      running: running
    )
  end

  # DASH-5: one row per chat that wants the user — every chat that blocks a turn
  # (awaiting approval, then paused), then the interrupted ones, capped at
  # `@interrupted_rows` with the rest counted. The store lists chats newest
  # first, and so does each group.
  defp attention_rows(chats, awaiting, paused, names) do
    split = fn chats, match, reason_key, reason ->
      {for(chat <- chats, match.(chat), do: row(chat, names, reason_key, reason)),
       Enum.reject(chats, match)}
    end

    {waiting, rest} = split.(chats, &(&1.id in awaiting), "awaiting_approval", "Needs approval")
    {held, rest} = split.(rest, &(&1.id in paused), "paused", "Paused at a limit")

    interrupted =
      for chat <- rest, Map.get(chat, :interrupted, false) do
        row(chat, names, "interrupted", "Interrupted by a restart")
      end

    {waiting ++ held ++ Enum.take(interrupted, @interrupted_rows),
     max(length(interrupted) - @interrupted_rows, 0)}
  end

  defp row(chat, names, reason_key, reason) do
    %{
      chat: chat,
      project: Map.get(names, chat.project_id, "Elia"),
      reason_key: reason_key,
      reason: reason
    }
  end

  # DASH-3, DASH-7: a chat as a list row, with the status it shows — the
  # sidebar's own rules (UI-46, UI-47, UI-58, UI-59, UI-72).
  defp row(chat, names, awaiting, paused, running) do
    %{
      chat: chat,
      project: Map.get(names, chat.project_id, "Elia"),
      status: status_of(chat, awaiting, paused, running)
    }
  end

  defp status_of(chat, awaiting, paused, running) do
    ChatStatus.status(chat, %{
      awaiting: chat.id in awaiting,
      paused: chat.id in paused,
      running: chat.id in running,
      # STORE-31: the record a restart left behind.
      interrupted: Map.get(chat, :interrupted, false)
    })
  end

  # PROJ-9: a chat with no project id belongs to Elia's own project.
  defp project_names(projects) do
    Map.put_new_lazy(
      Map.new(projects, &{&1.id, &1.name}),
      nil,
      fn -> Projects.harness().name end
    )
  end

  # DASH-9: every project with how many chats it has, as the projects page
  # counts them (PROJ-23).
  defp project_rows(projects, chats) do
    Enum.map(projects, fn project ->
      count =
        if project.harness?,
          do: Enum.count(chats, &(&1.project_id in [nil, project.id])),
          else: Enum.count(chats, &(&1.project_id == project.id))

      Map.put(project, :chats, count)
    end)
  end

  defp percent(pct) when is_number(pct), do: "#{round(pct)}%"

  # SYS-2, DASH-10: CPU usage needs two samples. One sample alone is not a rate,
  # so the card says it is measuring until the next one (2 seconds later).
  defp cpu_text(%{cpu: nil}, _cpu), do: "Unavailable"
  defp cpu_text(_stats, nil), do: "Measuring…"
  defp cpu_text(_stats, cpu), do: percent(cpu.total)

  defp level(pct) when is_number(pct), do: SystemStats.level(pct)
  defp level(_pct), do: :normal

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="home-scroll" class="h-full overflow-y-auto">
        <div class="mx-auto max-w-5xl px-4 py-8 sm:px-6">
          <header>
            <h1 class="text-2xl font-semibold tracking-tight">Home</h1>
            <p class="mt-1 text-sm text-base-content/60">
              Where you left off, what needs you, and how this machine is doing.
            </p>
          </header>

          <%!-- DASH-12: one column of `minmax(0, 1fr)` below `lg`, so the cards
          shrink with the screen instead of growing to a long title's
          `min-content` (a truncated title is one unbreakable line). --%>
          <div class="mt-6 grid grid-cols-1 gap-4 lg:grid-cols-5">
            <div class="flex flex-col gap-4 lg:col-span-3">
              <.continue_card
                resume={@resume}
                status={@resume_status}
                project={@resume_project}
                default_project={@default_project}
                now={@now}
              />
              <.attention_card rows={@attention} more={@attention_more} />
              <.recent_card rows={@recent} now={@now} />
            </div>

            <div class="flex flex-col gap-4 lg:col-span-2">
              <.projects_card rows={project_rows(@projects, @chats)} />
              <.system_card
                stats={@stats}
                percent={cpu_text(@stats, @cpu)}
                memory={memory_line(@stats)}
                load={load_line(@stats)}
                vm={vm_line(@stats)}
                cpu_level={level(@cpu && @cpu.total)}
                memory_level={level(@mem_pct)}
              />
              <.deploy_card deploy={@deploy} />
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## Cards

  # DASH-3, DASH-4: the chat the user left off in, and the way to start one.
  attr :resume, :map, default: nil
  attr :status, :string, default: nil
  attr :project, :string, default: nil
  attr :default_project, :map, required: true
  attr :now, :any, required: true

  defp continue_card(assigns) do
    ~H"""
    <section id="continue" class="rounded-2xl border border-base-300 p-5">
      <h2 class="text-xs font-medium tracking-wider text-base-content/50 uppercase">Continue</h2>

      <.link
        :if={@resume}
        navigate={~p"/c/#{@resume.id}"}
        id="continue-link"
        class="mt-3 flex items-center gap-3 rounded-xl px-3 py-2.5 transition hover:bg-base-200"
      >
        <ChatStatus.status_icon id="continue-status" status={@status} />
        <span class="min-w-0 flex-1">
          <span id="continue-title" class="block truncate font-medium">{@resume.title}</span>
          <span class="mt-0.5 flex flex-wrap items-center gap-x-2 text-xs text-base-content/50">
            <span id="continue-project">{@project}</span>
            <span aria-hidden="true">·</span>
            <time
              id="continue-time"
              datetime={DateTime.to_iso8601(@resume.created_at)}
              title={Calendar.strftime(@resume.created_at, "%Y-%m-%d %H:%M:%S UTC")}
            >
              {TimeAgo.format(@resume.created_at, @now)}
            </time>
          </span>
        </span>
        <.icon name="hero-arrow-right" class="size-4 shrink-0 text-base-content/40" />
      </.link>

      <p :if={!@resume} id="continue-empty" class="mt-3 text-sm text-base-content/50">
        No chats yet — start one and it will show up here.
      </p>

      <.link
        navigate={~p"/p/#{@default_project.id}/new"}
        id="new-chat"
        class="mt-3 flex w-fit items-center gap-1.5 rounded-xl bg-primary px-3.5 py-2 text-sm font-medium text-primary-content transition hover:brightness-110"
      >
        <.icon name="hero-plus" class="size-4" /> New chat
      </.link>
    </section>
    """
  end

  # DASH-5, DASH-6: the chats that want the user, each a link to its own chat.
  attr :rows, :list, required: true
  attr :more, :integer, required: true

  defp attention_card(assigns) do
    ~H"""
    <section id="attention" class="rounded-2xl border border-warning/30 bg-warning/5 p-5">
      <div class="flex items-center gap-2">
        <.icon name="hero-hand-raised" class="size-4 text-warning" />
        <h2 class="text-xs font-medium tracking-wider text-base-content/50 uppercase">
          Needs attention
        </h2>
      </div>

      <ul :if={@rows != []} class="mt-3 space-y-1">
        <li :for={row <- @rows} id={"attention-#{row.chat.id}"} data-reason={row.reason_key}>
          <.link
            navigate={~p"/c/#{row.chat.id}"}
            class="flex items-center gap-3 rounded-xl px-3 py-2 transition hover:bg-base-200"
          >
            <ChatStatus.status_icon id={"attention-status-#{row.chat.id}"} status={row.reason_key} />
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-medium">{row.chat.title}</span>
              <span class="block truncate text-xs text-base-content/60">
                {row.reason} · {row.project}
              </span>
            </span>
            <.icon name="hero-arrow-right" class="size-4 shrink-0 text-base-content/40" />
          </.link>
        </li>
      </ul>

      <p :if={@more > 0} id="attention-more" class="mt-2 px-3 text-xs text-base-content/60">
        and {@more} more interrupted
      </p>

      <p :if={@rows == []} id="attention-empty" class="mt-3 text-sm text-base-content/60">
        Nothing needs you right now.
      </p>
    </section>
    """
  end

  # DASH-7, DASH-8: the most recently started chats, newest first.
  attr :rows, :list, required: true
  attr :now, :any, required: true

  defp recent_card(assigns) do
    ~H"""
    <section id="recent-chats" class="rounded-2xl border border-base-300 p-5">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-xs font-medium tracking-wider text-base-content/50 uppercase">
          Recent chats
        </h2>
        <.link
          navigate={~p"/chats"}
          id="all-chats"
          class="flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          All chats <.icon name="hero-arrow-right" class="size-3.5" />
        </.link>
      </div>

      <ul :if={@rows != []} class="mt-3 space-y-1">
        <li :for={row <- @rows} id={"recent-#{row.chat.id}"}>
          <.link
            navigate={~p"/c/#{row.chat.id}"}
            title={row.chat.description}
            class="flex items-center gap-3 rounded-xl px-3 py-2 transition hover:bg-base-200"
          >
            <ChatStatus.status_icon id={"recent-status-#{row.chat.id}"} status={row.status} />
            <span class="min-w-0 flex-1 truncate text-sm">{row.chat.title}</span>
            <span class="hidden shrink-0 text-xs text-base-content/50 sm:block">{row.project}</span>
            <time
              id={"recent-time-#{row.chat.id}"}
              datetime={DateTime.to_iso8601(row.chat.created_at)}
              title={Calendar.strftime(row.chat.created_at, "%Y-%m-%d %H:%M:%S UTC")}
              class="shrink-0 text-xs text-base-content/50"
            >
              {TimeAgo.format(row.chat.created_at, @now)}
            </time>
          </.link>
        </li>
      </ul>

      <p :if={@rows == []} id="recent-empty" class="mt-3 text-sm text-base-content/50">
        No chats yet
      </p>
    </section>
    """
  end

  # DASH-9: every project, with how many chats it has and a way into each.
  attr :rows, :list, required: true

  defp projects_card(assigns) do
    ~H"""
    <section id="projects" class="rounded-2xl border border-base-300 p-5">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-xs font-medium tracking-wider text-base-content/50 uppercase">Projects</h2>
        <.link
          navigate={~p"/projects"}
          id="all-projects"
          class="flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          All projects <.icon name="hero-arrow-right" class="size-3.5" />
        </.link>
      </div>

      <ul class="mt-3 space-y-1">
        <li
          :for={project <- @rows}
          id={"dash-project-#{project.id}"}
          class="flex items-center gap-3 rounded-xl px-3 py-2 transition hover:bg-base-200"
        >
          <.icon name="hero-rectangle-stack" class="size-4 shrink-0 text-base-content/40" />
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-medium">{project.name}</span>
            <span
              class="block truncate font-mono text-xs text-base-content/50"
              title={project.folder}
            >
              {project.folder}
            </span>
          </span>
          <span
            id={"dash-project-chats-#{project.id}"}
            class="shrink-0 rounded-full bg-base-200 px-2 py-0.5 text-xs text-base-content/70"
          >
            {project.chats}
          </span>
          <.link
            navigate={~p"/p/#{project.id}/new"}
            id={"dash-project-new-#{project.id}"}
            title={"New chat in #{project.name}"}
            class="shrink-0 rounded-lg p-1.5 text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-plus" class="size-4" />
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  # DASH-10: the machine, the numbers the System page shows (SYS-1, SYS-3,
  # SYS-6, SYS-9, SYS-10).
  attr :stats, :map, required: true
  attr :percent, :string, required: true
  attr :memory, :string, required: true
  attr :load, :string, required: true
  attr :vm, :string, required: true
  attr :cpu_level, :atom, required: true
  attr :memory_level, :atom, required: true

  defp system_card(assigns) do
    ~H"""
    <section id="system-card" class="rounded-2xl border border-base-300 p-5">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-xs font-medium tracking-wider text-base-content/50 uppercase">System</h2>
        <.link
          navigate={~p"/system"}
          id="dash-system-link"
          class="flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          Details <.icon name="hero-arrow-right" class="size-3.5" />
        </.link>
      </div>

      <p id="dash-host" class="mt-3 truncate text-sm text-base-content/70">
        {@stats.host || "Unknown host"}
      </p>

      <dl class="mt-3 grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
        <div>
          <dt class="text-xs text-base-content/50">CPU</dt>
          <dd class="mt-0.5 flex items-center gap-2">
            <span id="dash-cpu" class="font-mono tabular-nums">{@percent}</span>
            <.level_badge level={@cpu_level} />
          </dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/50">Memory</dt>
          <dd class="mt-0.5 flex items-center gap-2">
            <span id="dash-memory" class="font-mono tabular-nums">{@memory}</span>
            <.level_badge level={@memory_level} />
          </dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/50">Load (1m)</dt>
          <dd id="dash-load" class="mt-0.5 font-mono tabular-nums">{@load}</dd>
        </div>
        <div>
          <dt class="text-xs text-base-content/50">Elixir VM</dt>
          <dd id="dash-vm" class="mt-0.5 font-mono tabular-nums">{@vm}</dd>
        </div>
      </dl>
    </section>
    """
  end

  # SYS-9: high and critical percentages say so in words, not only in colour.
  attr :level, :atom, required: true

  defp level_badge(assigns) do
    ~H"""
    <span
      :if={@level != :normal}
      data-level={@level}
      class={[
        "inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-[11px] font-medium",
        @level == :high && "bg-warning/15 text-warning",
        @level == :critical && "bg-error/15 text-error"
      ]}
    >
      {if @level == :high, do: "High", else: "Critical"}
    </span>
    """
  end

  # DASH-11: where the trunk stands against the branch the server runs
  # (DEPLOY-14, DEPLOY-15, DEPLOY-17).
  attr :deploy, :any, required: true

  defp deploy_card(assigns) do
    ~H"""
    <section id="deploy-card" class="rounded-2xl border border-base-300 p-5">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-xs font-medium tracking-wider text-base-content/50 uppercase">Deploy</h2>
        <.link
          navigate={~p"/settings"}
          id="deploy-settings-link"
          class="flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
        >
          Settings <.icon name="hero-arrow-right" class="size-3.5" />
        </.link>
      </div>

      <%= case @deploy do %>
        <% {:ok, %{pending: 0}} -> %>
          <p id="deploy-ok" class="mt-3 flex items-center gap-2 text-sm text-success">
            <.icon name="hero-check-circle" class="size-4 shrink-0" /> Up to date
          </p>
        <% {:ok, %{pending: 1}} -> %>
          <p id="deploy-pending" class="mt-3 text-sm">1 commit to deploy</p>
        <% {:ok, %{pending: commits}} -> %>
          <p id="deploy-pending" class="mt-3 text-sm">{commits} commits to deploy</p>
        <% {:error, reason} -> %>
          <p id="deploy-error" class="mt-3 text-sm text-base-content/60">{reason}</p>
      <% end %>

      <%!-- DEPLOY-15: a deploy that merged and never reached the load. --%>
      <p :if={behind?(@deploy)} id="deploy-behind" class="mt-2 text-xs text-warning">
        The running app is behind the deployed code — a restart loads it.
      </p>

      <p class="mt-2 text-xs text-base-content/50">
        Deploying runs the test suite and loads the trunk, from Settings.
      </p>
    </section>
    """
  end

  defp behind?({:ok, %{behind?: behind?}}), do: behind?
  defp behind?(_deploy), do: false

  defp memory_line(%{memory: nil}), do: "Unavailable"

  defp memory_line(%{memory: memory}) do
    SystemStats.format_bytes(memory.used) <> " of " <> SystemStats.format_bytes(memory.total)
  end

  defp load_line(%{load: [one | _rest]}), do: :erlang.float_to_binary(one, decimals: 2)
  defp load_line(_stats), do: "Unavailable"

  defp vm_line(%{vm: nil}), do: "Unavailable"

  defp vm_line(%{vm: vm}) do
    SystemStats.format_bytes(vm.memory) <> " · " <> Integer.to_string(vm.processes) <> " procs"
  end
end
