defmodule EliaWeb.SessionsLive do
  use EliaWeb, :live_view

  alias EliaWeb.{ClientTracker, UserAgent}

  # Keeps the "connected … ago" labels fresh.
  @tick :timer.seconds(30)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      ClientTracker.subscribe()
      :timer.send_interval(@tick, :tick)
    end

    {:ok, assign(socket, page_title: "Sessions")}
  end

  # Runs after ClientTracker's handle_params hook, so this tab is listed.
  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, refresh(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-4xl px-4 py-10 sm:px-6">
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold tracking-tight">Sessions</h1>
              <p class="mt-1 text-sm text-base-content/60">
                Browser tabs connected to Elia right now.
              </p>
            </div>
            <div
              id="session-count"
              class="flex items-center gap-2 rounded-full border border-base-300 px-3 py-1 text-sm"
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-60" />
                <span class="relative inline-flex size-2 rounded-full bg-success" />
              </span>
              {@count} {if @count == 1, do: "tab", else: "tabs"} open
            </div>
          </div>

          <ul id="client-sessions" phx-update="stream" class="mt-8 space-y-3">
            <li
              id="client-sessions-empty"
              class="hidden only:block rounded-xl border border-dashed border-base-300 py-16 text-center text-sm text-base-content/50"
            >
              No open tabs
            </li>
            <li
              :for={{dom_id, session} <- @streams.client_sessions}
              id={dom_id}
              class={[
                "group rounded-xl border p-4 transition duration-200 hover:shadow-sm",
                session.this_tab? && "border-primary/40 bg-primary/5",
                !session.this_tab? && "border-base-300 hover:border-base-content/20"
              ]}
            >
              <div class="flex items-start gap-4">
                <div class="grid size-10 shrink-0 place-items-center rounded-lg bg-base-200 text-base-content/70 transition group-hover:text-base-content">
                  <.icon
                    name={
                      if session.mobile?,
                        do: "hero-device-phone-mobile",
                        else: "hero-computer-desktop"
                    }
                    class="size-5"
                  />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
                    <span class="font-medium">{session.browser}</span>
                    <span class="text-base-content/30">·</span>
                    <span class="text-base-content/70">{session.os}</span>
                    <span
                      :if={session.this_tab?}
                      id="this-tab"
                      class="rounded-full bg-primary/15 px-2 py-0.5 text-[11px] font-medium text-primary"
                    >
                      This tab
                    </span>
                  </div>
                  <.link
                    :if={session.path}
                    navigate={session.path}
                    class="mt-1 inline-flex max-w-full items-center gap-1 text-sm text-base-content/70 transition hover:text-primary"
                  >
                    <.icon name="hero-arrow-up-right" class="size-3.5 shrink-0" />
                    <span class="truncate">{session.page}</span>
                  </.link>
                  <p
                    class="mt-2 truncate font-mono text-xs text-base-content/40 group-hover:whitespace-normal group-hover:break-all"
                    title={session.user_agent}
                  >
                    {if session.user_agent == "", do: "No user agent", else: session.user_agent}
                  </p>
                </div>
                <div class="shrink-0 text-right">
                  <p class="font-mono text-sm">{session.ip}</p>
                  <p class="mt-1 text-xs text-base-content/50" title={session.connected_at}>
                    {session.connected}
                  </p>
                </div>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, refresh(socket)}

  def handle_info(:tick, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    now = DateTime.utc_now()
    rows = Enum.map(ClientTracker.list(), &row(&1, now, socket.assigns.client_id))

    socket
    |> assign(count: length(rows))
    |> stream(:client_sessions, rows, reset: true)
  end

  defp row(meta, now, own_id) do
    meta
    |> Map.take([:id, :ip, :user_agent, :path])
    |> Map.merge(UserAgent.parse(meta.user_agent))
    |> Map.merge(%{
      page: page(meta.path),
      connected: ago(DateTime.diff(now, meta.connected_at)),
      connected_at: DateTime.to_iso8601(meta.connected_at),
      this_tab?: meta.id == own_id
    })
  end

  defp page("/c/" <> id) do
    if Elia.Store.valid_id?(id), do: Elia.Store.title(Elia.Store.load(id)), else: "/c/" <> id
  end

  defp page("/sessions"), do: "Sessions"
  defp page(path), do: path

  defp ago(seconds) when seconds < 60, do: "connected just now"
  defp ago(seconds) when seconds < 3600, do: "connected #{div(seconds, 60)} min ago"
  defp ago(seconds) when seconds < 86_400, do: "connected #{div(seconds, 3600)} h ago"
  defp ago(seconds), do: "connected #{div(seconds, 86_400)} d ago"
end
