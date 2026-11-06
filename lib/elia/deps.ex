defmodule Elia.Deps do
  @moduledoc """
  The dependency layer a chat's worktree compiles against (spec:
  `specs/command-isolation.md`, ISOL-7, DEPLOY-10).

  A chat worktree holds no dependency tree of its own: its `deps` is a symlink
  to the live tree's (`Elia.Deploy`, DEPLOY-1), so every worktree and the live
  tree compile the same sources. A compile can need to write inside that tree —
  `deps/phoenix` copies its installer templates into its own `priv/templates`,
  and `mix deps.get` unpacks a dependency the chat added — so a chat's own
  commands get it as an **overlay** (`Elia.Shell`): the live tree's `deps` is the
  read-only lower layer, and everything a command writes lands in the upper
  layer this module owns, one per worktree, under the live tree's data dir
  (DEPLOY-2). What the live tree and every other chat compile against is
  unchanged by any command, and two worktrees never write the same file.

  A dependency a chat adds is fetched into its own layer, so it stays that
  chat's until its change is deployed (DEPLOY-18). The layer sits under the
  masked `.elia` (ISOL-6), so nothing inside the jail can reach it, and it is
  removed with the worktree (DEPLOY-10).
  """

  alias Elia.Workspace

  @doc """
  A worktree's layer directory (ISOL-7): where its upper layer and the overlay's
  work directory live, keyed on the worktree's own directory name — a chat's id.
  """
  @spec layer(Path.t(), Path.t()) :: Path.t()
  def layer(dir, root \\ Workspace.runtime_root()) do
    Path.join([
      Workspace.data_dir(root),
      "deps_layer",
      Path.basename(Path.expand(dir))
    ])
  end

  @doc """
  The upper layer and the work directory for a worktree's overlay (ISOL-7),
  created when a command first needs them: `{:ok, {upper, work}}`, or `{:error,
  reason}` when they could not be made — the command then runs without an
  overlay, and what it could not write is in its own result.
  """
  @spec open(Path.t(), Path.t()) :: {:ok, {Path.t(), Path.t()}} | {:error, binary()}
  def open(dir, root \\ Workspace.runtime_root()) do
    base = layer(dir, root)
    upper = Path.join(base, "upper")
    work = Path.join(base, "work")

    with :ok <- mkdir(upper), :ok <- mkdir(work) do
      {:ok, {upper, work}}
    end
  end

  @doc """
  Removes a worktree's layer (DEPLOY-10), whose chat is gone, or which never had
  one — a chat that added no dependency and compiled nothing has an empty one.
  """
  @spec remove(Path.t(), Path.t()) :: :ok
  def remove(dir, root \\ Workspace.runtime_root()) do
    File.rm_rf(layer(dir, root))
    :ok
  end

  defp mkdir(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end
end
