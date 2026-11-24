defmodule EliaWeb.ChatList do
  @moduledoc """
  The chat list: its state, the markup it is drawn with and the events that
  drive it (UI-4 to UI-6, UI-31 to UI-36, UI-45 to UI-47, UI-59, UI-63 to UI-65,
  UI-72, UI-76, UI-80, UI-84, UI-85, UI-91 to UI-93, UI-105 to UI-108), and the
  project whose chats it lists (PROJ-28 to PROJ-31).

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

  # UI-105: the filters the list is shown under, and the buttons that drive
  # them — the group each toggles, the name its button carries and the icon it
  # shows.
  @filter_groups [
    {"running", "Running chats", "hero-arrow-path"},
    {"idle", "Idle chats", "hero-moon"},
    {"done", "Finished chats", "hero-check-circle"}
  ]

  # UI-105, UI-108: what the filters start as — one boolean per group, all on
  # until a press (UI-106) or the tab's stored value (UI-108) says otherwise.
  @filters Map.new(@filter_groups, fn {group, _label, _icon} -> {group, true} end)

  # UI-106: the status (UI-59) each group hides. A chat showing any other
  # status is never hidden.
  @filter_status %{"running" => "working", "idle" => "idle", "done" => "done"}

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
        # UI-104: the chat whose row is showing a box to type a name in, or nil
        # when no row is being renamed. One at a time, and the server's: the row
        # itself is what changes shape.
        renaming: nil,
        projects: [],
        # UI-31, PROJ-28, PROJ-31: the project the interface has open — what
        # "New chat" starts a chat in, whose chats the list holds, and what the
        # header names (PROJ-29).
        open_project: nil,
        # PROJ-29: the open project's menu, closed until the header opens it.
        projects_open: false,
        # UI-72: chats whose turn a restart cut short (STORE-31).
        interrupted: [],
        # UI-47, UI-58, UI-59, UI-76: the chats the registry marks.
        awaiting: [],
        input: [],
        paused: [],
        running: [],
        # UI-105, UI-108: the filters the list is shown under, all on until a
        # press (UI-106) or the tab's stored value (UI-108) says otherwise.
        filters: @filters,
        # UI-34: the clock the list's relative times read.
        now: nil
      })
      |> attach_hook(:chat_list_events, :handle_event, &handle_event/3)
      |> attach_hook(:chat_list_status, :handle_info, &handle_info/2)
      |> attach_hook(:chat_list_page, :handle_params, &put_page_chat/3)
      |> put_projects()
      |> clock()

    {:cont, socket}
  end

  # PROJ-28, PROJ-29: the header names the open project on every page, from the
  # first render — so which project is open and which ones there are is read
  # here, while the chats themselves wait until a page draws the list (UI-92).
  defp put_projects(socket) do
    projects = Elia.Projects.list()

    put_state(socket,
      projects: projects,
      open_project: open_project(socket.assigns.chat_list.active, projects)
    )
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
    projects = Elia.Projects.list()
    # PROJ-28: a page that is about a chat opens that chat's project. PROJ-29,
    # PROJ-31: the header and the list follow the project that is open.
    open = open_project(state.active, projects)
    {chats, more_chats} = list_chats(state.limit, open)

    put_state(socket,
      chats: chats,
      more_chats: more_chats,
      projects: projects,
      interrupted: interrupted_ids(chats),
      open_project: open,
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

  # PROJ-29: the header's project control, which opens and closes the menu a
  # project is switched in. It is drawn like the settings page's pickers: the
  # trigger asks to close while the menu is open, so a press on it is not also a
  # press outside the menu.
  defp handle_event("open_projects", _params, socket),
    do: {:halt, put_state(socket, projects_open: true)}

  defp handle_event("close_projects", _params, socket),
    do: {:halt, put_state(socket, projects_open: false)}

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

  # UI-105, UI-106: a press on one of the list's filter buttons — the group is
  # that button's own, and a press flips whether the list shows that group.
  # UI-108: the state a press leaves is handed to the browser to keep, so the
  # next page of the session shows the list under the same filters.
  defp handle_event("toggle_filter", %{"group" => group}, socket) do
    case socket.assigns.chat_list.filters do
      %{^group => shown} ->
        filters = Map.put(socket.assigns.chat_list.filters, group, not shown)

        {:halt, socket |> put_state(filters: filters) |> push_event("chat_filter", filters)}

      _other ->
        {:halt, socket}
    end
  end

  # UI-108: the filters the tab stored, handed back by the list's hook as it
  # mounts. The server decides them: three booleans, one per toggle, and
  # anything else — a key missing, a value that isn't a boolean, a hand-written
  # event — leaves them as they are, which is the all-on default (UI-105).
  defp handle_event("chat_filter", %{"running" => r, "idle" => i, "done" => d}, socket)
       when is_boolean(r) and is_boolean(i) and is_boolean(d),
       do: {:halt, put_state(socket, filters: %{"running" => r, "idle" => i, "done" => d})}

  defp handle_event("chat_filter", _params, socket), do: {:halt, socket}

  # UI-103, UI-104: a chat's row in the chat list opens a menu from its own
  # trigger; "Rename" is one of the things in it, and the box it opens takes
  # the row's link's place. The name is posted on Enter (the form's own
  # `phx-submit`) and the list is read again, so the row shows the new name —
  # which is the chat's own from now on (TITLE-8, STORE-55).
  defp handle_event("start_rename", %{"id" => id}, socket),
    do: {:halt, put_state(socket, renaming: id)}

  # UI-104: the box's Cancel button leaves the row as it was.
  defp handle_event("cancel_rename", _params, socket),
    do: {:halt, put_state(socket, renaming: nil)}

  # UI-104: the box a row shows posts its name on Enter. Which chat that is is
  # this list's own state — one row is being renamed at a time, and it is the
  # row the box is drawn in — so the name is not carried in the form. An
  # accepted name is the chat's own title from then on (TITLE-8, STORE-55) and
  # the list is read again, so the row shows it.
  defp handle_event("rename_chat", %{"title" => title}, socket) do
    with id when is_binary(id) <- socket.assigns.chat_list.renaming,
         {:ok, _title} <- Elia.Agent.rename(id, title) do
      {:halt, socket |> put_state(renaming: nil) |> refresh()}
    else
      # TITLE-2, UI-104: a name that is blank once trimmed is no title at all,
      # so it saves nothing and the row goes back to what it showed — exactly
      # as cancelling leaves it. No row being renamed at all (a stale client)
      # is nothing to do either.
      _refused -> {:halt, put_state(socket, renaming: nil)}
    end
  end

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
    {chats, more_chats} = list_chats(limit, socket.assigns.chat_list.open_project)

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
  defp handle_info({:chat_status, id, status}, socket) do
    # UI-49: the list is read again, so a row follows a change the status alone
    # doesn't carry — a chat's done flag (STORE-35, DONE-2), or a task chat
    # started since the page drew the list. A page that shows no list pays
    # nothing (UI-92).
    socket =
      if socket.assigns.chat_list.open or socket.assigns.chat_list.chats != [] do
        refresh(socket)
      else
        socket
      end

    # UI-47, UI-58, UI-59, UI-72, UI-76: the event says what the chat is doing
    # now, so its row reads that — whatever the list, read a moment ago, said
    # about it — and its interrupted marker goes (INTR-3).
    {:cont, put_status_marks(socket, id, status)}
  end

  # UI-34: the list's relative times keep up with the clock wherever it is
  # shown.
  defp handle_info(:chat_list_tick, socket) do
    Process.send_after(self(), :chat_list_tick, 60_000)
    {:halt, put_state(socket, now: DateTime.utc_now())}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  # UI-47, UI-58, UI-59, UI-72, UI-76: the markers one chat's status event sets.
  defp put_status_marks(socket, id, status) do
    state = socket.assigns.chat_list

    put_state(socket,
      awaiting: put_member(state.awaiting, id, status == :awaiting_approval),
      input: put_member(state.input, id, status == :awaiting_input),
      paused: put_member(state.paused, id, status == :paused),
      running: put_member(state.running, id, status == :running),
      interrupted: List.delete(state.interrupted, id)
    )
  end

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

  # UI-4, UI-84, PROJ-31: the chats the list shows — one page, or as many pages
  # as the user loaded (UI-85) — the open project's and no other project's, and
  # whether the store holds more of them than that. One chat past the page is
  # enough to know: a page is a prefix of STORE-12 order, so the store is read
  # once and not twice (STORE-52).
  defp list_chats(limit, project) do
    where = Elia.Projects.chats_of(project)

    case Elia.Store.list(limit + 1, where: where) do
      chats when length(chats) > limit -> {Enum.take(chats, limit), true}
      chats -> {chats, false}
    end
  end

  # UI-72, STORE-31: the chats whose saved turn a restart cut short, so the list
  # is right on first render and every page shows the same.
  defp interrupted_ids(chats), do: for(%{interrupted: true} = chat <- chats, do: chat.id)

  # PROJ-28: the project the interface has open — this page's chat's own project
  # (PROJ-9) when the page is about a chat, and the stored default (PROJ-8)
  # otherwise. Opening a chat opens its project, so a new chat started from the
  # list (UI-31) and a new chat started from `/chats` (UI-77) are in the project
  # the page shows, whatever the settings said before.
  defp open_project(active, projects) do
    case chat_project(active, projects) do
      nil ->
        Elia.Projects.default()

      project ->
        :ok = Elia.Projects.set_default(project.id)
        project
    end
  end

  # PROJ-9: the project this page's chat belongs to — its own, or Elia's own for
  # a chat with none and one whose project is gone (PROJ-7) — or `nil` when the
  # page is about no chat at all, which is what sends a caller to the default.
  defp chat_project(active, projects) when is_binary(active) do
    Enum.find(projects, &(&1.id == Elia.Store.load_project(active))) ||
      Enum.find(projects, & &1.harness?)
  end

  defp chat_project(_active, _projects), do: nil

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

  attr :open_project, :map,
    default: nil,
    doc: "the open project, which \"New chat\" starts a chat in (UI-31, PROJ-28)"

  @doc """
  UI-4, UI-5, UI-31 to UI-34, UI-36, UI-64, UI-84, UI-91, UI-92, UI-105 to
  UI-107: the chat list. The chat page draws it as its own sidebar (UI-4,
  UI-35, UI-36) and the drawer the other pages open draws the same, from the
  same state (UI-91).
  """
  def chat_list(assigns) do
    statuses = Map.take(assigns.state, [:awaiting, :input, :paused, :running, :interrupted])

    assigns =
      assign(assigns,
        active: assigns.active || assigns.state.active,
        open_project: assigns.open_project || assigns.state.open_project,
        statuses: statuses,
        filter_groups: @filter_groups,
        # UI-106, UI-107: the chats the filters leave listed, so the list draws
        # those and can tell "the filters hide them all" from "nothing saved"
        # (UI-5).
        shown: shown_chats(assigns.state.chats, statuses, assigns.state.filters)
      )

    ~H"""
    <%!-- UI-85, UI-108: what this tab has the list shown under — how much of it
    it has loaded, so opening another chat — which mounts a page again —
    re-lists the same pages rather than starting from the first one (UI-4), and
    which filters it hides chats by (UI-105), so another chat opens under the
    same filters. The server decides both (UI-84, UI-108): the hook hands back
    what it stored and writes down what it is told. Without it, or with nothing
    stored, the list is the first page, unfiltered.
    It hangs off this list (`#chat-list`), and its name is resolved against the
    module the markup is compiled in — `EliaWeb.ChatList` — so the two belong in
    this file together: a `phx-hook` in another module's template would name a
    hook that is not there. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatPageSize">
      const KEY = "elia:chat-page"
      const FILTER_KEY = "elia:chat-filter"

      export default {
        mounted() {
          this.handleEvent("chat_page", ({limit}) => {
            try { sessionStorage.setItem(KEY, String(limit)) } catch (_e) {}
          })

          this.handleEvent("chat_filter", (filters) => {
            try { sessionStorage.setItem(FILTER_KEY, JSON.stringify(filters)) } catch (_e) {}
          })

          let limit = null
          try { limit = parseInt(sessionStorage.getItem(KEY), 10) } catch (_e) {}
          if (limit) this.pushEvent("chat_page", {limit})

          let filters = null
          try { filters = JSON.parse(sessionStorage.getItem(FILTER_KEY)) } catch (_e) {}
          if (filters && typeof filters === "object") this.pushEvent("chat_filter", filters)
        }
      }
    </script>
    <%!-- UI-64, UI-103, UI-104 (specs/chat-ui.md): a chat's row holds its link
    and the menu the row opens. The menu is the client's, not the server's — LiveView
    draws it once and never patches it again (`phx-update="ignore"`), and
    whether it is open is the DOM's own state (the element's own `style`) — so
    the pane a row sits in has no event of its own that opens one or shuts one.
    The gesture is the hook's too: a press held for half a second, a press with
    the right button (which is the browser's own long press on a phone, the
    `contextmenu` event), and the keyboard's context-menu key while the row's
    link has focus. No timer on the server, and no event per row. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatRowMenu">
      // UI-103: half a second is a long press; less is a press on the link.
      const PRESS_MS = 500
      // A press that has travelled this far is a scroll or a drag, not a press
      // held on the row: the browser is taking it over.
      const MOVE_SLOP = 12
      // The menu is shut in its own markup (UI-103), so it is never a rule in
      // the stylesheet that keeps a closed menu from swallowing a press.
      const SHUT = "none"
      const OPEN = "block"
      // How long after a long press released the click that ends it is still
      // the press that opened the menu, and not a press on the row as well.
      const SWALLOW_MS = 700
      const MARGIN = 8
      // UI-103: one row's menu is open at a time — this is how a row that opens
      // one shuts another.
      const ANNOUNCE = "chat-row-menu"

      export default {
        mounted() {
          this.row = this.el
          this.menu = this.row.querySelector("[data-row-menu]")
          this.link = this.row.querySelector("[data-row-link]")
          this.press = null
          this.from = null
          this.openedAt = 0

          this.cancelPress = () => {
            if (this.press) clearTimeout(this.press)
            this.press = null
            this.from = null
          }

          this.isOpen = () => !!this.menu && this.menu.style.display !== SHUT

          this.setOpen = open => {
            if (this.menu) this.menu.setAttribute("aria-hidden", String(!open))
            if (this.link) this.link.setAttribute("aria-expanded", String(open))
          }

          // UI-103: the menu is drawn from the row's link when the keyboard
          // opened it, and from the point the press was at otherwise (a long
          // press's own coordinates, or the `contextmenu` event's, which is a
          // point in the viewport). Kept inside the viewport: it is positioned
          // against the viewport rather than inside the list's scroll box,
          // which would clip it.
          this.place = (x, y) => {
            this.menu.style.left = "0px"
            this.menu.style.top = "0px"
            const box = this.menu.getBoundingClientRect()
            const link = this.link ? this.link.getBoundingClientRect() : this.row.getBoundingClientRect()
            let left = typeof x === "number" ? x : link.left
            let top = typeof y === "number" ? y : link.bottom

            left = Math.min(left, window.innerWidth - box.width - MARGIN)
            top = Math.min(top, window.innerHeight - box.height - MARGIN)
            this.menu.style.left = `${Math.max(MARGIN, left)}px`
            this.menu.style.top = `${Math.max(MARGIN, top)}px`
          }

          this.open = (x, y) => {
            // UI-104: a row that is a box to type a name in is not one a menu
            // opens from — the same press belongs to the box.
            if (!this.menu || this.row.querySelector("input")) return
            this.openedAt = Date.now()
            this.place(x, y)
            this.menu.style.display = OPEN
            this.setOpen(true)
            // UI-103: one menu at a time.
            window.dispatchEvent(new CustomEvent(ANNOUNCE, { detail: { row: this.row } }))
            // A press at a point away shuts it, and Escape the keyboard's
            // context-menu key opened it with shuts it from wherever the focus
            // is — so only an open menu listens for either.
            document.addEventListener("pointerdown", this.onAway, true)
            document.addEventListener("keydown", this.onKey, true)
          }

          this.close = () => {
            if (!this.menu) return
            this.menu.style.display = SHUT
            this.setOpen(false)
            document.removeEventListener("pointerdown", this.onAway, true)
            document.removeEventListener("keydown", this.onKey, true)
          }

          this.focusRow = () => {
            if (this.link) this.link.focus()
          }

          this.onAway = event => {
            if (this.row.contains(event.target)) return
            if (this.menu.contains(event.target)) return
            this.close()
          }

          // UI-103: a press at another point in the row shuts a menu that is
          // open, and starts the long press this one is. A press on the menu
          // itself is neither — it is a press on an entry.
          this.onPointerDown = event => {
            if (event.button > 0) return
            if (event.target.closest("[data-row-menu], input")) return
            this.cancelPress()
            if (this.isOpen()) this.close()
            this.from = { x: event.clientX, y: event.clientY, at: Date.now() }
            const { clientX: x, clientY: y } = event
            this.press = setTimeout(() => this.open(x, y), PRESS_MS)
          }

          // UI-103: a press that travels — a finger scrolling, a drag — is not
          // a press held on the row, so it opens nothing and leaves the list
          // scrolling as it did. The browser's own `pointercancel` (a touch
          // scroll it took over) lands in the same place.
          this.onPointerMove = event => {
            if (!this.press || !this.from) return
            const dx = event.clientX - this.from.x
            const dy = event.clientY - this.from.y
            if (Math.sqrt(dx * dx + dy * dy) > MOVE_SLOP) this.cancelPress()
          }

          // UI-103: the browser's own long press is the `contextmenu` event on
          // the platforms that fire one, and the right button on a desktop.
          // Never the browser's own menu.
          this.onContextMenu = event => {
            if (event.target.closest("input")) return
            event.preventDefault()
            const held = this.press && this.from && Date.now() - this.from.at >= PRESS_MS
            this.cancelPress()
            // The press this hook opened the menu with is not a second press.
            if (held && this.isOpen()) return
            if (this.isOpen()) this.close()
            else this.open(event.clientX, event.clientY)
          }

          // UI-103: a press that opened the menu must not also open the chat,
          // and a press on an entry of the menu is a press on the menu — it is
          // chosen, and the menu shuts.
          this.onClick = event => {
            // UI-104: a row whose box is open is a form, not a row's link.
            if (event.target.closest("input")) return
            if (event.target.closest("[data-row-menu]")) {
              this.close()
              return
            }
            if (!this.isOpen()) return
            // The menu has just been opened: this click is the press that did
            // it, not a press on the row, which would open the chat as well.
            event.preventDefault()
            event.stopPropagation()
          }

          // UI-103: the keyboard's own context menu — the context-menu key, or
          // Shift+F10 — opens the row's menu while the row's link has focus.
          this.onRowKey = event => {
            if (event.key !== "ContextMenu" && !(event.shiftKey && event.key === "F10")) return
            event.preventDefault()
            if (this.isOpen()) this.close()
            else this.open()
          }

          // UI-103: Escape shuts it and puts focus back on the row's link. The
          // event stops here, so a pane's own Escape — the drawer's, say — is
          // not what a menu's Escape also fires (it is listened for while the
          // menu is open, so nothing listens for it otherwise).
          this.onKey = event => {
            if (event.key !== "Escape" || !this.isOpen()) return
            event.stopPropagation()
            event.preventDefault()
            this.close()
            this.focusRow()
          }

          // UI-103: a menu is not what the list is showing once the pane
          // changes its chat, so it shuts as the page moves.
          this.onNavigate = () => this.close()

          this.onOtherOpen = event => {
            if (event.detail.row !== this.row) this.close()
          }

          this.row.addEventListener("pointerdown", this.onPointerDown)
          this.row.addEventListener("pointermove", this.onPointerMove)
          this.row.addEventListener("contextmenu", this.onContextMenu)
          this.row.addEventListener("click", this.onClick)
          this.row.addEventListener("pointerup", this.cancelPress)
          this.row.addEventListener("pointercancel", this.cancelPress)
          this.row.addEventListener("pointerleave", this.cancelPress)
          this.row.addEventListener("keydown", this.onRowKey)
          window.addEventListener(ANNOUNCE, this.onOtherOpen)
          window.addEventListener("phx:navigate", this.onNavigate)
          window.addEventListener("popstate", this.onNavigate)
        },

        // A re-render patches the row's children — the link becomes the name's
        // box and back, or the row's chat is renamed — but the menu itself is
        // never patched (UI-103). A menu that is open stays exactly as it was
        // drawn, shut or open, since that is this hook's state and no longer
        // LiveView's.
        updated() {
          this.menu = this.row.querySelector("[data-row-menu]")
          this.link = this.row.querySelector("[data-row-link]")
          if (this.isOpen()) this.setOpen(true)
        },

        destroyed() {
          this.cancelPress()
          document.removeEventListener("pointerdown", this.onAway, true)
          document.removeEventListener("keydown", this.onKey, true)
          window.removeEventListener(ANNOUNCE, this.onOtherOpen)
          window.removeEventListener("phx:navigate", this.onNavigate)
          window.removeEventListener("popstate", this.onNavigate)
        }
      }
    </script>

    <%!-- UI-104: the input a row shows while it is being renamed. It is a hook
    because what the spec asks for is what only the browser can do — the title
    selected as the box opens, so it can be typed over at once, and the two
    cancels that are not a control of the row: a press outside the input (the
    focus leaving it) and Escape. Escape stops there, so a pane's own Escape —
    the drawer's, say — is not what cancelling also fires. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatRename">
      export default {
        mounted() {
          this.el.focus()
          this.el.select()

          this.onBlur = () => this.pushEvent("cancel_rename", {})
          this.onKey = event => {
            if (event.key !== "Escape") return
            event.stopPropagation()
            this.pushEvent("cancel_rename", {})
          }

          this.el.addEventListener("blur", this.onBlur)
          this.el.addEventListener("keydown", this.onKey)
        },

        destroyed() {
          this.el.removeEventListener("blur", this.onBlur)
          this.el.removeEventListener("keydown", this.onKey)
        }
      }
    </script>
    <%!-- UI-105: the filters the list is shown under, at the top of the list —
    one toggle per group (UI-106), driven by the presses below. --%>
    <div class="flex items-center justify-between gap-2 px-4 pt-4 pb-2">
      <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">Chats</p>
      <div id={"#{@scope}chat-filters"} class="flex items-center gap-1">
        <button
          :for={{group, label, icon} <- @filter_groups}
          type="button"
          id={"#{@scope}filter-#{group}"}
          phx-click="toggle_filter"
          phx-value-group={group}
          aria-pressed={to_string(Map.fetch!(@state.filters, group))}
          aria-label={label}
          title={label}
          class={filter_button_class(Map.fetch!(@state.filters, group))}
        >
          <.icon name={icon} class="size-4" />
        </button>
      </div>
    </div>
    <%!-- UI-31, PROJ-26: start a chat in the open project — the open chat's own
    project when the page shows one (PROJ-28). --%>
    <.link
      :if={@open_project}
      navigate={~p"/p/#{@open_project.id}/new"}
      id={"#{@scope}new-chat"}
      class="mx-2 mb-1 flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition hover:bg-base-200"
    >
      <.icon name="hero-plus" class="size-4" /> New chat
    </.link>
    <nav
      id={"#{@scope}chat-list"}
      phx-hook=".ChatPageSize"
      class="flex-1 space-y-0.5 overflow-y-auto px-2 pb-4"
    >
      <%!-- UI-4, PROJ-31: the open project's chats, newest first, with a task
      chat nested under the parent it belongs to (UI-45) — UI-106: as many of
      them as the filters leave shown, so a task chat whose parent a filter
      hides is listed at the top level, as one whose parent is not loaded is
      (UI-45). --%>
      <%= for {chat, children} <- chat_tree(@shown) do %>
        <.chat_row
          chat={chat}
          active={chat.id == @active}
          statuses={@statuses}
          now={@state.now}
          scope={@scope}
          renaming={@state.renaming == chat.id}
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
            renaming={@state.renaming == child.id}
          />
        </div>
      <% end %>
      <%!-- UI-5: nothing saved in the open project; UI-107: chats saved, and
      every one the list holds hidden by the filters. --%>
      <p :if={@state.chats == []} class="px-3 py-2 text-sm text-base-content/50">No chats yet</p>
      <p :if={@state.chats != [] and @shown == []} class="px-3 py-2 text-sm text-base-content/50">
        No chats match the filters
      </p>
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
  attr :renaming, :boolean, default: false

  # UI-4, UI-34, UI-46, UI-47, UI-58, UI-59, UI-64, UI-72, UI-76, UI-103, UI-104
  defp chat_row(assigns) do
    assigns =
      assign(assigns,
        status_id: "#{assigns.scope}chat-status-#{assigns.chat.id}",
        # UI-46: a task chat's row is the row any chat has, from the one
        # derivation its header (UI-48) reads too.
        status: ChatStatus.for_chat(assigns.chat, assigns.statuses)
      )

    ~H"""
    <%!-- UI-64, UI-103: the row's link, and the row's own menu beside it — the
    menu the row opens with a long press, a right-click or the keyboard, and the
    one place a chat is deleted from (UI-64). UI-104: while the row is being
    renamed its input takes the link's place, so the row's link is not rendered
    then and no control is nested in another. --%>
    <div
      id={"#{@scope}chat-row-#{@chat.id}"}
      phx-hook=".ChatRowMenu"
      data-row-chat={@chat.id}
      class="flex"
    >
      <.chat_rename_form :if={@renaming} chat={@chat} scope={@scope} />
      <.chat_link
        :if={!@renaming}
        chat={@chat}
        status_id={@status_id}
        status={@status}
        active={@active}
        now={@now}
        scope={@scope}
      />
      <.chat_row_menu chat={@chat} scope={@scope} />
    </div>
    """
  end

  attr :chat, :map, required: true
  attr :status_id, :string, required: true
  attr :status, :atom, required: true
  attr :active, :boolean, required: true
  attr :now, :any, required: true
  attr :scope, :string, default: ""

  # UI-4, UI-34, UI-59, UI-74: the row's link — a press on it opens the chat.
  # UI-103: it is also where the menu's gesture is looked for and what the
  # keyboard is on, which is why the hook finds it by `data-row-link`.
  defp chat_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/c/#{@chat.id}"}
      id={"#{@scope}chat-link-#{@chat.id}"}
      data-row-link
      aria-haspopup="true"
      aria-expanded="false"
      aria-controls={"#{@scope}chat-row-menu-#{@chat.id}"}
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
    """
  end

  attr :chat, :map, required: true
  attr :scope, :string, default: ""

  # UI-104: naming a chat in its row. The input holds the chat's own title (the
  # row's `title` attribute stays the description, UI-33, and is not what the
  # input holds) with all of it selected and focused, so it can be typed over at
  # once; Enter saves it — the form's own `phx-submit` — and Escape, a press
  # outside it and losing focus cancel it. `.ChatRename` is what focuses and
  # selects, since an attribute can say neither. Cancel is a control of its own,
  # the accessible way out of the input for a pointer.
  defp chat_rename_form(assigns) do
    ~H"""
    <form
      id={"#{@scope}rename-form-#{@chat.id}"}
      phx-submit="rename_chat"
      class="flex min-w-0 flex-1 items-center gap-1 px-1 py-1"
    >
      <input
        type="text"
        name="title"
        id={"#{@scope}chat-rename-#{@chat.id}"}
        value={@chat.title}
        phx-hook=".ChatRename"
        maxlength="60"
        autocomplete="off"
        aria-label="Chat name"
        class="min-w-0 flex-1 rounded-md border border-primary bg-base-100 px-2 py-1 text-sm focus:outline-none"
      />
      <button
        type="button"
        id={"#{@scope}cancel-rename-#{@chat.id}"}
        phx-click="cancel_rename"
        aria-label="Cancel renaming"
        title="Cancel renaming"
        class="shrink-0 rounded-lg px-1.5 py-1 text-base-content/40 transition hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </form>
    """
  end

  attr :chat, :map, required: true
  attr :scope, :string, default: ""

  # UI-64, UI-103: the menu a chat's row opens. It is in the row's markup from
  # the first render and it is the client's, not the server's: LiveView draws it
  # once and never patches it again (`phx-update="ignore"`), and whether it is
  # open is the DOM's own state (the element's own `style`), so opening it costs
  # no round trip and the pane a row sits in has no event of its own that opens
  # one or shuts one. It is shut in its own markup, so a closed menu is
  # invisible whatever stylesheet the page has (the argument IMG-7 makes for the
  # image viewer's overlay), and it is positioned against the viewport — above
  # the list, not clipped by its scroll box — and kept inside the screen's own
  # width (UI-78).
  defp chat_row_menu(assigns) do
    ~H"""
    <div
      id={"#{@scope}chat-row-menu-#{@chat.id}"}
      data-row-menu
      phx-update="ignore"
      aria-hidden="true"
      style="display: none"
      class="fixed z-50 min-w-44 overflow-hidden rounded-xl border border-base-300 bg-base-100 p-1 shadow-xl shadow-base-content/5"
    >
      <button
        type="button"
        id={"#{@scope}rename-chat-#{@chat.id}"}
        phx-click="start_rename"
        phx-value-id={@chat.id}
        class="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-base-content/80 transition hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-pencil" class="size-4 shrink-0 opacity-70" /> Rename
      </button>
      <%!-- UI-64: the list's one way to delete a chat, confirmed with
      `data-confirm` naming the chat and labelled "Delete chat". --%>
      <button
        type="button"
        id={"#{@scope}delete-chat-#{@chat.id}"}
        phx-click="delete_chat"
        phx-value-id={@chat.id}
        data-confirm={"Delete the chat #{@chat.title}? This can't be undone."}
        aria-label="Delete chat"
        title="Delete chat"
        class="flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm text-error/80 transition hover:bg-error/10 hover:text-error"
      >
        <.icon name="hero-trash" class="size-4 shrink-0" />
        <span class="truncate">Delete</span>
      </button>
    </div>
    """
  end

  # UI-106: the chats the filters leave listed — a chat is hidden when its
  # status (UI-59) is the one a group's toggle hides and that toggle is off
  # (UI-105); every other status is never hidden, so a chat waiting for the
  # user (UI-47, UI-58, UI-76) and one a restart cut short (UI-72) stay listed
  # whatever the filters say.
  defp shown_chats(chats, statuses, filters) do
    Enum.filter(chats, fn chat ->
      status = ChatStatus.for_chat(chat, statuses)

      Enum.all?(filters, fn {group, shown} ->
        shown or status != Map.fetch!(@filter_status, group)
      end)
    end)
  end

  # UI-105, UI-106: a square filter button — tinted, as the app's other pressed
  # toggles are (UI-60), for a group the list shows, and dimmed for one it hides.
  # The tint is the theme's own: the light theme's primary, off-white in the dark
  # theme (its primary is the blue UI-105's icons would otherwise wear).
  defp filter_button_class(true),
    do:
      "grid size-7 place-items-center rounded-none border border-primary/40 bg-primary/10 text-primary transition dark:border-base-content/40 dark:bg-base-content/10 dark:text-base-content"

  defp filter_button_class(false),
    do:
      "grid size-7 place-items-center rounded-none border border-base-300 text-base-content/40 transition hover:border-base-content/25 hover:text-base-content"

  # UI-45: task chats nested under their parent; orphans stay at the top level.
  defp chat_tree(chats) do
    ids = MapSet.new(chats, & &1.id)
    {nested, top} = Enum.split_with(chats, &(Map.get(&1, :parent_id) in ids))
    by_parent = nested |> Enum.reverse() |> Enum.group_by(& &1.parent_id)
    Enum.map(top, &{&1, Map.get(by_parent, &1.id, [])})
  end
end
