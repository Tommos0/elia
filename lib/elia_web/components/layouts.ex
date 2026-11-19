defmodule EliaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EliaWeb, :html

  # PWA-8: the shell's asset links carry a version of the built file.
  alias EliaWeb.AssetVersion

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash} notifications={@notifications}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  # UI-32, UI-91: the header's "Chats" button opens the chat list — the drawer
  # this layout renders — rather than leaving the page. A page that keeps the
  # list itself, as its own sidebar (UI-4, UI-35), says so with `chats_sidebar`:
  # then the button is that list's small-screen shape and the layout renders no
  # drawer (UI-36). The logo at the top left goes home, `/`, the dashboard
  # (DASH-1), and the open project stands beside the logo as the switcher that
  # changes it (PROJ-29); the other pages' links (UI-32) are below the button.
  attr :chats_sidebar, :boolean,
    default: false,
    doc: "the page draws the chat list itself, so no drawer here (UI-36, UI-91)"

  # UI-91, UI-92: the chat list's state (`EliaWeb.ChatList`), which is what the
  # drawer draws. Every page in the live session has it assigned.
  attr :chats, :map, default: nil, doc: "the chat list's state (UI-91, UI-92)"

  # NOTIF-5: the bell's state (`EliaWeb.Notifications`). Every page in the live
  # session has it assigned, and the header draws the bell from it. Required, so
  # a page that does not hand it over fails to compile rather than losing the
  # bell.
  attr :notifications, :map, required: true, doc: "the notification bell's state (NOTIF-5)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- UI-78, HOT-8: the shell's height is the markup's own, not a class's. A
    deploy hot-reloads new markup into a page that keeps the stylesheet it
    loaded — and its built assets are not rebuilt by the deploy at all — so a
    class the stylesheet has never seen would leave the page with no height rule
    for the shell: the page would be as tall as its content, which in a chat
    means a message list the composer sits at the end of, off the screen. The
    same reason the image viewer's closed state is its own markup (IMG-7).
    `100vh` first, for an engine that doesn't know `svh`; `100svh` — the visible
    area with a mobile browser's toolbars shown — where it does, so a phone's
    URL bar cannot overlap the bottom of the page. The keyboard is PWA-7. --%>
    <div id="app-shell" class="flex flex-col bg-base-100" style="height: 100vh; height: 100svh">
      <header class="flex items-center justify-between border-b border-base-300 px-4 py-3 sm:px-6">
        <div class="flex min-w-0 items-center gap-2">
          <%!-- DASH-1: the logo goes home — `/`, the dashboard. The open
          project's name stands beside it, where the app's own name used to, as
          the switcher that changes it (PROJ-29). --%>
          <.link navigate={~p"/"} title="Home" class="flex shrink-0 items-center">
            <span class="grid size-7 place-items-center rounded-lg bg-primary text-sm text-primary-content">
              E
            </span>
          </.link>
          <.project_switcher
            :if={@chats && @chats.open_project}
            projects={@chats.projects}
            open={@chats.open_project}
            menu={@chats.projects_open}
          />
        </div>
        <div class="flex min-w-0 items-center gap-0.5 sm:gap-2">
          <%!-- UI-32, UI-36, UI-91: the chat list's drawer toggle, on every
          page. Where the page keeps the list itself the drawer is that list's
          small-screen shape and the button goes with it (`lg:hidden`); on a
          page without a list of its own the drawer is the page's chat list, so
          the button is there at every width. --%>
          <button
            type="button"
            id="chats-toggle"
            phx-click="toggle_chats"
            aria-expanded={to_string(@chats && @chats.open)}
            aria-controls={if @chats_sidebar, do: "sidebar", else: "chats-drawer"}
            title="Chats"
            class={[
              "flex items-center gap-1.5 rounded-lg p-2 text-sm transition hover:bg-base-200 sm:px-3 sm:py-1.5",
              @chats_sidebar && "lg:hidden"
            ]}
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" />
            <span class="sr-only sm:not-sr-only">Chats</span>
          </button>
          <.nav_link to={~p"/files"} id="files-link" icon="hero-folder" label="Files" />
          <.nav_link to={~p"/sessions"} id="sessions-link" icon="hero-signal" label="Sessions" />
          <.nav_link to={~p"/system"} id="system-link" icon="hero-chart-bar" label="System" />
          <.nav_link to={~p"/settings"} id="settings-link" icon="hero-cog-6-tooth" label="Settings" />
          <%!-- NOTIF-5: the notification bell, at the right-hand end of the
          header, last so that it sits at the top right of every page. --%>
          <EliaWeb.Notifications.bell state={@notifications} />
        </div>
      </header>

      <%!-- UI-78: a flex column, so a page fills the rest of the shell by
      growing into it rather than by a percentage height, and so the element a
      page scrolls itself (the chat transcript) can shrink to nothing. UI-91:
      it is also where the drawer is anchored — below the header, over the page
      — so the header's own control stays reachable while it is open. --%>
      <main class="relative flex min-h-0 flex-1 flex-col">
        {render_slot(@inner_block)}
        <%!-- UI-36, UI-91: the chat list's drawer and its backdrop, on the pages
        that keep no chat list of their own. It starts closed; the header's
        button opens it, a backdrop or Escape closes it. FEED-1: a backdrop is
        not a control, so it does not press — shrinking it would show the page's
        edges through it. --%>
        <button
          :if={@chats && @chats.open && !@chats_sidebar}
          type="button"
          id="chats-backdrop"
          phx-click="toggle_chats"
          aria-label="Close chats"
          class="absolute inset-0 z-20 bg-black/40"
          data-press="none"
        ></button>
        <aside
          :if={@chats && !@chats_sidebar}
          id="chats-drawer"
          phx-window-keydown={@chats.open && "close_chats"}
          phx-key="Escape"
          class={[
            "absolute inset-y-0 left-0 z-30 flex w-72 max-w-[85vw] flex-col border-r border-base-300 bg-base-100 shadow-xl",
            !@chats.open && "hidden"
          ]}
        >
          <EliaWeb.ChatList.chat_list state={@chats} scope="drawer-" />
        </aside>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :projects, :list, required: true, doc: "every project, in `list/0` order (PROJ-4)"

  attr :open, :map, required: true, doc: "the open project (PROJ-28)"

  attr :menu, :boolean, default: false, doc: "whether the menu is open (PROJ-29)"

  # PROJ-29, PROJ-30, UI-94: the open project beside the logo — its name where
  # the header used to show the app's own — and the menu it opens: every project,
  # the open one marked `data-open="true"`, and, below them, the entry to the
  # projects page (PROJ-23), where a project is created and deleted. Choosing a
  # project opens it and its chat list (PROJ-8, PROJ-28, UI-77). The control is
  # drawn like the settings page's pickers: the trigger asks to close while the
  # menu is open (so a press on it is not also a press outside), and the menu
  # closes on Escape and on a press outside it. Its layer is the notification
  # menu's (NOTIF-6), above the chat list's drawer and its backdrop (UI-36,
  # UI-91): the menu drops from the header over the page, and the drawer — which
  # is a layer of that page, at the same height as the menu's old one — would
  # otherwise cover the projects the user is choosing from.
  defp project_switcher(assigns) do
    ~H"""
    <div class="relative flex min-w-0 items-center">
      <button
        type="button"
        id="project-switcher"
        phx-click={if @menu, do: "close_projects", else: "open_projects"}
        aria-haspopup="listbox"
        aria-expanded={to_string(@menu)}
        title={"Open project: #{@open.name}"}
        class="group flex min-w-0 items-center gap-1 rounded-lg px-1.5 py-1 font-semibold tracking-tight transition hover:bg-base-200"
      >
        <span class="truncate">{@open.name}</span>
        <.icon
          name="hero-chevron-up-down"
          class="size-3.5 shrink-0 opacity-60 transition group-hover:opacity-100"
        />
      </button>

      <div
        :if={@menu}
        id="project-menu"
        phx-click-away="close_projects"
        phx-window-keydown="close_projects"
        phx-key="Escape"
        class="absolute top-full left-0 z-40 mt-1 w-[min(18rem,calc(100vw-2rem))] overflow-hidden rounded-xl border border-base-300 bg-base-100 p-1 shadow-xl shadow-base-content/5 motion-safe:animate-[picker-in_120ms_ease-out]"
      >
        <.link
          :for={project <- @projects}
          navigate={~p"/chats?project=#{project.id}"}
          id={"project-option-#{project.id}"}
          data-open={to_string(project.id == @open.id)}
          class={[
            "flex w-full items-center gap-2 rounded-lg px-3 py-2 text-left text-sm transition hover:bg-base-200",
            project.id == @open.id && "font-medium"
          ]}
        >
          <.icon name="hero-rectangle-stack" class="size-4 shrink-0 opacity-60" />
          <span class="min-w-0 flex-1 truncate">{project.name}</span>
          <.icon :if={project.id == @open.id} name="hero-check" class="size-4 shrink-0" />
        </.link>
        <div class="my-1 border-t border-base-300"></div>
        <.link
          navigate={~p"/projects"}
          id="manage-projects-link"
          class="flex items-center gap-2 rounded-lg px-3 py-2 text-sm text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-cog-6-tooth" class="size-4 shrink-0" /> Manage projects
        </.link>
      </div>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  # Header button: icon only below `sm` (UI-37), icon and label from `sm` up.
  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      id={@id}
      title={@label}
      class="flex items-center gap-1.5 rounded-lg p-2 text-sm transition hover:bg-base-200 sm:px-3 sm:py-1.5"
    >
      <.icon name={@icon} class="size-4" />
      <span class="sr-only sm:not-sr-only">{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  The UI scale: a slider, a readout of the percentage in force and a reset
  (CONF-30), kept in the browser rather than on the server (CONF-32).

  The page head applies the stored scale before anything is painted (CONF-33),
  so applying it is not this control's job: it reads the scale in force off the
  root element, where the head script leaves it, and asks for a new one with
  the event that script listens for. The server knows nothing about the scale,
  so `phx-update="ignore"` keeps a patch out of the control's own DOM.
  """
  def ui_scale(assigns) do
    ~H"""
    <div
      id="ui-scale"
      phx-hook=".UiScale"
      phx-update="ignore"
      class="mt-4 flex flex-wrap items-center justify-between gap-4 rounded-xl border border-base-300 p-4"
    >
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline justify-between gap-3">
          <label for="ui-scale-range" class="text-sm font-medium">UI scale</label>
          <output
            id="ui-scale-value"
            for="ui-scale-range"
            class="font-mono text-sm text-base-content/60"
          >
            100%
          </output>
        </div>
        <input
          id="ui-scale-range"
          type="range"
          min="80"
          max="150"
          step="5"
          value="100"
          class="range range-sm mt-3 w-full"
        />
      </div>
      <button id="ui-scale-reset" type="button" class="btn btn-sm">
        <.icon name="hero-arrow-path" class="size-4" /> Reset
      </button>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".UiScale">
        export default {
          mounted() {
            const range = this.el.querySelector("#ui-scale-range")
            const readout = this.el.querySelector("#ui-scale-value")

            // CONF-34: the scale in force is the one the page head applied
            // (CONF-33), which is what the control shows.
            const show = () => {
              const scale = document.documentElement.dataset.uiScale || "100"
              range.value = scale
              readout.textContent = scale + "%"
            }

            // CONF-32: the head script owns storing and applying it, so this
            // only tells it, and nothing reaches the server.
            const apply = (scale) => {
              range.dataset.phxUiScale = scale
              range.dispatchEvent(new CustomEvent("phx:set-ui-scale", { bubbles: true }))
              show()
            }

            range.addEventListener("input", () => apply(range.value))
            this.el
              .querySelector("#ui-scale-reset")
              .addEventListener("click", () => apply("100"))

            show()
          }
        }
      </script>
    </div>
    """
  end
end
