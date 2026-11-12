# Scratch workspace for file and session tests (see config/test.exs).
root = Application.fetch_env!(:elia, :workspace)
File.rm_rf!(root)
File.mkdir_p!(root)
{_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)

# BROWSER-2: the Playwright driver is pointed at the user-wide Playwright CLI —
# the same directory the jail binds read-only (ISOL-26). It is set here rather
# than in `config/test.exs` because a config file is evaluated before the
# application environment an earlier one set can be read back, and
# `Elia.Shell.playwright_dir/0` is the one place that names the directory.
Application.put_env(
  :phoenix_test,
  :playwright,
  Keyword.put(
    Application.get_env(:phoenix_test, :playwright, []),
    :assets_dir,
    EliaWeb.BrowserAssets.dir()
  )
)

# Real-browser tests are excluded unless a run asks for the tag, so `mix test`,
# the `run_tests` tool and `mix precommit` never start a browser or need Node
# (BROWSER-5). Run them with
# `ELIA_BROWSER_TESTS=1 mix test --only real_browser`.
#
# A UI preview (`bin/preview`) is a browser run too, and is excluded the same
# way (PREVIEW-6): `mix test --only preview`.
ExUnit.start(exclude: [:real_browser, :preview])

if System.get_env("ELIA_BROWSER_TESTS") == "1" do
  # BROWSER-10: the driver validates the user-wide Playwright CLI as it starts,
  # so a machine that never installed it gets the command that fixes that
  # before the error can read as a broken config.
  EliaWeb.BrowserAssets.check!()

  # The Playwright driver, and the URL of the test server it drives
  # (BROWSER-3, BROWSER-4).
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, EliaWeb.Endpoint.url())
end
