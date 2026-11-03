defmodule Elia.DepsSync do
  @moduledoc """
  Compiling the shared dependency tree a chat worktree compiles against (spec:
  `specs/command-isolation.md`, ISOL-7).

  A chat worktree doesn't own its dependencies: `deps` is a symlink to the live
  tree's (`Elia.Deploy`), and a jailed command finds it read-only (ISOL-13).
  A compile can need to write inside it — `deps/phoenix` copies its installer
  templates into its own `priv/templates` — so the harness keeps the shared tree
  compiled itself: `mix deps.get` and `MIX_ENV=test mix deps.compile`, in the
  worktree, under the `:deps_sync` profile, the one that binds `deps`
  read-write (ISOL-13).

  It runs before the first jailed command in a worktree — one just created, or
  one that predates this — and again whenever that worktree's `mix.lock`
  changes. `deps.get` finds the lock's dependencies already in the shared tree
  and needs no network; only a changed `mix.lock` fetches. What it remembers is
  one value per worktree, the `mix.lock` it last synced with, kept as a file
  under the live tree's data dir (DEPLOY-2).

  This is a harness step, not a tool call: it needs no approval, and the model
  doesn't choose it.
  """

  require Logger

  alias Elia.{Deploy, Shell, Workspace}

  @timeout :timer.minutes(10)

  @doc """
  Syncs a worktree's dependencies (ISOL-7): nothing when its `mix.lock` is the
  one it was last synced with, else `mix deps.get` and `MIX_ENV=test mix
  deps.compile` in it, under the `:deps_sync` profile, and the lock is
  remembered. `:ok`, or `{:error, reason}` when a step failed (nothing is
  remembered then, so the next call tries again).
  """
  @spec sync(Path.t(), Path.t()) :: :ok | {:error, binary()}
  def sync(dir, root \\ Workspace.runtime_root()) do
    case mix_lock(dir) do
      nil -> :ok
      lock -> if lock == recorded(dir, root), do: :ok, else: compile(dir, lock, root)
    end
  end

  @doc """
  The sync a jailed command owes the worktree it runs in (ISOL-7). Called
  before a `:worktree`-profile command and when a chat's worktree is resolved or
  created; a `dir` that isn't a chat worktree of this live tree is left alone.
  """
  @spec sync_worktree(Path.t()) :: :ok | {:error, binary()}
  def sync_worktree(dir) do
    root = Workspace.runtime_root()

    if Deploy.worktree_chat(dir, root), do: sync(dir, root), else: :ok
  end

  @doc """
  The `mix.lock` a worktree was last synced with (ISOL-7): one value per
  worktree, or `nil` when it was never synced.
  """
  @spec recorded(Path.t(), Path.t()) :: binary() | nil
  def recorded(dir, root \\ Workspace.runtime_root()) do
    case File.read(record_path(dir, root)) do
      {:ok, lock} -> lock
      {:error, _reason} -> nil
    end
  end

  @doc "Where a worktree's recorded `mix.lock` is kept (ISOL-7)."
  @spec record_path(Path.t(), Path.t()) :: Path.t()
  def record_path(dir, root \\ Workspace.runtime_root()) do
    Path.join([
      Workspace.data_dir(root),
      "deps_sync",
      Path.basename(Path.expand(dir)) <> ".mixlock"
    ])
  end

  @doc """
  Forgets what was recorded for a worktree, whose chat is gone (DEPLOY-10).
  """
  @spec forget(Path.t(), Path.t()) :: :ok
  def forget(dir, root \\ Workspace.runtime_root()) do
    File.rm(record_path(dir, root))
    :ok
  end

  ## Syncing

  defp mix_lock(dir) do
    case File.read(Path.join(dir, "mix.lock")) do
      {:ok, lock} -> lock
      {:error, _reason} -> nil
    end
  end

  defp compile(dir, lock, root) do
    case steps(dir) do
      :ok ->
        remember(dir, lock, root)

      {:error, reason} ->
        Logger.warning("Could not sync the dependencies of #{dir}: #{reason}")
        {:error, reason}
    end
  end

  # The spec's ISOL-7 step: a fetch, then a compile for the environment the
  # suite runs in (ISOL-8's allowlist is where MIX_ENV reaches the command).
  defp steps(dir) do
    with :ok <- step("mix deps.get", dir),
         :ok <- step("mix deps.compile", dir, env: [{"MIX_ENV", "test"}]) do
      :ok
    end
  end

  defp step(command, dir, opts \\ []) do
    opts = Keyword.merge([cd: dir, profile: :deps_sync, timeout: @timeout], opts)

    case run(command, opts) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        {:error, "#{command} exited with #{status}:\n#{Shell.truncate(output, 2_000)}"}

      {:timeout, output} ->
        {:error, "#{command} timed out:\n#{Shell.truncate(output, 2_000)}"}
    end
  end

  defp run(command, opts), do: runner().(command, opts)

  # A real sync runs the command in the worktree (ISOL-1); tests replace it with
  # a message to themselves, so the suite doesn't compile a dependency tree
  # (`config :elia, Elia.DepsSync, run: fun`).
  defp runner, do: Application.get_env(:elia, __MODULE__, [])[:run] || (&Shell.run/2)

  defp remember(dir, lock, root) do
    path = record_path(dir, root)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, lock) do
      :ok
    else
      {:error, reason} ->
        message = "could not record #{path}: #{:file.format_error(reason)}"
        Logger.warning(message)
        {:error, message}
    end
  end
end
