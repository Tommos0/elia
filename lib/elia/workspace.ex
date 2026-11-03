defmodule Elia.Workspace do
  @moduledoc """
  A directory the harness works in, and the policy classes for paths inside it:

    * `:extension` - under the skills directory; the agent may change freely
    * `:core` - the rest of the workspace; changes need user approval
    * `:protected` - `.git`, `_build`, `deps`, `.elia`; never written by tools
    * `:outside` - not under the workspace

  Every path function works against a `root`: Elia's own source tree by default
  (WS-4), the live tree, or the folder of the chat's project (PROJ-12). Elia's
  own data is always under the live tree (PROJ-13, DEPLOY-2).

      config :elia, :workspace, "/path/to/root"

  The live tree is where the server runs and where Elia's data lives; a chat in
  Elia's own project works in its own git worktree instead, and its tools use
  that worktree as their root (DEPLOY-1):

      config :elia, :runtime_root, "/path/to/live/tree"
  """

  @protected ~w(.git _build deps .elia)

  @doc "Elia's own root: `config :elia, :workspace`, or the current directory (WS-4)."
  def root, do: Path.expand(Application.get_env(:elia, :workspace) || File.cwd!())

  @doc """
  The live tree: where the server runs, where the code reloader reloads, and
  where Elia's data lives (DEPLOY-2). `config :elia, :runtime_root`, else Elia's
  root — the working directory when nothing else is configured, which is where
  the server was started from.
  """
  def runtime_root, do: Path.expand(Application.get_env(:elia, :runtime_root) || root())

  @doc "The skills folder under `root` (WS-4)."
  def skills_dir(root \\ root()), do: Path.join(root, "skills")

  @doc """
  Elia's own data dir (PROJ-13). It sits directly under the live tree, so chats
  are the same across a chat's worktrees and across a deploy (DEPLOY-2).
  """
  def data_dir(root \\ runtime_root()), do: Path.join(root, ".elia")

  @type class :: :extension | :core | :protected | :outside

  @doc "Expands `path` against `root` and classifies it."
  @spec resolve(binary(), binary()) :: {binary(), class()}
  def resolve(path, root \\ root()) do
    abs = Path.expand(path, root)
    {abs, classify(abs, root)}
  end

  @spec classify(binary(), binary()) :: class()
  def classify(abs, root \\ root()) do
    cond do
      not inside?(abs, root) -> :outside
      hd(Path.split(Path.relative_to(abs, root)) ++ [""]) in @protected -> :protected
      # A symlink could point anywhere; don't give it extension privileges.
      inside?(abs, skills_dir(root)) and not symlink_on_path?(abs, root) -> :extension
      true -> :core
    end
  end

  @doc "The path of `abs` relative to `root`."
  def relative(abs, root \\ root()), do: Path.relative_to(abs, root)

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp symlink_on_path?(abs, root) do
    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(fn path -> match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) end)
  end
end
