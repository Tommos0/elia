defmodule EliaWeb.LogsLive do
  @moduledoc """
  The Log viewer: the server's recent log output, with a level filter and a
  text search. See `specs/log-viewer.md`.
  """
  use EliaWeb, :live_view

  alias Elia.Logs

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Logs.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Logs", level: :all, query: "")
     |> assign_form()
     |> refresh()}
  end

  # LOG-7, LOG-9
  @impl true
  def handle_event("filter", %{"filter" => params}, socket) do
    socket =
      socket
      |> assign(level: parse_level(params["level"]), query: params["query"] || "")
      |> assign_form()
      |> refresh()

    {:noreply, socket}
  end

  # LOG-8
  def handle_event("clear", _params, socket) do
    Logs.clear()
    {:noreply, socket}
  end

  @impl true
  def handle_info({:log_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info(:logs_cleared, socket), do: {:noreply, refresh(socket)}

  # LOG-5, LOG-6
  defp refresh(socket) do
    entries = Logs.list(level: socket.assigns.level, query: socket.assigns.query)

    socket
    |> assign(count: length(entries), total: length(Logs.list()))
    |> stream(:entries, entries, reset: true)
  end

  defp assign_form(socket) do
    assign(socket,
      form:
        to_form(
          %{"level" => to_string(socket.assigns.level), "query" => socket.assigns.query},
          as: :filter
        )
    )
  end

  defp parse_level("all"), do: :all

  defp parse_level(level) do
    Enum.find(Logs.levels(), :all, &(to_string(&1) == level))
  end

  defp level_options do
    [{"All levels", "all"} | Enum.map(Logs.levels(), &{&1, to_string(&1)})]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="h-full overflow-y-auto">
        <div class="mx-auto max-w-6xl px-4 py-10 sm:px-6">
          <div class="flex flex-wrap items-end justify-between gap-4">
            <div>
              <h1 class="text-2xl font-semibold tracking-tight">Logs</h1>
              <p class="mt-1 text-sm text-base-content/60">
                The server's most recent log output, newest first.
              </p>
            </div>
            <div
              id="log-count"
              class="flex items-center gap-2 rounded-full border border-base-300 px-3 py-1 text-sm"
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-success opacity-60" />
                <span class="relative inline-flex size-2 rounded-full bg-success" />
              </span>
              {if @count == @total,
                do: "#{@count} entries",
                else: "#{@count} of #{@total} entries"}
            </div>
          </div>

          <div class="mt-8 flex flex-wrap items-end gap-3">
            <.form
              for={@form}
              id="log-filter"
              phx-change="filter"
              class="flex flex-wrap items-end gap-3"
            >
              <.input
                field={@form[:level]}
                type="select"
                id="log-level"
                label="Minimum level"
                options={level_options()}
                class="select select-sm w-40"
              />
              <.input
                field={@form[:query]}
                type="search"
                id="log-query"
                label="Search"
                placeholder="Filter messages…"
                class="input input-sm w-64"
              />
            </.form>
            <button id="clear-logs" phx-click="clear" class="btn btn-sm ml-auto">
              <.icon name="hero-trash" class="size-4" /> Clear
            </button>
          </div>

          <ul
            id="log-entries"
            phx-update="stream"
            class="mt-6 overflow-hidden rounded-xl border border-base-300"
          >
            <li
              id="log-entries-empty"
              class="hidden only:block px-4 py-16 text-center text-sm text-base-content/50"
            >
              No log entries
            </li>
            <li
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              data-level={entry.level}
              class="border-b border-base-300 px-4 py-2 font-mono text-[13px] leading-5 last:border-b-0 hover:bg-base-200/40 sm:flex sm:gap-3"
            >
              <!--
                LOG-11: a phone has no room for time, level, source and message
                in one row — the message would be squeezed into a column a
                character wide. Below `sm` the meta parts share a line and the
                message gets the next one; from `sm` up the wrapper is
                `contents`, so they are the row's own items again.
              -->
              <div class="flex min-w-0 items-center gap-2 sm:contents">
                <time class="shrink-0 text-base-content/40" title={DateTime.to_iso8601(entry.at)}>
                  {Calendar.strftime(entry.at, "%H:%M:%S")}
                </time>
                <span class={[
                  "shrink-0 rounded px-1.5 text-[11px] uppercase sm:self-start",
                  level_class(entry.level)
                ]}>
                  {entry.level}
                </span>
                <span
                  :if={source(entry)}
                  title={source(entry)}
                  class="min-w-0 truncate text-xs text-base-content/30 sm:order-last"
                >
                  {source(entry)}
                </span>
              </div>
              <span class="mt-0.5 block whitespace-pre-wrap break-words sm:mt-0 sm:min-w-0 sm:flex-1">
                {entry.message}
              </span>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp source(%{mfa: nil, pid: nil}), do: nil
  defp source(%{mfa: nil, pid: pid}), do: inspect(pid)

  defp source(%{mfa: {module, fun, arity}, pid: nil}),
    do: "#{inspect(module)}.#{fun}/#{arity}"

  defp source(%{mfa: {module, fun, arity}, pid: pid}),
    do: "#{inspect(module)}.#{fun}/#{arity} #{inspect(pid)}"

  defp level_class(level) do
    case level do
      :debug -> "bg-base-200 text-base-content/50"
      :info -> "bg-info/15 text-info"
      :notice -> "bg-info/15 text-info"
      :warning -> "bg-warning/15 text-warning"
      :error -> "bg-error/15 text-error"
      :critical -> "bg-error/20 text-error"
      :alert -> "bg-error/20 text-error"
      :emergency -> "bg-error/20 text-error"
    end
  end
end
