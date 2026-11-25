defmodule EliaWeb.ActiveChats do
  @moduledoc """
  The header's active chats control: its state, the events that drive it and the
  markup it is drawn with (ACTIVE-1 to ACTIVE-11).

  Like `EliaWeb.ChatList` it hangs off every page of the live session
  (`EliaWeb.Router`'s `on_mount`), which is what puts the control in the header
  wherever the user is without a page wiring anything of its own. The list is
  the chats themselves: every saved chat that isn't done (ACTIVE-2), across
  every project, each with the status the chat list shows for it (UI-46, UI-59),
  and the count is the ones no turn of which is running (ACTIVE-3). A row is a
  chat's own row (`EliaWeb.ChatRowMenu`), so a chat is renamed or deleted from
  the header without leaving the page (ACTIVE-8 to ACTIVE-11).
  """

  use EliaWeb, :html

  # ACTIVE-8, ACTIVE-9: a row of the menu is a chat's own row — the menu a long
  # press opens and the box a name is typed in — which is what the chat list
  # draws too (UI-103, UI-104).
  alias EliaWeb.{ChatRowMenu, ChatStatus}

  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  # ACTIVE-4: how many active chats the menu lists, the rest counted into "and
  # N more".
  @listed 50

  # ACTIVE-2, ACTIVE-3: the bound the chats are read with — the dashboard's own
  # (DASH-3) — so the count is over every active chat a store of any believable
  # size holds rather than over one page of a listing (ACTIVE-4).
  @read 1000

  @doc """
  ACTIVE-1, ACTIVE-7: the control's state and events, on every page of the live
  session. Every page draws the control from this (`EliaWeb.Layouts`), so a page
  that adds no wiring of its own still has it.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      # ACTIVE-8, ACTIVE-10: `renaming` is the header's own — the row it is
      # showing a box to type a name in, or nil — so a rename started in the
      # chat list's row is not shown here (UI-104).
      |> assign(:active_chats, %{open: false, chats: [], more: 0, count: 0, renaming: nil})
      |> attach_hook(:active_chats_events, :handle_event, &handle_event/3)
      |> attach_hook(:active_chats_status, :handle_info, &handle_info/2)
      |> subscribe()
      |> refresh()

    {:cont, socket}
  end

  ## Events

  # ACTIVE-5: the control opens and closes the menu and never navigates. The
  # chats are read as it opens, so a menu that opens late shows them as they are
  # now.
  defp handle_event("toggle_active_chats", _params, socket) do
    open = not socket.assigns.active_chats.open

    {:halt, refresh(put_state(socket, open: open))}
  end

  # ACTIVE-10: naming a chat from the header's row. The row's own box posts the
  # name alone, and which chat that is is this control's own state (ACTIVE-1) —
  # the row the box is drawn in — so the name is not carried in the form. An
  # accepted name is the chat's own title from then on (TITLE-8, STORE-55) and
  # the chats are read again, so the row shows it (ACTIVE-7).
  defp handle_event("active_rename_chat", %{"title" => title}, socket) do
    with id when is_binary(id) <- socket.assigns.active_chats.renaming,
         {:ok, _title} <- Elia.Agent.rename(id, title) do
      {:halt, socket |> put_state(renaming: nil) |> refresh()}
    else
      # TITLE-2, ACTIVE-10: a name that is blank once trimmed is no title at
      # all, so it saves nothing and the row goes back to what it showed —
      # exactly as cancelling leaves it. No row being renamed at all (a stale
      # client) is nothing to do either.
      _refused -> {:halt, put_state(socket, renaming: nil)}
    end
  end

  defp handle_event("active_start_rename", %{"id" => id}, socket),
    do: {:halt, put_state(socket, renaming: id)}

  # ACTIVE-10: the box's Cancel button, a press outside the box and Escape
  # (UI-104) all leave the row as it was.
  defp handle_event("active_cancel_rename", _params, socket),
    do: {:halt, put_state(socket, renaming: nil)}

  defp handle_event("close_active_chats", _params, socket),
    do: {:halt, put_state(socket, open: false)}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ACTIVE-7: a chat's status changed (SESS-19), a chat's done flag changed
  # (SESS-35) or a chat was deleted (SESS-48) — the chats are read again, so the
  # menu and the count are right without a reload. A page reads every saved chat
  # to do this, as its own dashboard cards do (DASH-5), which is what lets the
  # count be over every active chat rather than over a page of a listing
  # (ACTIVE-3, ACTIVE-4).
  #
  # The message goes on to the page's own `handle_info/2` (`{:cont, …}`): the
  # same event is what a dashboard's cards (DASH-5, DASH-8), a chat list's rows
  # (UI-49) and a chat page follow, and a hook that halted it would take it from
  # them.
  defp handle_info({:chat_status, _id, _status}, socket), do: {:cont, refresh(socket)}

  defp handle_info({:chat_deleted, _id}, socket), do: {:cont, refresh(socket)}

  defp handle_info(_message, socket), do: {:cont, socket}

  ## The control

  attr :state, :map, required: true, doc: "the control's state (ACTIVE-1)"

  # ACTIVE-9 to ACTIVE-11: the events a row's menu and its box send. Rename is
  # the header's own, so a rename started here is not taken for one started in
  # the chat list (UI-104); delete is the chat list's own event, which every
  # page of the live session handles (UI-64, UI-65).
  @row_events %{
    start: "active_start_rename",
    submit: "active_rename_chat",
    cancel: "active_cancel_rename",
    delete: "delete_chat"
  }

  @doc """
  ACTIVE-1, ACTIVE-4 to ACTIVE-6, ACTIVE-8 to ACTIVE-11: the header's control,
  with the count of the chats needing the user, and the menu behind it: the
  active chats, each a link to its chat and a row of its own, whose menu renames
  or deletes the chat without leaving the page.
  """
  def control(assigns) do
    assigns = assign(assigns, :row_events, @row_events)

    ~H"""
    <div class="relative">
      <%!-- ACTIVE-1: below the `sm` breakpoint only the icon and the count are
      shown, and the label stays in the DOM for screen readers (UI-37). --%>
      <button
        type="button"
        id="active-chats-toggle"
        phx-click="toggle_active_chats"
        aria-expanded={to_string(@state.open)}
        aria-controls="active-chats-menu"
        title="Active chats"
        class="flex items-center gap-1.5 rounded-lg p-2 text-sm transition hover:bg-base-200 sm:px-3 sm:py-1.5"
      >
        <.icon name="hero-bolt" class="size-4" />
        <span :if={@state.count > 0} id="active-chats-count" class="text-xs font-medium">
          {@state.count}
        </span>
        <span class="sr-only sm:not-sr-only">Active</span>
      </button>
      <%!-- ACTIVE-5: a backdrop closes the menu, as the chat list's drawer's
      does (UI-36). FEED-1: a backdrop is not a control, so it does not
      press. --%>
      <button
        :if={@state.open}
        type="button"
        id="active-chats-backdrop"
        phx-click="close_active_chats"
        aria-label="Close active chats"
        class="fixed inset-0 z-30 bg-black/40"
        data-press="none"
      ></button>
      <div
        :if={@state.open}
        id="active-chats-menu"
        phx-window-keydown="close_active_chats"
        phx-key="Escape"
        class="absolute right-0 z-40 mt-2 flex max-h-[70vh] w-80 max-w-[calc(100vw-2rem)] flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-xl"
      >
        <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
          <span class="text-sm font-medium">Active chats</span>
          <%!-- ACTIVE-4: what the menu doesn't list is counted here. --%>
          <span :if={@state.more > 0} id="active-chats-more" class="text-xs text-base-content/60">
            and {@state.more} more
          </span>
        </div>
        <div class="min-h-0 flex-1 overflow-y-auto">
          <%!-- ACTIVE-6: an empty menu says so. --%>
          <p
            :if={@state.chats == []}
            id="active-chats-empty"
            class="px-3 py-4 text-sm text-base-content/50"
          >
            No active chats — every chat is done.
          </p>
          <%!-- ACTIVE-2, ACTIVE-5: newest first, each a link to its chat, with
          the project it belongs to and its status — the one indicator the chat
          list draws (UI-46, UI-59), which names itself on hover and in
          words. ACTIVE-8, ACTIVE-9: the row is a chat's own row
          (`EliaWeb.ChatRowMenu`) — its menu opens on a long press, a
          right-click or the keyboard, and holds the same two entries the chat
          list's rows have — drawn under the `active-` scope, so a chat listed
          by both the header and the chat list has two menus of its own. --%>
          <ChatRowMenu.row
            :for={chat <- @state.chats}
            id={"active-chat-row-#{chat.id}"}
            chat={chat}
            scope="active-"
            renaming={@state.renaming == chat.id}
            events={@row_events}
            class="flex border-b border-base-300/60 last:border-b-0 transition hover:bg-base-200"
          >
            <.link
              id={"active-chat-#{chat.id}"}
              navigate={~p"/c/#{chat.id}"}
              data-row-link
              aria-haspopup="true"
              aria-expanded="false"
              aria-controls={"active-chat-row-menu-#{chat.id}"}
              title={chat.title}
              class="flex min-w-0 flex-1 items-center gap-2 px-3 py-2"
            >
              <ChatStatus.status_icon id={"active-chats-status-#{chat.id}"} status={chat.status} />
              <span class="min-w-0 flex-1">
                <span class="block truncate text-sm">{chat.title}</span>
                <span class="block truncate text-xs text-base-content/60">{chat.project}</span>
              </span>
            </.link>
          </ChatRowMenu.row>
        </div>
      </div>
    </div>
    """
  end

  ## State

  # ACTIVE-2, ACTIVE-3, ACTIVE-7: the active chats and the count, read from the
  # store and the registry.
  defp refresh(socket), do: put_state(socket, list())

  defp list do
    chats = Elia.Store.list(@read, where: &(Map.get(&1, :done) != true))
    projects = project_names()

    marks = %{
      awaiting: Elia.Agent.awaiting_approval(),
      input: Elia.Agent.awaiting_input(),
      paused: Elia.Agent.paused(),
      running: Elia.Agent.running()
    }

    rows = Enum.map(chats, &row(&1, projects, marks))

    %{
      chats: Enum.take(rows, @listed),
      more: max(length(rows) - @listed, 0),
      # ACTIVE-3: every active chat no turn is running in, over the whole list
      # rather than the `@listed` the menu shows.
      count: Enum.count(rows, &(&1.status != "working"))
    }
  end

  defp row(chat, projects, marks) do
    status =
      ChatStatus.status(chat, %{
        awaiting: chat.id in marks.awaiting,
        input: chat.id in marks.input,
        paused: chat.id in marks.paused,
        running: chat.id in marks.running,
        # STORE-31: the record a restart left behind.
        interrupted: Map.get(chat, :interrupted, false)
      })

    %{
      id: chat.id,
      title: chat.title,
      project: Map.get(projects, chat.project_id, "Elia"),
      status: status
    }
  end

  # PROJ-9: a chat with no project id belongs to Elia's own project, which the
  # dashboard's rows read the same way (DASH-3, DASH-5).
  defp project_names do
    Map.put_new_lazy(
      Map.new(Elia.Projects.list(), &{&1.id, &1.name}),
      nil,
      fn -> Elia.Projects.harness().name end
    )
  end

  defp subscribe(socket) do
    if connected?(socket), do: Elia.Agent.subscribe_activity()
    socket
  end

  defp put_state(socket, changes),
    do: assign(socket, :active_chats, Map.merge(socket.assigns.active_chats, Map.new(changes)))
end
