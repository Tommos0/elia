defmodule EliaWeb.Router do
  use EliaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {EliaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # A UI preview's images (PREVIEW-7): directory-independent, so they are
  # served without the session, layout or static pipeline — straight from the
  # chat's own worktree.
  scope "/preview", EliaWeb do
    get "/:chat_id/:file", PreviewController, :show
  end

  scope "/", EliaWeb do
    pipe_through :browser

    live_session :default, on_mount: EliaWeb.ClientTracker do
      live "/", ChatLive, :new
      live "/c/:id", ChatLive, :show
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
