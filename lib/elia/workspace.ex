defmodule Elia.Workspace do
  @moduledoc """
  The directory the harness works in (by default the app's own source tree),
  and the policy classes for paths inside it:

    * `:extension` - under the skills directory; the agent may change freely
    * `:core` - the rest of the workspace; changes need user approval
    * `:protected` - `.git`, `_build`, `deps`, `.elia`; never written by tools
    * `:outside` - not under the workspace

      config :elia, :workspace, "/path/to/root"
  """

  @protected ~w(.git _build deps .elia)

  def root, do: Path.expand(Application.get_env(:elia, :workspace) || File.cwd!())

  def skills_dir, do: Path.join(root(), "skills")

  def data_dir, do: Path.join(root(), ".elia")

  @type class :: :extension | :core | :protected | :outside

  @doc "Expands `path` against the root and classifies it."
  @spec resolve(binary()) :: {binary(), class()}
  def resolve(path) do
    abs = Path.expand(path, root())
    {abs, classify(abs)}
  end

  @spec classify(binary()) :: class()
  def classify(abs) do
    root = root()

    cond do
      not inside?(abs, root) -> :outside
      hd(Path.split(Path.relative_to(abs, root)) ++ [""]) in @protected -> :protected
      # A symlink could point anywhere; don't give it extension privileges.
      inside?(abs, skills_dir()) and not symlink_on_path?(abs, root) -> :extension
      true -> :core
    end
  end

  def relative(abs), do: Path.relative_to(abs, root())

  defp inside?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp symlink_on_path?(abs, root) do
    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(fn path -> match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path)) end)
  end
end
