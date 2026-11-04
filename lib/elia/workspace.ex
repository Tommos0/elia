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

  # How far `real_location/1` follows a link chain before giving up (WS-5).
  @max_link_depth 8

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

  @doc """
  The real location of `path` (WS-5): its path with symlinks followed. A path
  that doesn't exist yet — or a link whose target doesn't — comes back as what
  does exist with the rest of the path appended, so a write target is judged by
  where it would land.

  The classes of `classify/2` are decided on the path as written; a caller that
  must not be fooled by a link compares real locations (FILE-13).
  """
  @spec real_location(binary()) :: binary()
  def real_location(path) do
    ["/" | components] = Path.split(Path.expand(path))
    resolve(components, "/", @max_link_depth)
  end

  # Components left to right, `real` being the resolved prefix. A link is
  # followed where it is found, whether it is the last component or in the
  # middle, and the rest of the path continues from the link's target. The depth
  # bound is what a chain gets at most: a loop (`a -> a`) would otherwise follow
  # forever.
  defp resolve([], real, _depth), do: real

  defp resolve([name | rest], real, depth) do
    path = Path.join(real, name)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} when depth > 0 ->
        case File.read_link(path) do
          {:ok, target} -> resolve(rest, resolve_target(target, real, depth), depth - 1)
          {:error, _} -> Path.join([real, name | rest])
        end

      {:ok, _} ->
        resolve(rest, path, depth)

      {:error, _} ->
        # Nothing exists from here on, so this is where the path would land.
        Path.join([real, name | rest])
    end
  end

  # A link's target is relative to the link's own directory, and may have
  # components of its own, links among them.
  defp resolve_target(target, dir, depth) do
    ["/" | components] = Path.split(Path.expand(target, dir))
    resolve(components, "/", depth - 1)
  end

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp symlink_on_path?(abs, root) do
    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(fn path -> match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) end)
  end
end
