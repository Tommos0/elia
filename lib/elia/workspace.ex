defmodule Elia.Workspace do
  @moduledoc """
  A directory the harness works in, and the policy classes for paths inside it:

    * `:extension` - under the skills directory; the agent may change freely
    * `:core` - the rest of the workspace; changes need user approval
    * `:protected` - `.git`, `_build`, `deps`, `.elia`; never written by tools
    * `:outside` - not under the workspace

  Every path function works against a `root`: Elia's own source tree by default
  (WS-4), or the folder of the chat's project (PROJ-12). Elia's own data is
  always under Elia's root (PROJ-13).

      config :elia, :workspace, "/path/to/root"
  """

  @protected ~w(.git _build deps .elia)

  @doc "Elia's own root: `config :elia, :workspace`, or the current directory (WS-4)."
  def root, do: Path.expand(Application.get_env(:elia, :workspace) || File.cwd!())

  @doc "The skills folder under `root` (WS-4)."
  def skills_dir(root \\ root()), do: Path.join(root, "skills")

  @doc "Elia's own data dir, always under Elia's root whatever project a chat is in (PROJ-13)."
  def data_dir, do: Path.join(root(), ".elia")

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
