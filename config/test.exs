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

# PhoenixTest drives that endpoint from a real browser (BROWSER-3). Errors the
# page logs are recorded and fail the test that caused them (BROWSER-8). A UI
# preview writes its pictures into its own dir, where the chat that asked for
# them looks for them (PREVIEW-4, PREVIEW-7). The driver's `assets_dir` — the
# user-wide Playwright CLI (BROWSER-2) — is set in `test/test_helper.exs`, just
# before the driver starts.
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

# RESUME-6: a test run's own boot resumes nothing, so a test that covers a
# resume turns it on for itself (specs/auto-resume.md).
config :elia, Elia.Agent.Resumer, enabled: false

# A test run's own state, under a run directory that belongs to that run alone
# (SUITE-1, specs/test-suite.md): the settings database here, the scratch
# workspace below, and — in `test/test_helper.exs` — the temp directory a test
# names its own paths in. `bin/test` makes its run directory with `mktemp -d` and
# names it in `ELIA_TEST_RUN` for each partition; a run that is not `bin/test`,
# such as a plain `mix test` or the deploy's own suite run, derives one here from
# its own process, so two runs on one machine differ whatever they are.
#
# `Elia.TestRun` in `test/support/` reads the value back, and prunes the run
# directories a killed run left behind by matching this name (SUITE-13), so the
# places that name a run directory have to agree on it.
run =
  case System.get_env("ELIA_TEST_RUN") do
    nil -> :derived
    value -> if String.trim(value) == "", do: :derived, else: String.trim(value)
  end

run =
  case run do
    :derived ->
      # Named for this node and the moment it started: a command runs in its own
      # pid namespace (ISOL-9), so two runs on one machine can see the same pid.
      Path.join(
        System.tmp_dir!(),
        "elia-test-run-#{System.pid()}-#{System.system_time(:nanosecond)}"
      )

    run ->
      run
  end

config :elia, :test_run, run

# The run names its directory in the environment too, so a node it hands its
# environment to resolves the same one (SUITE-12). A run that starts a suite of
# its own names that one explicitly instead (`Elia.Harness`), since `Elia.Shell`
# hands a command its variables *on top of* the environment it inherited.
System.put_env("ELIA_TEST_RUN", run)

# Settings (API keys, model selection) go to a scratch database, in a directory
# of its own below the run's: `Elia.Settings` keeps the directory it creates
# private (CONF-2), so this must not be one that already exists.
config :elia, Elia.Settings,
  path:
    System.get_env("ELIA_TEST_SETTINGS") ||
      Path.join([run, "settings", "settings.dets"])

# Tests run against a scratch workspace (a fresh git repo, see test_helper.exs).
config :elia,
       :workspace,
       System.get_env("ELIA_TEST_WORKSPACE") || Path.join(run, "workspace")

# The suite runs commands unjailed so it needs no bubblewrap; the isolation
# tests turn the jail on per call and skip where bubblewrap is missing
# (ISOL-12).
config :elia, Elia.Shell, jail: false
