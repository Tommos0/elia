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

# The user-wide Playwright CLI that the real-browser tests and a UI preview
# drive (BROWSER-2). It belongs to the user, not to a workspace: one install
# serves Elia and any other project on the machine. The browser driver is
# pointed at the directory that holds `node_modules/playwright`, and the jail
# binds the same directory read-only, so a jailed browser run reaches the copy
# the driver was told to use (ISOL-26).
config :elia,
  playwright_dir: System.get_env("ELIA_PLAYWRIGHT_DIR", Path.expand("~/.local/lib"))

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

# Turn retries (RETRY): a model call that failed transiently — a stream cut off
# by its idle timeout, a connection dropped mid-answer, an overloaded provider —
# is asked again after each of these waits, so the turn carries on by itself.
# The list's length is how many retries a step gets; [] turns retrying off and a
# transient failure then ends the turn (RETRY-4).
config :elia, :step_retry, delays_ms: [15_000, 30_000, 60_000]

# Compaction (COMPACT-6, COMPACT-8, COMPACT-9, COMPACT-11, COMPACT-12, COMPACT-28,
# COMPACT-36): a turn compacts first when the estimated request exceeds
# `min(budget, fraction * window)`, and reduces it to `target_fraction` of that,
# keeping the last `working_set` turns — or only the recent ones that fit in
# `working_set_tokens`, whichever is smaller — verbatim, cutting a user message
# longer than `user_cap` tokens with a marker and leaving an item smaller than
# `elide_floor` estimated tokens alone while a bigger one can reach the target.
# `auto` is whether that happens on its own; a chat can override all of it
# (Elia.Agent.set_compaction/2).
config :elia, Elia.LLM.Compaction,
  budget: 100_000,
  fraction: 0.6,
  target_fraction: 0.5,
  working_set: 6,
  working_set_tokens: 25_000,
  user_cap: 8_000,
  elide_floor: 1_000,
  auto: true

config :elia, Elia.LLM.Anthropic,
  model: "claude-opus-5-5",
  effort: "medium",
  thinking_display: "summarized"

# OpenRouter (LLM-37, LLM-38): the effort and the prompt-cache breakpoint are
# sent only to an Anthropic-family model, the family that documents them, so a
# model of any other family is asked exactly as it was before.
config :elia, Elia.LLM.OpenRouter,
  effort: "medium",
  cache_control: true

# The local llama.cpp server (LOCAL): a third provider, with no key and no
# network. `base_url` says where the server is, is overridden by `LLAMA_CPP_BASE_URL`
# and by a URL saved in Settings (LOCAL-3); `model` is used when a request names
# none. Elia can start the server itself from a `.gguf` (LOCAL-11) — every field
# of Elia.LLM.LlamaServer can also be saved in Settings, which wins (LOCAL-14).
config :elia, Elia.LLM.LlamaCpp,
  base_url: nil,
  model: nil,
  max_tokens: nil,
  api_key: nil

config :elia, Elia.LLM.LlamaServer,
  binary: nil,
  models_dir: nil,
  model: nil,
  host: "127.0.0.1",
  port: 8080,
  context: nil,
  threads: nil,
  jinja: true,
  api_key: nil,
  extra_args: [],
  log_lines: 200,
  startup_timeout: 60_000

config :elia, Elia.Skills,
  builtin: [
    Elia.Skills.Shell,
    Elia.Skills.Files,
    Elia.Skills.Harness,
    Elia.Skills.Tasks,
    Elia.Skills.Terminal,
    Elia.Skills.Titles,
    Elia.Skills.Done,
    Elia.Skills.Chats,
    Elia.Skills.UserInput,
    Elia.Skills.SelfModification
  ]

# The chat's own terminal (TERM): one session per chat, a tmux process tree in
# the chat's workspace, jailed like a command (TERM-7) and niced like one
# (TERM-8), streamed to xterm.js on the browser's side (TERM-12). `tmux` is
# resolved from PATH when unset, and where there is none the feature says so
# (TERM-29). `scrollback_lines` is what a joining client is sent and what
# `terminal_read` returns (TERM-14, TERM-26); `max_sessions` bounds how many
# ptys one server hands out.
config :elia, Elia.Terminal,
  tmux: nil,
  default_command: nil,
  scrollback_lines: 2_000,
  max_sessions: 8,
  max_pending: 1_000

# Command isolation (ISOL): tool calls run inside a bubblewrap jail, which holds
# the workspace and the toolchain and nothing else. `false` turns the jail off
# for every chat on this host; a chat's own setting can turn it off for one chat
# (ISOL-20).
config :elia, Elia.Shell, jail: true

# Process priority (PRIO): every process Elia spawns for a tool call or a
# harness step — the shell tool, a test suite, a compile — runs below the
# server's own CPU priority (`nice`) and I/O class (`ionice`), so it takes the
# machine from the UI and the agent loops only as far as it must (PRIO-1,
# PRIO-4). Only the children are lowered, so no privileges are needed; `nice: 0`
# or `nil` and `ionice: nil` turn either half off (PRIO-6).
config :elia, Elia.Priority, nice: 10, ionice: 6

# How long a tool call may run. A `shell` call's default is for the common
# command, not the longest one: a build, a cold compile or a whole test suite
# asks for more with the call's `timeout_seconds`, up to `max_timeout`, and a
# call that asks for more than that runs with the maximum and is told so
# (SHELL-10). A test run has its own timeout, and hands `mix test` a per-test
# one, from the harness's settings (VERIFY-8, VERIFY-9).
config :elia, Elia.Skills.Shell,
  default_timeout: 300,
  max_timeout: 1_800,
  max_output: 30_000

config :elia, Elia.Harness,
  timeout: 600,
  max_timeout: 1_800,
  test_timeout: 60_000,
  max_test_timeout: 600_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
