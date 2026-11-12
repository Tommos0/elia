defmodule EliaWeb.BrowserAssetsTest do
  @moduledoc """
  The check a browser run does before it starts the Playwright driver
  (BROWSER-10): where the user-wide CLI is looked for, and the message that says
  what to install when it isn't there, instead of the driver's own `:assets_dir`
  error.
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

  # BROWSER-2: the CLI is a user-wide install, and the driver is pointed at the
  # directory that holds it — the same one the jail binds read-only (ISOL-26).
  test "the CLI is looked for where the config names it" do
    assert BrowserAssets.dir() == Elia.Shell.playwright_dir()
    assert Application.get_env(:phoenix_test, :playwright)[:assets_dir] == BrowserAssets.dir()
  end

  # BROWSER-2: with no override the install is the npm user prefix's lib, which
  # is what `npm install -g --prefix ~/.local` writes.
  test "the default is the user prefix's lib" do
    if System.get_env("ELIA_PLAYWRIGHT_DIR") == nil do
      assert BrowserAssets.dir() == Path.expand("~/.local/lib")
    end
  end

  test "a directory with no Playwright package is not installed", %{dir: dir} do
    refute BrowserAssets.installed?(dir)
  end

  # BROWSER-10: a machine that never installed the CLI gets a message naming the
  # user-wide install, not a workspace one.
  test "names the user-wide install when Playwright is missing", %{dir: dir} do
    error = assert_raise(RuntimeError, fn -> BrowserAssets.check!(dir) end)

    assert error.message =~ "user-wide"
    assert error.message =~ "npm install -g --prefix"
    assert error.message =~ dir
    assert error.message =~ "playwright@"
  end

  # BROWSER-10: where it is installed the check passes, so a browser run carries
  # on to the driver.
  test "passes where the Playwright CLI is installed", %{dir: dir} do
    File.mkdir_p!(Path.join([dir, "node_modules", "playwright"]))
    File.write!(Path.join([dir, "node_modules", "playwright", "package.json"]), "{}")

    assert BrowserAssets.installed?(dir)
    assert :ok = BrowserAssets.check!(dir)
  end

  # BROWSER-2: the command installs into that directory — the npm prefix is its
  # parent, so `~/.local/lib` comes from `--prefix ~/.local` — and it is pinned
  # to the version whose Chromium is cached.
  test "the install command installs into the directory's parent prefix", %{dir: dir} do
    assert ["npm", "install", "-g", "--prefix", prefix, package] =
             BrowserAssets.install_command(dir)

    assert prefix == Path.dirname(dir)
    assert package == "playwright@1.64.1"
  end
end
