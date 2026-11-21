defmodule EliaWeb.Router do
  use EliaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EliaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # PWA-9: a document loaded again is revalidated with the server rather than
    # answered from the browser's cache, which is what an installed app's window
    # otherwise holds on to. Not `no-store`: a page restored from the
    # back/forward cache is how a backgrounded tab recovers (CONN-1).
    plug :no_cache_document
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # PWA-9: every HTML document the browser pipeline serves says so.
  defp no_cache_document(conn, _opts) do
    put_resp_header(conn, "cache-control", "no-cache")
  end

  # A UI preview's images (PREVIEW-7): directory-independent, so they are
  # served without the session, layout or static pipeline — straight from the
  # `tmp/preview/` the preview wrote them to.
  scope "/preview", EliaWeb do
    get "/:chat_id/:file", PreviewController, :show
  end

  # The bytes a preview of the Files page is made of (EXPL-24): outside the
  # browser pipeline like the images above, since it serves a file rather than
  # a document — a PDF is framed by the page, which the secure browser headers
  # would refuse — and `EliaWeb.FilesRawController` sets its own cache,
  # content-type and policy headers.
  scope "/files", EliaWeb do
    get "/raw", FilesRawController, :show
  end

  scope "/", EliaWeb do
    pipe_through :browser

    # BUNDLE-3: the bundle the server serves now, for a page that is already
    # open and asks whether the one it loaded is still the one served
    # (specs/bundle-refresh.md). Through the browser pipeline, so it is never
    # answered from a cache (PWA-9).
    get "/asset-version", AssetVersionController, :show

    # UI-32, UI-36, UI-91: `EliaWeb.ChatList` gives every page the chat list's
    # state and its events, which is the drawer the header's "Chats" button
    # opens on the pages that keep no list of their own; ACTIVE-1: and
    # `EliaWeb.ActiveChats` gives every page the active chats control's state
    # and its events, which is the count and its menu in the header.
    live_session :default,
      on_mount: [EliaWeb.ClientTracker, EliaWeb.ChatList, EliaWeb.ActiveChats] do
      # DASH-1: `/` is the dashboard, the app's start URL (PWA-1) and the
      # header logo's target; it starts no chat.
      live "/", DashboardLive, :index
      # UI-77: the chat list's entry point, where deleting the chat a page shows
      # lands (UI-65, UI-93): it resumes the most recent chat, or starts one.
      live "/chats", ChatLive, :new
      live "/c/:id", ChatLive, :show
      # CSET-1: this chat's own settings — model, auto-approval, jail, limits
      # and context — on their own page instead of in the composer.
      live "/c/:id/settings", ChatSettingsLive
      # TERM-19: this chat's terminal, where a shell or a terminal app runs and
      # the user watches it.
      live "/c/:id/terminal", TerminalLive
      live "/p/:project_id/new", ChatLive, :new
      live "/projects", ProjectsLive
      live "/sessions", SessionsLive
      live "/system", SystemLive
      live "/logs", LogsLive
      live "/files", FilesLive
      live "/settings", SettingsLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", EliaWeb do
  #   pipe_through :api
  # end
end
