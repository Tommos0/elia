defmodule EliaWeb.ChatList do
  @moduledoc """
  The chat list: its state, the markup it is drawn with and the events that
  drive it (UI-4 to UI-6, UI-31 to UI-36, UI-45 to UI-47, UI-59, UI-63 to UI-65,
  UI-72, UI-76, UI-80, UI-84, UI-85, UI-91 to UI-93).

  The list is drawn in two places — the chat page's own sidebar (UI-4, UI-35,
  UI-36) and the drawer every page that keeps no list of its own opens (UI-91) —
  and both draw it from the state this module holds, so the two cannot drift
  apart. Its `on_mount/4` runs for every page of the live session (see
  `EliaWeb.Router`), which is what gives a page the drawer and its button
  without any wiring of its own.
  """

  use EliaWeb, :html

  alias EliaWeb.ChatStatus

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1, push_event: 3, push_navigate: 2, put_flash: 3]

  # UI-4, UI-84: the list's first page, and how many chats each "Load more
  # chats" adds.
  @chat_page 30

  @doc """
  UI-32, UI-36, UI-91 to UI-93: the chat list's state and events, on every page
  of the live session. The list itself is read when the page first draws it —
  the chat page's sidebar asks for it in `mount` (UI-4), and elsewhere it is read
  as the drawer opens (UI-92) — so a page that never shows it pays nothing.
  """
  def on_mount(:default, params, _session, socket) do
    socket =
      socket
      |> assign(:chat_list, %{
        # UI-36: the drawer starts closed.
        open: false,
        # UI-4, UI-91, UI-92: the chat this page is about, if it is about one.
        active: params["id"],
        chats: [],
        more_chats: false,
        limit: @chat_page,
        projects: [],
        # UI-31, UI-92: the project "New chat" starts a chat in (PROJ-8).
        project: nil,
        # UI-72: chats whose turn a restart cut short (STORE-31).
        interrupted: [],
        # UI-47, UI-58, UI-59, UI-76: the chats the registry marks.
        awaiting: [],
        input: [],
        paused: [],
        running: [],
        # UI-34: the clock the list's relative times read.
        now: nil
      })
      |> attach_hook(:chat_list_events, :handle_event, &handle_event/3)
      |> attach_hook(:chat_list_status, :handle_info, &handle_info/2)
      |> attach_hook(:chat_list_page, :handle_params, &put_page_chat/3)
      |> clock()

    {:cont, socket}
  end

  @doc """
  UI-5, UI-6, UI-63, UI-72, UI-92: the list read again from the store — the
  chats at the page size loaded (UI-84, UI-85) and the statuses that go with
  them — so a list that is on screen is as fresh as this read. The chat page
  asks for this itself (`EliaWeb.ChatLive`), since its sidebar is on screen from
  the first render (UI-4).
  """
  def refresh(socket) do
    state = socket.assigns.chat_list
    {chats, more_chats} = list_chats(state.limit)
    projects = Elia.Projects.list()

    put_state(socket,
      chats: chats,
      more_chats: more_chats,
      projects: projects,
      interrupted: interrupted_ids(chats),
      project: project_for(state.active, chats, projects),
      awaiting: Elia.Agent.awaiting_approval(),
      input: Elia.Agent.awaiting_input(),
      paused: Elia.Agent.paused(),
      running: Elia.Agent.running()
    )
  end

  ## Events

  # UI-32, UI-36, UI-91: the header's control opens and closes the list, and
  # never navigates. On a page that keeps no list of its own, opening it is what
  # reads the list in (UI-92).
  defp handle_event("toggle_chats", _params, socket) do
    open = not socket.assigns.chat_list.open
    socket = put_state(socket, open: open)

    {:halt, if(open, do: refresh(socket), else: socket)}
  end

  defp handle_event("close_chats", _params, socket),
    do: {:halt, put_state(socket, open: false)}

  # UI-84: "Load more chats" lists the next page — 30 more chats (UI-4), the
  # same prefix of STORE-12 order one page longer. The open chat, the drawer
  # (UI-36) and the list's scroll position are left where they are, so only the
  # list's own rows change. UI-85: the size is handed to the browser, which
  # remembers it for the tab and gives it back on the next mount, so opening
  # another chat re-lists these pages.
  defp handle_event("more_chats", _params, socket) do
    limit = socket.assigns.chat_list.limit + @chat_page

    {:halt, socket |> assign_limit(limit) |> push_event("chat_page", %{limit: limit})}
  end

  # UI-85: the size the browser remembers for this tab, pushed back by the
  # list's hook (`.ChatPageSize`) as it mounts. Below the first page (UI-4) it is
  # ignored rather than honoured, so a hand-written event can't shrink the list,
  # and anything that isn't a whole number of chats leaves it as it is.
  defp handle_event("chat_page", %{"limit" => limit}, socket) when is_integer(limit),
    do: {:halt, assign_limit(socket, max(limit, @chat_page))}

  defp handle_event("chat_page", _params, socket), do: {:halt, socket}

  # UI-64, UI-65, SESS-29: delete a chat from the list — the open one or any
  # other, running or not. Deleting the chat the page shows leaves for `/chats`,
  # the chat list's entry point (UI-77), which resumes the next chat or starts a
  # fresh one when there is none; deleting another leaves the page where it is.
  defp handle_event("delete_chat", %{"id" => id}, socket) do
    case Elia.Agent.delete(id) do
      :ok ->
        socket = socket |> refresh() |> put_flash(:info, "Chat deleted.")

        if id == socket.assigns.chat_list.active,
          do: {:halt, push_navigate(socket, to: ~p"/chats")},
          else: {:halt, socket}

      _error ->
        {:halt, put_flash(socket, :error, "That chat can't be deleted.")}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # UI-4, UI-84, UI-85: the listed chats, re-read at a page size, with the
  # interrupted markers that go with them (UI-72, STORE-31).
  defp assign_limit(socket, limit) do
    {chats, more_chats} = list_chats(limit)

    put_state(socket,
      limit: limit,
      chats: chats,
      more_chats: more_chats,
      interrupted: interrupted_ids(chats)
    )
  end

  ## Status and clock

  # UI-47, UI-58, UI-59, UI-72, UI-76: follows every chat's status, so the list
  # flags those awaiting approval, those waiting for an answer, those paused at a
  # limit and those working, and drops the marker of a chat whose session has
  # started — which is what clears the record the restart left behind (INTR-3).
  # The page's own handler for the same message runs after this one (UI-44).
  defp handle_info({:chat_status, id, status}, socket) do
    state = socket.assigns.chat_list

    state = %{
      state
      | awaiting: put_member(state.awaiting, id, status == :awaiting_approval),
        input: put_member(state.input, id, status == :awaiting_input),
        paused: put_member(state.paused, id, status == :paused),
        running: put_member(state.running, id, status == :running),
        interrupted: List.delete(state.interrupted, id)
    }

    if state == socket.assigns.chat_list,
      do: {:cont, socket},
      else: {:cont, assign(socket, :chat_list, state)}
  end

  # UI-34: the list's relative times keep up with the clock wherever it is
  # shown.
  defp handle_info(:chat_list_tick, socket) do
    Process.send_after(self(), :chat_list_tick, 60_000)
    {:halt, put_state(socket, now: DateTime.utc_now())}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp clock(socket) do
    if connected?(socket) do
      Elia.Agent.subscribe_activity()
      Process.send_after(self(), :chat_list_tick, 60_000)
    end

    put_state(socket, now: DateTime.utc_now())
  end

  # UI-4, UI-91, UI-92: which chat this page is about, so the list marks it the
  # active one and "New chat" starts in its project (UI-31); a page that is about
  # no chat has neither.
  defp put_page_chat(params, _uri, socket) do
    active = params["id"]

    if active == socket.assigns.chat_list.active,
      do: {:cont, socket},
      else: {:cont, refresh(put_state(socket, active: active))}
  end

  defp put_member(list, id, true), do: if(id in list, do: list, else: [id | list])
  defp put_member(list, id, false), do: List.delete(list, id)

  defp put_state(socket, changes),
    do: assign(socket, :chat_list, Map.merge(socket.assigns.chat_list, Map.new(changes)))

  ## The list's own data

  # UI-4, UI-84: the chats the list shows — one page, or as many pages as the
  # user loaded (UI-85) — and whether the store holds more than that. One chat
  # past the page is enough to know: a page is a prefix of STORE-12 order, so
  # the store is read once and not twice.
  defp list_chats(limit) do
    case Elia.Store.list(limit + 1) do
      chats when length(chats) > limit -> {Enum.take(chats, limit), true}
      chats -> {chats, false}
    end
  end

  # UI-72, STORE-31: the chats whose saved turn a restart cut short, so the list
  # is right on first render and every page shows the same.
  defp interrupted_ids(chats), do: for(%{interrupted: true} = chat <- chats, do: chat.id)

  # UI-31, PROJ-8, UI-92: the project "New chat" starts a chat in — this page's
  # chat's own project (PROJ-26), or the default project where the page is about
  # no chat or its chat isn't among those listed.
  defp project_for(active, chats, projects) do
    with id when is_binary(id) <- active,
         %{project_id: project_id} <- Enum.find(chats, &(&1.id == id)),
         %{} = project <- Enum.find(projects, &(&1.id == (project_id || "harness"))) do
      project
    else
      _none -> Elia.Projects.default()
    end
  end

  ## The list itself

  attr :state, :map, required: true, doc: "the chat list's state (UI-92)"

  # UI-92: the list is drawn twice — the chat page's sidebar (UI-4) and the
  # drawer the other pages open (UI-91) — and a page has one of them. Every id
  # the list renders carries this, so the two can never collide with each other
  # or with the page's own markup (a page's "New chat" button, say), and the
  # sidebar's ids are what they have always been (no scope).
  attr :scope, :string, default: "", doc: "the id prefix for this copy of the list (UI-92)"

  attr :active, :string,
    default: nil,
    doc: "the chat the page is showing, if it is showing one (UI-4)"

  attr :project, :map,
    default: nil,
    doc: "the project \"New chat\" starts a chat in (UI-31, UI-92)"

  @doc """
  UI-4, UI-5, UI-31 to UI-34, UI-36, UI-64, UI-84, UI-91, UI-92: the chat list.
  The chat page draws it as its own sidebar (UI-4, UI-35, UI-36) and the drawer
  the other pages open draws the same, from the same state (UI-91).
  """
  def chat_list(assigns) do
    assigns =
      assign(assigns,
        active: assigns.active || assigns.state.active,
        project: assigns.project || assigns.state.project,
        statuses: Map.take(assigns.state, [:awaiting, :input, :paused, :running, :interrupted])
      )

    ~H"""
    <%!-- UI-85: how much of the chat list this tab has loaded, so opening
    another chat — which mounts a page again — re-lists the same pages rather
    than starting from the first one (UI-4). The server decides the number
    (UI-84): the hook hands back what it stored and writes down what it is told.
    Without it, or with nothing stored, the list is the first page, as before. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatPageSize">
      const KEY = "elia:chat-page"

      export default {
        mounted() {
          this.handleEvent("chat_page", ({limit}) => {
            try { sessionStorage.setItem(KEY, String(limit)) } catch (_e) {}
          })

          let limit = null
          try { limit = parseInt(sessionStorage.getItem(KEY), 10) } catch (_e) {}
          if (limit) this.pushEvent("chat_page", {limit})
        }
      }
    </script>
    <p class="px-4 pt-4 pb-2 text-xs font-medium uppercase tracking-wider text-base-content/50">
      Chats
    </p>
    <%!-- UI-31, PROJ-26: start a chat in the open chat's project. --%>
    <.link
      :if={@project}
      navigate={~p"/p/#{@project.id}/new"}
      id={"#{@scope}new-chat"}
      class="mx-2 mb-1 flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition hover:bg-base-200"
    >
      <.icon name="hero-plus" class="size-4" /> New chat
    </.link>
    <nav id={"#{@scope}chat-list"} class="flex-1 space-y-0.5 overflow-y-auto px-2 pb-4">
      <%!-- UI-4, PROJ-24: chats grouped by project, newest first --%>
      <%= for group <- project_groups(@state.projects, @state.chats) do %>
        <div
          id={"#{@scope}project-header-#{group.project.id}"}
          class="flex items-center gap-1 px-3 pt-3 pb-1"
        >
          <.icon name="hero-rectangle-stack" class="size-3.5 shrink-0 text-base-content/40" />
          <span class="min-w-0 flex-1 truncate text-xs font-medium uppercase tracking-wider text-base-content/50">
            {group.project.name}
          </span>
          <.link
            navigate={~p"/p/#{group.project.id}/new"}
            id={"#{@scope}new-chat-#{group.project.id}"}
            title={"New chat in #{group.project.name}"}
            class="rounded-md p-1 text-base-content/50 transition hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-plus" class="size-3.5" />
          </.link>
        </div>
        <%= for {chat, children} <- group.tree do %>
          <.chat_row
            chat={chat}
            active={chat.id == @active}
            statuses={@statuses}
            now={@state.now}
            scope={@scope}
          />
          <div
            :if={children != []}
            id={"#{@scope}chat-children-#{chat.id}"}
            class="ml-3 space-y-0.5 border-l border-base-300 pl-1.5"
          >
            <.chat_row
              :for={child <- children}
              chat={child}
              active={child.id == @active}
              statuses={@statuses}
              now={@state.now}
              scope={@scope}
            />
          </div>
        <% end %>
      <% end %>
      <p :if={@state.chats == []} class="px-3 py-2 text-sm text-base-content/50">No chats yet</p>
    </nav>
    <%!-- UI-4, UI-84: the list's next page. Below the list's scroll box
    (`#chat-list`), not inside it, so the button is visible without scrolling to
    the end of the list. --%>
    <button
      :if={@state.more_chats}
      type="button"
      id={"#{@scope}load-more-chats"}
      phx-click="more_chats"
      class="mx-2 mb-2 shrink-0 rounded-lg border border-base-300 px-3 py-2 text-sm font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
    >
      Load more chats
    </button>
    """
  end

  attr :chat, :map, required: true
  attr :active, :boolean, required: true
  attr :now, :any, required: true
  attr :statuses, :map, required: true
  attr :scope, :string, default: ""

  # UI-4, UI-34, UI-46, UI-47, UI-58, UI-59, UI-64, UI-72, UI-76
  defp chat_row(assigns) do
    status_state = %{
      awaiting: assigns.chat.id in assigns.statuses.awaiting,
      input: assigns.chat.id in assigns.statuses.input,
      paused: assigns.chat.id in assigns.statuses.paused,
      running: assigns.chat.id in assigns.statuses.running,
      interrupted: assigns.chat.id in assigns.statuses.interrupted
    }

    assigns =
      assign(assigns,
        status_id: "#{assigns.scope}chat-status-#{assigns.chat.id}",
        status: ChatStatus.status(assigns.chat, status_state)
      )

    ~H"""
    <%!-- UI-64: the delete button sits beside the link, as its sibling, so no
    interactive element is nested inside another. --%>
    <div id={"#{@scope}chat-row-#{@chat.id}"} class="flex gap-0.5">
      <.link
        navigate={~p"/c/#{@chat.id}"}
        id={"#{@scope}chat-link-#{@chat.id}"}
        title={@chat.description}
        class={[
          "block min-w-0 flex-1 rounded-lg px-3 py-2 text-sm transition",
          @active && "bg-base-300 font-medium",
          !@active && "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        ]}
      >
        <span class="flex items-center gap-1.5">
          <ChatStatus.status_icon id={@status_id} status={@status} />
          <span class="block min-w-0 flex-1 truncate">{@chat.title}</span>
        </span>
        <time
          id={"#{@scope}chat-time-#{@chat.id}"}
          datetime={DateTime.to_iso8601(@chat.created_at)}
          title={Calendar.strftime(@chat.created_at, "%Y-%m-%d %H:%M:%S UTC")}
          class="block text-xs font-normal text-base-content/50"
        >
          {EliaWeb.TimeAgo.format(@chat.created_at, @now)}
        </time>
      </.link>
      <button
        type="button"
        id={"#{@scope}delete-chat-#{@chat.id}"}
        phx-click="delete_chat"
        phx-value-id={@chat.id}
        data-confirm={"Delete the chat #{@chat.title}? This can't be undone."}
        aria-label="Delete chat"
        title="Delete chat"
        class="shrink-0 rounded-lg px-1.5 text-base-content/40 transition hover:bg-error/10 hover:text-error focus-visible:bg-error/10 focus-visible:text-error focus-visible:outline-none"
      >
        <.icon name="hero-trash" class="size-3.5" />
      </button>
    </div>
    """
  end

  # UI-45: task chats nested under their parent; orphans stay at the top level.
  defp chat_tree(chats) do
    ids = MapSet.new(chats, & &1.id)
    {nested, top} = Enum.split_with(chats, &(Map.get(&1, :parent_id) in ids))
    by_parent = nested |> Enum.reverse() |> Enum.group_by(& &1.parent_id)
    Enum.map(top, &{&1, Map.get(by_parent, &1.id, [])})
  end

  # PROJ-24: the listed chats grouped by project, each project with its nested
  # tree of chats. A chat without a project id belongs to Elia's own project
  # (PROJ-9); projects without chats still get an entry (an empty tree).
  defp project_groups(projects, chats) do
    by_project = Enum.group_by(chats, &(&1.project_id || "harness"))

    Enum.map(projects, fn project ->
      %{project: project, tree: chat_tree(Map.get(by_project, project.id, []))}
    end)
  end
end
