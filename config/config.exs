# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elia,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :elia, EliaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EliaWeb.ErrorHTML, json: EliaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Elia.PubSub,
  live_view: [signing_salt: "Sj47a7MI"]

# The live tree (DEPLOY-2): where the server runs, where the code reloader
# reloads, and where Elia's data lives (`.elia`). A chat in Elia's own project
# works in its own git worktree (`.elia/worktrees/<chat id>`, branch
# `chat/<chat id>`) instead, and a deploy merges that branch into `live`; the
# live tree must be on the branch `live` for that. Defaults to Elia's root
# (`config :elia, :workspace`, else the working directory = where the server was
# started from). See `Elia.Workspace.runtime_root/0` and `Elia.Deploy`.
#
# config :elia, :runtime_root, "/path/to/live/tree"

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  elia: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  elia: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# AI harness. Swap the provider module to use another LLM backend.
config :elia, Elia.LLM, provider: Elia.LLM.Anthropic

config :elia, Elia.LLM.Anthropic,
  model: "claude-opus-5-5",
  effort: "high",
  thinking_display: "summarized"

config :elia, Elia.Skills,
  builtin: [
    Elia.Skills.Shell,
    Elia.Skills.Files,
    Elia.Skills.Harness,
    Elia.Skills.Tasks,
    Elia.Skills.SelfModification
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
