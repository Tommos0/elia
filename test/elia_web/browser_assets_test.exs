defmodule EliaWeb.BrowserAssetsTest do
  @moduledoc """
  The check a browser run does before it starts the Playwright driver
  (BROWSER-10): where the CLI is looked for, and the message that says what to
  install when it isn't there, instead of the driver's own `:assets_dir` error.
  """

  use ExUnit.Case, async: true

  alias EliaWeb.BrowserAssets

  setup do
    dir =
      Path.join(System.tmp_dir!(), "elia-browser-assets-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # BROWSER-2: the workspace's own assets hold the pinned Playwright CLI.
  test "looks for Playwright in the workspace's own assets", %{dir: dir} do
    assert BrowserAssets.assets_dir(dir) == Path.join(dir, "assets")
    refute BrowserAssets.installed?(BrowserAssets.assets_dir(dir))
  end

  # BROWSER-10: a fresh chat worktree has no assets/node_modules, and the
  # message names the install there rather than the driver's config error.
  test "names npm install in the workspace's assets when Playwright is missing", %{dir: dir} do
    assets = BrowserAssets.assets_dir(dir)

    error = assert_raise(RuntimeError, fn -> BrowserAssets.check!(assets) end)

    assert error.message =~ "npm install"
    assert error.message =~ assets
    assert error.message =~ "gitignored"
    assert error.message =~ "bin/preview"
  end

  # BROWSER-10: where it is installed the check passes, so a browser run
  # carries on to the driver.
  test "passes where the Playwright CLI is installed", %{dir: dir} do
    assets = BrowserAssets.assets_dir(dir)
    File.mkdir_p!(Path.join([assets, "node_modules", "playwright"]))
    File.write!(Path.join([assets, "node_modules", "playwright", "package.json"]), "{}")

    assert BrowserAssets.installed?(assets)
    assert :ok = BrowserAssets.check!(assets)
  end

  # PREVIEW-14: the command `bin/preview` runs is the one the message names.
  test "the install command installs into that assets directory", %{dir: dir} do
    assets = BrowserAssets.assets_dir(dir)

    assert ["npm", "install" | _] = BrowserAssets.install_command(assets)
    assert Enum.member?(BrowserAssets.install_command(assets), assets)
  end
end
