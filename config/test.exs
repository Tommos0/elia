import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :elia, EliaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Pac3kJrObCElMVU07qb/sTiYCV1OVBBo1qJZEAi5cY++bmi3bc81cR9TV4voBIBV",
  server: false

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

# Tests run against a scratch workspace (a fresh git repo, see test_helper.exs).
config :elia, :workspace, Path.join(System.tmp_dir!(), "elia-test-workspace")
