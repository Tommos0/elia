defmodule EliaWeb.BrowserAssets do
  @moduledoc """
  The user-wide Playwright CLI the browser layer drives, and what to say when it
  is not there yet (BROWSER-2, BROWSER-10).

  The CLI belongs to the user, not to a workspace: it is installed once with
  npm's user prefix (`~/.local`), so one copy serves Elia and any other project
  on the machine, and a fresh chat worktree installs none. The driver validates
  the directory it is pointed at — `:elia, :playwright_dir` (BROWSER-2) — as it
  starts and raises its own `:assets_dir` error, which reads as an Elixir config
  problem rather than the one command that fixes it. So the check runs first —
  in `test/test_helper.exs`, before `PhoenixTest.Playwright.Supervisor`
  (BROWSER-4, BROWSER-10).
  """

  # Where the package sits inside the install directory, and the version the CLI
  # is pinned to: one whose Chromium revision is already in
  # `~/.cache/ms-playwright` (BROWSER-2).
  @package Path.join(["node_modules", "playwright", "package.json"])
  @version "1.64.1"

  @doc """
  The directory the user-wide Playwright CLI is installed in (BROWSER-2), the
  same one the jail binds read-only (ISOL-26).
  """
  @spec dir() :: Path.t()
  def dir, do: Elia.Shell.playwright_dir()

  @doc "Whether the user-wide Playwright CLI is installed in `dir` (BROWSER-2)."
  @spec installed?(Path.t()) :: boolean()
  def installed?(dir \\ dir()), do: File.exists?(Path.join(dir, @package))

  @doc """
  Fails with a message naming the user-wide install when the Playwright CLI is
  missing (BROWSER-10), so a browser run says what to do instead of raising
  inside the driver; returns `:ok` where it is installed.
  """
  @spec check!(Path.t()) :: :ok
  def check!(dir \\ dir()) do
    if installed?(dir) do
      :ok
    else
      raise """
      The browser layer needs the Playwright CLI, and #{Path.join(dir, @package)} is not there.

      It is a user-wide install, not a workspace dependency (BROWSER-2): install it
      once for the user, and any project on this machine can drive it.

          #{Enum.join(install_command(dir), " ")}

      That needs Node >= 20 and the network. The Chromium it drives comes from
      ~/.cache/ms-playwright, which already holds this version's revision.
      """
    end
  end

  @doc """
  The command that installs what `check!/1` looks for: the user-wide install
  (BROWSER-2). `dir` is the directory that holds `node_modules/playwright`, so
  the npm prefix is its parent (`~/.local/lib` → `~/.local`).
  """
  @spec install_command(Path.t()) :: [binary()]
  def install_command(dir \\ dir()) do
    ["npm", "install", "-g", "--prefix", Path.dirname(dir), "playwright@#{@version}"]
  end
end
