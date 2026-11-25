defmodule EliaWeb.ChatRowMenu do
  @moduledoc """
  A chat's own row and the menu it opens (UI-103, UI-104, ACTIVE-8, ACTIVE-9).

  Two places draw a chat's row — the chat list (`EliaWeb.ChatList`, its sidebar
  and the drawer every other page opens) and the header's active chats
  (`EliaWeb.ActiveChats`) — and both draw the menu and the box a name is typed
  in from here, under their own id scope, so the two copies of a chat's row
  cannot drift apart and never collide. It has to be one module's markup: a
  colocated hook's name is resolved against the module its markup is compiled
  in, so a `phx-hook` in another module's markup would name a hook that is not
  there.
  """

  use EliaWeb, :html

  # UI-103, UI-104: the events a row's menu and its box send. The chat list's
  # are the default, and the header's rows name their own (ACTIVE-10), so a
  # rename started in one is not taken for a rename started in the other.
  @events %{
    start: "start_rename",
    submit: "rename_chat",
    cancel: "cancel_rename",
    delete: "delete_chat"
  }

  attr :id, :string, required: true, doc: "the row's own id (UI-103)"

  attr :chat, :map,
    required: true,
    doc: "the chat the row is about, with the `:id` and `:title` the menu and the box read"

  attr :scope, :string, default: "", doc: "the id prefix this copy of the row draws under (UI-92)"

  attr :class, :string, default: "flex", doc: "the row's own classes"

  attr :renaming, :boolean,
    default: false,
    doc: "whether this row is the one showing a box to type a name in (UI-104)"

  attr :events, :map,
    default: @events,
    doc: "the events the row's menu and its box send (UI-103, UI-104, ACTIVE-10)"

  slot :inner_block, required: true, doc: "the row's link, drawn by the caller (UI-4)"

  @doc """
  UI-103, UI-104, ACTIVE-8 to ACTIVE-10: a chat's row — the link the caller
  draws in the slot, the box a name is typed in while the row is being renamed,
  and the menu the row opens, with the gesture that opens it.
  """
  def row(assigns) do
    ~H"""
    <div id={@id} phx-hook=".ChatRowMenu" data-row-chat={@chat.id} class={@class}>
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
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatRename">
        export default {
          mounted() {
            this.el.focus()
            this.el.select()

            // ACTIVE-10: the event a cancel sends is the caller's — the chat
            // list's own, or the header's — and the box carries it.
            const cancel = this.el.dataset.cancelEvent || "cancel_rename"

            this.onBlur = () => this.pushEvent(cancel, {})
            this.onKey = event => {
              if (event.key !== "Escape") return
              event.stopPropagation()
              this.pushEvent(cancel, {})
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
      <.rename_form :if={@renaming} chat={@chat} scope={@scope} events={@events} />
      <%= if !@renaming do %>
        {render_slot(@inner_block)}
      <% end %>
      <.menu chat={@chat} scope={@scope} events={@events} />
    </div>
    """
  end

  attr :chat, :map, required: true
  attr :scope, :string, default: ""
  attr :events, :map, default: @events

  # UI-64, UI-103: the menu a chat's row opens. It is in the row's markup from
  # the first render and it is the client's, not the server's: LiveView draws it
  # once and never patches it again (`phx-update="ignore"`), and whether it is
  # open is the DOM's own state (the element's own `style`), so opening it costs
  # no round trip and the pane a row sits in has no event of its own that opens
  # one or shuts one. It is shut in its own markup, so a closed menu is
  # invisible whatever stylesheet the page has (the argument IMG-7 makes for the
  # image viewer's overlay), and it is positioned against the viewport — above
  # the list, not clipped by its scroll box — and kept inside the screen's own
  # width (UI-78). The events it sends are the caller's (ACTIVE-10).
  defp menu(assigns) do
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
        phx-click={@events.start}
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
        phx-click={@events.delete}
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

  attr :chat, :map, required: true
  attr :scope, :string, default: ""
  attr :events, :map, default: @events

  # UI-104: naming a chat in its row. The input holds the chat's own title (the
  # row's `title` attribute stays the description, UI-33, and is not what the
  # input holds) with all of it selected and focused, so it can be typed over at
  # once; Enter saves it — the form's own `phx-submit` — and Escape, a press
  # outside it and losing focus cancel it. `.ChatRename` is what focuses and
  # selects, since an attribute can say neither, and `data-cancel-event` is the
  # event a cancel sends, which is the caller's (ACTIVE-10). Cancel is a control
  # of its own, the accessible way out of the input for a pointer.
  defp rename_form(assigns) do
    ~H"""
    <form
      id={"#{@scope}rename-form-#{@chat.id}"}
      phx-submit={@events.submit}
      class="flex min-w-0 flex-1 items-center gap-1 px-1 py-1"
    >
      <input
        type="text"
        name="title"
        id={"#{@scope}chat-rename-#{@chat.id}"}
        value={@chat.title}
        phx-hook=".ChatRename"
        data-cancel-event={@events.cancel}
        maxlength="60"
        autocomplete="off"
        aria-label="Chat name"
        class="min-w-0 flex-1 rounded-md border border-primary bg-base-100 px-2 py-1 text-sm focus:outline-none"
      />
      <button
        type="button"
        id={"#{@scope}cancel-rename-#{@chat.id}"}
        phx-click={@events.cancel}
        aria-label="Cancel renaming"
        title="Cancel renaming"
        class="shrink-0 rounded-lg px-1.5 py-1 text-base-content/40 transition hover:bg-base-200 hover:text-base-content"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </form>
    """
  end
end
