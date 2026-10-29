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

  scope "/", EliaWeb do
    pipe_through :browser

    live_session :default, on_mount: EliaWeb.ClientTracker do
      live "/", ChatLive, :new
      live "/c/:id", ChatLive, :show
      live "/sessions", SessionsLive
      live "/system", SystemLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", EliaWeb do
  #   pipe_through :api
  # end
end
