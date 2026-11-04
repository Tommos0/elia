defmodule EliaWeb.SystemLive do
  use EliaWeb, :live_view

  alias Elia.SystemStats

  # SYS-7
  @tick :timer.seconds(2)
  # SYS-8
  @history 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@tick, :tick)

    {:ok,
     socket
     |> assign(page_title: "System", prev: nil, cpu_history: [], mem_history: [])
     |> update_stats(SystemStats.sample())}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, update_stats(socket, SystemStats.sample())}

  defp update_stats(socket, sample) do
    prev = socket.assigns.prev
    cpu = SystemStats.cpu_usage(prev && prev.cpu, sample.cpu)
    mem_pct = sample.memory && sample.memory.used / sample.memory.total * 100

    assign(socket,
      prev: sample,
      stats: sample,
      cpu: cpu,
      mem_pct: mem_pct,
      net: SystemStats.net_rates(prev, sample),
      cpu_history: push(socket.assigns.cpu_history, cpu && cpu.total),
      mem_history: push(socket.assigns.mem_history, mem_pct)
    )
  end

  defp push(history, nil), do: history
  defp push(history, value), do: Enum.take(history ++ [value], -@history)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="system-scroll" class="h-full overflow-y-auto">
        <div class="mx-auto max-w-6xl px-4 py-10 sm:px-6">
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold tracking-tight">System</h1>
              <p id="system-host" class="mt-1 text-sm text-base-content/60">
                <span class="font-medium text-base-content/80">{@stats.host || "Unknown host"}</span>
                <span :if={@stats.kernel}> · Linux {@stats.kernel}</span>
                <span :if={@stats.cpu_model}> · {@stats.cpu_model}</span>
              </p>
            </div>
            <div
              id="system-uptime"
              class="flex items-center gap-2 rounded-full border border-base-300 px-3 py-1 text-sm"
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-60" />
                <span class="relative inline-flex size-2 rounded-full bg-success" />
              </span>
              up {SystemStats.format_duration(@stats.uptime)}
            </div>
          </div>

          <div class="mt-6 flex flex-wrap items-center gap-2">
            <.link
              id="logs-link"
              navigate={~p"/logs"}
              class="inline-flex items-center gap-2 rounded-lg border border-base-300 px-3 py-1.5 text-sm transition hover:border-base-content/20 hover:bg-base-200"
            >
              <.icon name="hero-document-text" class="size-4" /> Logs
            </.link>
          </div>

          <div class="mt-8 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <.tile id="tile-cpu" icon="hero-cpu-chip" label="CPU" pct={@cpu && @cpu.total}>
              <:detail>
                {if @stats.cpu, do: "#{length(@stats.cpu.cores)} cores", else: "Unavailable"}
              </:detail>
              <.sparkline id="cpu-sparkline" points={@cpu_history} label="CPU" />
            </.tile>

            <.tile id="tile-memory" icon="hero-circle-stack" label="Memory" pct={@mem_pct}>
              <:detail>
                <%= if @stats.memory do %>
                  {SystemStats.format_bytes(@stats.memory.used)} of {SystemStats.format_bytes(
                    @stats.memory.total
                  )}
                <% else %>
                  Unavailable
                <% end %>
              </:detail>
              <.sparkline id="memory-sparkline" points={@mem_history} label="Memory" />
            </.tile>

            <.card id="tile-load" icon="hero-scale" label="Load average">
              <%= if @stats.load do %>
                <div class="mt-3 flex items-baseline gap-4">
                  <div :for={{value, window} <- Enum.zip(@stats.load, ["1m", "5m", "15m"])}>
                    <p class={[
                      "font-mono tabular-nums",
                      window == "1m" && "text-3xl font-semibold tracking-tight",
                      window != "1m" && "text-lg text-base-content/70"
                    ]}>
                      {:erlang.float_to_binary(value, decimals: 2)}
                    </p>
                    <p class="text-xs text-base-content/50">{window}</p>
                  </div>
                </div>
                <p :if={@stats.cpu} class="mt-3 text-xs text-base-content/50">
                  across {length(@stats.cpu.cores)} cores
                </p>
              <% else %>
                <.unavailable />
              <% end %>
            </.card>

            <.card id="tile-network" icon="hero-arrows-up-down" label="Network">
              <%= if @net do %>
                <div class="mt-3 space-y-1.5">
                  <p class="flex items-center gap-2">
                    <.icon name="hero-arrow-down" class="size-4 text-base-content/40" />
                    <span class="font-mono text-lg tabular-nums">
                      {rate(Enum.sum_by(@net, & &1.rx))}
                    </span>
                  </p>
                  <p class="flex items-center gap-2">
                    <.icon name="hero-arrow-up" class="size-4 text-base-content/40" />
                    <span class="font-mono text-lg tabular-nums">
                      {rate(Enum.sum_by(@net, & &1.tx))}
                    </span>
                  </p>
                </div>
                <p class="mt-2 text-xs text-base-content/50">all interfaces</p>
              <% else %>
                <p class="mt-3 text-sm text-base-content/50">
                  {if @stats.net, do: "Measuring…", else: "Unavailable"}
                </p>
              <% end %>
            </.card>
          </div>

          <%!-- SYS-12: one shrinkable column of cards below `lg`, so a long value
          inside one can't widen the page. --%>
          <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
            <.card id="cpu-cores" icon="hero-squares-2x2" label="CPU cores">
              <%= cond do %>
                <% @cpu -> %>
                  <div class="mt-4 grid grid-cols-2 gap-x-6 gap-y-3 sm:grid-cols-4">
                    <div :for={{pct, i} <- Enum.with_index(@cpu.cores)} id={"core-#{i}"}>
                      <div class="flex justify-between text-xs">
                        <span class="text-base-content/60">Core {i}</span>
                        <span class="font-mono tabular-nums">{percent(pct)}</span>
                      </div>
                      <.meter pct={pct} class="mt-1" />
                    </div>
                  </div>
                <% @stats.cpu -> %>
                  <p class="mt-3 text-sm text-base-content/50">Measuring…</p>
                <% true -> %>
                  <.unavailable />
              <% end %>
            </.card>

            <.card id="memory-detail" icon="hero-circle-stack" label="Memory">
              <%= if m = @stats.memory do %>
                <dl class="mt-4 grid grid-cols-3 gap-4 text-sm">
                  <.stat label="Used" value={SystemStats.format_bytes(m.used)} />
                  <.stat label="Available" value={SystemStats.format_bytes(m.available)} />
                  <.stat label="Cache & buffers" value={SystemStats.format_bytes(m.cached)} />
                </dl>
                <div id="swap" class="mt-5">
                  <div class="flex items-baseline justify-between text-sm">
                    <span class="text-base-content/60">Swap</span>
                    <%= if m.swap_total > 0 do %>
                      <span class="flex items-center gap-2">
                        <.level_badge pct={m.swap_used / m.swap_total * 100} />
                        <span class="font-mono text-xs tabular-nums">
                          {SystemStats.format_bytes(m.swap_used)} / {SystemStats.format_bytes(
                            m.swap_total
                          )}
                        </span>
                      </span>
                    <% else %>
                      <span class="text-xs text-base-content/50">None</span>
                    <% end %>
                  </div>
                  <.meter
                    :if={m.swap_total > 0}
                    pct={m.swap_used / m.swap_total * 100}
                    class="mt-1.5"
                  />
                </div>
              <% else %>
                <.unavailable />
              <% end %>
            </.card>
          </div>

          <.card id="disks" icon="hero-server-stack" label="Disks" class="mt-4">
            <%= cond do %>
              <% @stats.disks == nil -> %>
                <.unavailable />
              <% @stats.disks == [] -> %>
                <p class="mt-3 text-sm text-base-content/50">No disks found</p>
              <% true -> %>
                <ul class="mt-2 divide-y divide-base-300">
                  <li
                    :for={{disk, i} <- Enum.with_index(@stats.disks)}
                    id={"disk-#{i}"}
                    class="py-3"
                  >
                    <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                      <div class="min-w-0">
                        <span class="font-mono text-sm font-medium">{disk.mount}</span>
                        <span class="ml-2 text-xs text-base-content/50">
                          {disk.device} · {disk.type}
                        </span>
                      </div>
                      <div class="flex items-center gap-2 text-sm">
                        <.level_badge pct={disk.pct} />
                        <span class="font-mono tabular-nums text-base-content/70">
                          {SystemStats.format_bytes(disk.used)} / {SystemStats.format_bytes(disk.size)}
                        </span>
                        <span class="w-12 text-right font-mono font-medium tabular-nums">
                          {percent(disk.pct)}
                        </span>
                      </div>
                    </div>
                    <.meter pct={disk.pct} class="mt-2" />
                  </li>
                </ul>
            <% end %>
          </.card>

          <div class="mt-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
            <.card id="network" icon="hero-globe-alt" label="Interfaces">
              <%= cond do %>
                <% @net == [] -> %>
                  <p class="mt-3 text-sm text-base-content/50">No interfaces found</p>
                <% @net -> %>
                  <table class="mt-3 w-full text-sm">
                    <thead>
                      <tr class="text-left text-xs text-base-content/50">
                        <th class="pb-2 font-normal">Interface</th>
                        <th class="pb-2 text-right font-normal">Receive</th>
                        <th class="pb-2 text-right font-normal">Send</th>
                      </tr>
                    </thead>
                    <tbody class="divide-y divide-base-300">
                      <tr :for={iface <- @net} id={"iface-#{iface.name}"}>
                        <td class="py-2 font-mono">{iface.name}</td>
                        <td class="py-2 text-right font-mono tabular-nums">{rate(iface.rx)}</td>
                        <td class="py-2 text-right font-mono tabular-nums">{rate(iface.tx)}</td>
                      </tr>
                    </tbody>
                  </table>
                <% @stats.net -> %>
                  <p class="mt-3 text-sm text-base-content/50">Measuring…</p>
                <% true -> %>
                  <.unavailable />
              <% end %>
            </.card>

            <.card id="vm" icon="hero-beaker" label="Erlang VM">
              <dl class="mt-4 grid grid-cols-2 gap-4 text-sm sm:grid-cols-3">
                <.stat label="Memory" value={SystemStats.format_bytes(@stats.vm.memory)} />
                <.stat label="Processes" value={@stats.vm.processes} />
                <.stat label="Schedulers" value={@stats.vm.schedulers} />
                <.stat label="Uptime" value={SystemStats.format_duration(@stats.vm.uptime)} />
                <.stat label="Elixir" value={@stats.vm.elixir} />
                <.stat label="OTP" value={@stats.vm.otp} />
              </dl>
            </.card>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp card(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "rounded-xl border border-base-300 p-5 transition duration-200 hover:border-base-content/20 hover:shadow-sm",
        @class
      ]}
    >
      <h2 class="flex items-center gap-2 text-sm font-medium text-base-content/70">
        <.icon name={@icon} class="size-4" /> {@label}
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :pct, :any, required: true
  slot :detail, required: true
  slot :inner_block

  defp tile(assigns) do
    ~H"""
    <.card id={@id} icon={@icon} label={@label}>
      <div class="mt-3 flex items-baseline justify-between gap-2">
        <p class="font-mono text-3xl font-semibold tracking-tight tabular-nums">
          {if @pct, do: percent(@pct), else: "—"}
        </p>
        <.level_badge pct={@pct} />
      </div>
      <p class="mt-1 text-xs text-base-content/50">{render_slot(@detail)}</p>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </.card>
    """
  end

  attr :pct, :any, required: true
  attr :class, :string, default: nil

  defp meter(assigns) do
    ~H"""
    <div class={["h-1.5 overflow-hidden rounded-full bg-base-200", @class]}>
      <div
        class={[
          "h-full rounded-full transition-[width] duration-700 ease-out",
          level_bg(SystemStats.level(@pct))
        ]}
        style={"width: #{min(@pct || 0, 100)}%"}
      />
    </div>
    """
  end

  # SYS-9: high and critical carry a text label, not only a colour.
  attr :pct, :any, required: true

  defp level_badge(assigns) do
    assigns = assign(assigns, :level, SystemStats.level(assigns.pct))

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
      <.icon name="hero-exclamation-triangle-micro" class="size-3" />
      {if @level == :high, do: "High", else: "Critical"}
    </span>
    """
  end

  # SYS-8: last readings as a 0–100% line; each point has a hover title.
  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :label, :string, required: true

  defp sparkline(assigns) do
    n = length(assigns.points)
    step = 120 / max(@history - 1, 1)
    offset = (@history - n) * step

    coords =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> {offset + i * step, 30 - v * 0.28, v} end)

    assigns = assign(assigns, coords: coords, step: step)

    ~H"""
    <svg
      id={@id}
      viewBox="0 0 120 32"
      preserveAspectRatio="none"
      class="h-10 w-full overflow-visible text-primary"
      role="img"
      aria-label={"#{@label} over the last #{length(@points)} readings"}
    >
      <line
        x1="0"
        y1="30"
        x2="120"
        y2="30"
        class="stroke-base-300"
        stroke-width="1"
        vector-effect="non-scaling-stroke"
      />
      <polyline
        :if={length(@coords) > 1}
        points={Enum.map_join(@coords, " ", fn {x, y, _} -> "#{x},#{y}" end)}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
      <rect
        :for={{x, _y, v} <- @coords}
        x={x - @step / 2}
        y="0"
        width={@step}
        height="32"
        fill="transparent"
        class="hover:fill-base-content/10"
      >
        <title>{@label}: {percent(v)}</title>
      </rect>
    </svg>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <dt class="text-xs text-base-content/50">{@label}</dt>
      <dd class="mt-0.5 font-mono tabular-nums">{@value}</dd>
    </div>
    """
  end

  defp unavailable(assigns) do
    ~H"""
    <p class="mt-3 text-sm text-base-content/50" data-unavailable>Unavailable</p>
    """
  end

  defp level_bg(:normal), do: "bg-primary"
  defp level_bg(:high), do: "bg-warning"
  defp level_bg(:critical), do: "bg-error"

  defp percent(pct), do: "#{round(pct)}%"
  defp rate(bytes), do: SystemStats.format_bytes(bytes) <> "/s"
end
