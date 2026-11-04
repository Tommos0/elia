defmodule EliaWeb.BrowserCase do
  @moduledoc """
  Case for tests that drive a real headless Chromium (BROWSER-5, BROWSER-6,
  BROWSER-7):

      use EliaWeb.BrowserCase

      test "…", %{conn: conn} do
        conn |> visit("/") |> assert_has("#chat-form")
      end

  The browser talks to the test env server over HTTP, so a browser run needs
  the server (BROWSER-3), the Playwright CLI in `assets/node_modules`
  (BROWSER-2) and built assets (BROWSER-6):

      mix assets.build
      ELIA_BROWSER_TESTS=1 mix test --only browser

  They are excluded from a plain `mix test`, and they run one at a time, since
  the workspace, the server and the browser are shared (BROWSER-7).
  """

  use ExUnit.CaseTemplate

  alias EliaWeb.BrowserJsLogger

  # What the browser loads. `esbuild` and `tailwind` run only in dev, so a test
  # run has to build these first (BROWSER-6).
  @assets ["priv/static/assets/js/app.js", "priv/static/assets/css/app.css"]

  using _opts do
    quote do
      # Never `async`: the workspace, the server and the browser are shared.
      # Not `:browser`, which the library reads as its browser option.
      use PhoenixTest.Playwright.Case, async: false

      @moduletag :real_browser
    end
  end

  setup_all do
    check_assets!()
    start_supervised!(BrowserJsLogger)
    :ok
  end

  setup do
    BrowserJsLogger.clear()

    on_exit(fn ->
      case BrowserJsLogger.take() do
        [] ->
          :ok

        errors ->
          ExUnit.Assertions.flunk(
            "the page logged JavaScript errors:\n\n" <> Enum.join(errors, "\n\n")
          )
      end
    end)

    :ok
  end

  defp check_assets! do
    # BROWSER-10: one message for a missing Playwright CLI, shared with
    # `test/test_helper.exs`, which runs it before the driver starts.
    EliaWeb.BrowserAssets.check!()
    check_built!()
  end

  defp check_built! do
    case Enum.reject(@assets, &File.exists?/1) do
      [] ->
        :ok

      missing ->
        raise """
        Real-browser tests need built assets, and #{Enum.join(missing, ", ")} is missing.

        Run `mix assets.build` first (BROWSER-6).
        """
    end
  end
end
