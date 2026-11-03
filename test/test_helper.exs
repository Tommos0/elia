# Scratch workspace for file and session tests (see config/test.exs).
root = Application.fetch_env!(:elia, :workspace)
File.rm_rf!(root)
File.mkdir_p!(root)
{_, 0} = System.cmd("git", ["init", "--quiet"], cd: root)

# Real-browser tests are excluded unless a run asks for the tag, so `mix test`,
# the `run_tests` tool and `mix precommit` never start a browser or need Node
# (BROWSER-5). Run them with
# `ELIA_BROWSER_TESTS=1 mix test --only real_browser`.
ExUnit.start(exclude: [:real_browser])

if System.get_env("ELIA_BROWSER_TESTS") == "1" do
  # The Playwright driver, and the URL of the test server it drives
  # (BROWSER-3, BROWSER-4).
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, EliaWeb.Endpoint.url())
end
