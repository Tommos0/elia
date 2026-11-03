import Config

# We don't run a server during test, except for the real-browser tests, which
# ask for it with ELIA_BROWSER_TESTS=1 (BROWSER-3). Keeping a plain `mix test`
# serverless means runs that overlap on one machine (a chat and its sub-tasks)
# can't collide on the port, which ELIA_TEST_PORT can move.
config :elia, EliaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("ELIA_TEST_PORT", "4002"))],
  secret_key_base: "Pac3kJrObCElMVU07qb/sTiYCV1OVBBo1qJZEAi5cY++bmi3bc81cR9TV4voBIBV",
  # A test run is not an operating mode: no code reloader and no live reload
  # (HOT-7). The endpoint reads `code_reloader` at compile time, so tests that
  # fake a running server set it at runtime (Elia.Deploy.hot_reload_available?/0).
  code_reloader: false,
  server: System.get_env("ELIA_BROWSER_TESTS") == "1"

# PhoenixTest drives that endpoint from a real browser (BROWSER-3). The
# Playwright CLI sits in assets/node_modules (BROWSER-2); errors the page logs
# are recorded and fail the test that caused them (BROWSER-8). A UI preview
# writes its pictures into its own dir, where the chat that asked for them looks
# for them (PREVIEW-4, PREVIEW-7).
config :phoenix_test,
  otp_app: :elia

config :phoenix_test, :playwright,
  js_logger: EliaWeb.BrowserJsLogger,
  screenshot_dir: System.get_env("ELIA_PREVIEW_DIR", "tmp/screenshots"),
  trace_dir: "tmp/traces"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests script model turns with a fake provider.
config :elia, Elia.LLM, provider: Elia.FakeLLM

# Settings (API keys, model selection) go to a scratch database.
config :elia, Elia.Settings,
  path: Path.join([System.tmp_dir!(), "elia-test-settings", "settings.dets"])

# Tests run against a scratch workspace (a fresh git repo, see test_helper.exs).
config :elia, :workspace, Path.join(System.tmp_dir!(), "elia-test-workspace")

# The suite runs commands unjailed so it needs no bubblewrap; the isolation
# tests turn the jail on per call and skip where bubblewrap is missing
# (ISOL-12).
config :elia, Elia.Shell, jail: false
