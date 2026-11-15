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

      <Layouts.app flash={@flash}>
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
  # (DASH-1); the other pages' links (PROJ-25) are below the button.
  attr :chats_sidebar, :boolean,
    default: false,
    doc: "the page draws the chat list itself, so no drawer here (UI-36, UI-91)"

  # UI-91, UI-92: the chat list's state (`EliaWeb.ChatList`), which is what the
  # drawer draws. Every page in the live session has it assigned.
  attr :chats, :map, default: nil, doc: "the chat list's state (UI-91, UI-92)"

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
        <.link
          navigate={~p"/"}
          title="Home"
          class="flex items-center gap-2 font-semibold tracking-tight"
        >
          <span class="grid size-7 place-items-center rounded-lg bg-primary text-sm text-primary-content">
            E
          </span>
          Elia
        </.link>
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
          <.nav_link
            to={~p"/projects"}
            id="projects-link"
            icon="hero-rectangle-stack"
            label="Projects"
          />
          <.nav_link to={~p"/files"} id="files-link" icon="hero-folder" label="Files" />
          <.nav_link to={~p"/sessions"} id="sessions-link" icon="hero-signal" label="Sessions" />
          <.nav_link to={~p"/system"} id="system-link" icon="hero-chart-bar" label="System" />
          <.nav_link to={~p"/settings"} id="settings-link" icon="hero-cog-6-tooth" label="Settings" />
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
end
