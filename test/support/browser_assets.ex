defmodule EliaWeb.BrowserAssets do
  @moduledoc """
  Where the browser layer's Node packages live, and what to say when they are
  not there yet (BROWSER-10, BROWSER-2).

  The Playwright CLI comes from the workspace's own `assets/package.json`, and
  `assets/node_modules` is gitignored (`.gitignore`), so a fresh chat worktree
  never has it (DEPLOY-1). The driver validates that directory as it starts
  and raises its own `:assets_dir` error, which reads as an Elixir config
  problem rather than the one command that fixes it. So the check runs first —
  in `test/test_helper.exs`, before `PhoenixTest.Playwright.Supervisor`
  (BROWSER-4, BROWSER-10) — and `bin/preview` installs what is missing
  (PREVIEW-14) before it gets that far.
  """

  @package Path.join(["node_modules", "playwright", "package.json"])

  @doc "The workspace's assets directory, where the Playwright CLI is installed (BROWSER-2)."
  @spec assets_dir(Path.t()) :: Path.t()
  def assets_dir(root \\ File.cwd!()), do: Path.join(root, "assets")

  @doc "Whether the Playwright CLI is installed in `assets_dir` (BROWSER-2)."
  @spec installed?(Path.t()) :: boolean()
  def installed?(dir \\ assets_dir()), do: File.exists?(Path.join(dir, @package))

  @doc """
  Fails with a message naming the install when the Playwright CLI is missing
  (BROWSER-10), so a browser run says what to do instead of raising inside the
  driver; returns `:ok` where it is installed.
  """
  @spec check!(Path.t()) :: :ok
  def check!(dir \\ assets_dir()) do
    if installed?(dir) do
      :ok
    else
      raise """
      The browser layer needs the Playwright CLI, and #{Path.join(dir, @package)} is not there.

      assets/node_modules is gitignored, so a fresh chat worktree has none until it
      installs them. Install the workspace's own pinned packages:

          cd #{dir} && npm install

      That needs Node >= 20 and the network. `bin/preview` runs this install for
      you on its first run in a worktree (PREVIEW-14).
      """
    end
  end

  @doc "The command that installs what `check!/1` looks for (PREVIEW-14)."
  @spec install_command(Path.t()) :: [binary()]
  def install_command(dir \\ assets_dir()),
    do: ["npm", "install", "--prefix", dir, "--no-audit", "--no-fund"]
end
