defmodule EliaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use EliaWeb, :html

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

  # UI-32: on the chat page the header's Chats control is the chat list's
  # drawer toggle (`#chats-toggle`, UI-36) instead of navigating, so it shows
  # the list rather than leaving the open chat. On every other page — the
  # dashboard included (DASH-2) — it is the link (`#chats-link`) to `/chats`,
  # the chat list's entry point, which resumes the chat the user left off in
  # (UI-77). The logo at the top left goes home, `/`, the dashboard (DASH-1).
  attr :chats_drawer, :boolean,
    default: false,
    doc: "render the Chats control as the chat list's drawer toggle (UI-32, UI-36)"

  attr :chats_open, :boolean, default: false, doc: "whether that drawer is open (UI-36)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col bg-base-100">
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
          <%!-- UI-32, UI-36: the drawer's toggle, which only exists where the
          drawer does (`lg:hidden`); from `lg` up the list is always visible. --%>
          <button
            :if={@chats_drawer}
            type="button"
            id="chats-toggle"
            phx-click="toggle_chats"
            aria-expanded={to_string(@chats_open)}
            aria-controls="sidebar"
            title="Chats"
            class="flex items-center gap-1.5 rounded-lg p-2 text-sm transition hover:bg-base-200 sm:px-3 sm:py-1.5 lg:hidden"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" />
            <span class="sr-only sm:not-sr-only">Chats</span>
          </button>
          <.nav_link
            :if={!@chats_drawer}
            to={~p"/chats"}
            id="chats-link"
            icon="hero-chat-bubble-left-right"
            label="Chats"
          />
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

      <main class="min-h-0 flex-1">
        {render_slot(@inner_block)}
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
