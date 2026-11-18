defmodule EliaWeb.Notifications do
  @moduledoc """
  The notification bell: its state, the events that drive it and the markup it is
  drawn with (NOTIF-5 to NOTIF-11).

  Like `EliaWeb.ChatList` it hangs off every page of the live session
  (`EliaWeb.Router`'s `on_mount`), which is what puts the bell in the header
  wherever the user is without a page wiring anything of its own. The state is
  the stored list (`Elia.Notifications`), read when the page is drawn and
  followed on the topic from then on (NOTIF-10), so a notification recorded
  while the page is open appears without a reload.
  """

  use EliaWeb, :html

  alias Elia.Notifications

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  @doc """
  NOTIF-5, NOTIF-10: the bell's state and events, on every page of the live
  session. Every page draws the bell from this (`EliaWeb.Layouts`), so a page
  that adds no wiring of its own still has it.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:notifications, %{open: false, entries: [], unread: 0, now: nil})
      |> attach_hook(:notifications_events, :handle_event, &handle_event/3)
      |> attach_hook(:notifications_changes, :handle_info, &handle_info/2)
      |> subscribe()
      |> refresh()

    {:cont, socket}
  end

  ## Events

  # NOTIF-6, NOTIF-10: the list is read as the menu opens rather than only when
  # the page was mounted, so a menu that opens late shows what is stored now.
  defp handle_event("toggle_notifications", _params, socket) do
    open = not socket.assigns.notifications.open

    {:halt, refresh(put_state(socket, open: open))}
  end

  defp handle_event("close_notifications", _params, socket),
    do: {:halt, put_state(socket, open: false)}

  # NOTIF-9: the menu's own controls. Marking and clearing announce themselves
  # (NOTIF-10), so the state follows the store rather than a guess of its own.
  defp handle_event("notifications_mark_read", _params, socket) do
    Notifications.mark_all_read()
    {:halt, refresh(socket)}
  end

  defp handle_event("notifications_clear", _params, socket) do
    Notifications.clear()
    {:halt, refresh(socket)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # NOTIF-10: a change to the list, recorded, marked read or cleared anywhere —
  # this page, another, or another device.
  defp handle_info({:notifications, entries}, socket),
    do: {:halt, put_entries(socket, entries)}

  defp handle_info(_message, socket), do: {:cont, socket}

  ## The bell

  attr :state, :map, required: true, doc: "the bell's state (NOTIF-5)"

  @doc """
  NOTIF-5, NOTIF-6, NOTIF-11: the header's bell, with the count of what is
  unread, and the menu behind it: the entries newest first, each of them a link
  to the chat it is about (NOTIF-7), with the menu's own controls beside them
  (NOTIF-9).
  """
  def bell(assigns) do
    ~H"""
    <div class="relative">
      <%!-- NOTIF-5: below the `sm` breakpoint only the icon and the count are
      shown, and the label stays in the DOM for screen readers (UI-37). --%>
      <button
        type="button"
        id="notifications-toggle"
        phx-click="toggle_notifications"
        aria-expanded={to_string(@state.open)}
        aria-controls="notifications-menu"
        title="Notifications"
        class="flex items-center gap-1.5 rounded-lg p-2 text-sm transition hover:bg-base-200 sm:px-3 sm:py-1.5"
      >
        <.icon name="hero-bell" class="size-4" />
        <span :if={@state.unread > 0} id="notifications-count" class="text-xs font-medium">
          {@state.unread}
        </span>
        <span class="sr-only sm:not-sr-only">Notifications</span>
      </button>
      <%!-- NOTIF-6: a backdrop closes the menu, as the chat list's drawer's
      does (UI-36). FEED-1: a backdrop is not a control, so it does not
      press. --%>
      <button
        :if={@state.open}
        type="button"
        id="notifications-backdrop"
        phx-click="close_notifications"
        aria-label="Close notifications"
        class="fixed inset-0 z-30 bg-black/40"
        data-press="none"
      ></button>
      <div
        :if={@state.open}
        id="notifications-menu"
        phx-window-keydown="close_notifications"
        phx-key="Escape"
        class="absolute right-0 z-40 mt-2 flex max-h-[70vh] w-80 max-w-[calc(100vw-2rem)] flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl"
      >
        <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
          <span class="text-sm font-medium">Notifications</span>
          <span class="flex items-center gap-1">
            <button
              :if={@state.unread > 0}
              type="button"
              id="notifications-mark-read"
              phx-click="notifications_mark_read"
              class="rounded-lg px-2 py-1 text-xs text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
            >
              Mark all as read
            </button>
            <button
              :if={@state.entries != []}
              type="button"
              id="notifications-clear"
              phx-click="notifications_clear"
              class="rounded-lg px-2 py-1 text-xs text-base-content/70 transition hover:bg-base-200 hover:text-error"
            >
              Clear
            </button>
          </span>
        </div>
        <div class="min-h-0 flex-1 overflow-y-auto">
          <p
            :if={@state.entries == []}
            id="notifications-empty"
            class="px-3 py-4 text-sm text-base-content/50"
          >
            Nothing here yet — a chat that needs you lands here.
          </p>
          <%!-- NOTIF-6, NOTIF-7: newest first, each a link to its chat, with
          what it is about and when. An unread entry carries a dot and says so
          on `data-unread`. --%>
          <.link
            :for={entry <- @state.entries}
            id={"notification-#{entry.id}"}
            navigate={~p"/c/#{entry.chat_id}"}
            title={entry.title}
            data-unread={to_string(entry.read != true)}
            class="flex items-start gap-2 border-b border-base-300/60 px-3 py-2 last:border-b-0 transition hover:bg-base-200"
          >
            <span class={[
              "mt-1.5 size-2 shrink-0 rounded-full",
              entry.read != true && "bg-primary",
              entry.read == true && "bg-transparent"
            ]}></span>
            <span class="min-w-0 flex-1">
              <span class={["block truncate text-sm", entry.read != true && "font-medium"]}>
                {entry.title}
              </span>
              <span class="block text-xs text-base-content/60">
                {Elia.Push.reason_text(entry.reason)}
              </span>
              <time
                datetime={DateTime.to_iso8601(entry.at)}
                title={Calendar.strftime(entry.at, "%Y-%m-%d %H:%M:%S UTC")}
                class="block text-xs text-base-content/50"
              >
                {EliaWeb.TimeAgo.format(entry.at, @state.now)}
              </time>
            </span>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  ## State

  # NOTIF-10: the list as it is stored, and the clock its relative times read.
  defp refresh(socket),
    do: socket |> put_entries(Notifications.list()) |> put_state(now: DateTime.utc_now())

  defp put_entries(socket, entries),
    do: put_state(socket, entries: entries, unread: Notifications.count_unread(entries))

  defp subscribe(socket) do
    if connected?(socket), do: Notifications.subscribe()
    socket
  end

  defp put_state(socket, changes),
    do: assign(socket, :notifications, Map.merge(socket.assigns.notifications, Map.new(changes)))
end
