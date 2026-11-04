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

# The reload pipeline is part of the deploy, not of the Mix environment (HOT-7),
# so every environment carries it; it sits here rather than in config/runtime.exs
# because the endpoint reads `code_reloader` at compile time. Only the suite
# turns it off (config/test.exs): a test run is not an operating mode.
config :elia, EliaWeb.Endpoint, code_reloader: true

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

# Compaction (COMPACT-6, COMPACT-8, COMPACT-9, COMPACT-11, COMPACT-12, COMPACT-28):
# a turn compacts first when the estimated request exceeds `min(budget, fraction *
# window)`, and reduces it to `target_fraction` of that, keeping the last
# `working_set` turns — or only the recent ones that fit in `working_set_tokens`,
# whichever is smaller — verbatim and cutting a user message longer than
# `user_cap` tokens with a marker. `auto` is whether that happens on its own; a
# chat can override all of it (Elia.Agent.set_compaction/2).
config :elia, Elia.LLM.Compaction,
  budget: 150_000,
  fraction: 0.8,
  target_fraction: 0.5,
  working_set: 6,
  working_set_tokens: 40_000,
  user_cap: 8_000,
  auto: true

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
    Elia.Skills.Titles,
    Elia.Skills.UserInput,
    Elia.Skills.SelfModification
  ]

# Command isolation (ISOL): tool calls run inside a bubblewrap jail, which holds
# the workspace and the toolchain and nothing else. `false` turns the jail off
# for every chat on this host; a chat's own setting can turn it off for one chat
# (ISOL-20).
config :elia, Elia.Shell, jail: true

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
