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

  It doesn't hold up the start of a chat (ISOL-7): `sync_in_background/2` is
  what a chat that just got its worktree calls, and the first jailed command in
  a worktree that isn't synced yet waits for the sync instead (`sync/2`, called
  by `Elia.Shell`), so no command ever compiles against a half-synced tree. Two
  syncs of the same shared `deps` never run at once — the resource is that tree,
  not the worktree, since every worktree of a live tree compiles against the
  same one — and a caller that waited its turn finds the work done. A failure
  isn't remembered (nothing is written), so the next command tries again.

  While a sync is in flight the chat whose worktree it is says so (ISOL-23,
  UI-70): `syncing?/1` answers for a page that connects, and the sync broadcasts
  `{:deps_sync, on?}` on the chat's topic (`Elia.Agent.topic/1`, as `Elia.Tasks`
  does for `{:subtask, …}`) as it starts and ends.

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

  Only one sync of a live tree's shared `deps` runs at a time (ISOL-7), so a
  caller that finds one in flight — a command in the worktree whose compile it
  is — waits for it rather than starting a second one, and then finds the work
  already done.
  """
  @spec sync(Path.t(), Path.t()) :: :ok | {:error, binary()}
  def sync(dir, root \\ Workspace.runtime_root()) do
    case mix_lock(dir) do
      nil -> :ok
      lock -> if lock == recorded(dir, root), do: :ok, else: in_turn(dir, lock, root)
    end
  end

  @doc """
  Starts a worktree's sync (ISOL-7) and returns without waiting for it, so a
  chat that just got its worktree — or resolved an existing one — opens at once.
  The first jailed command in the worktree waits for the sync instead (`sync/2`).

  A failure is logged (as `sync/2` does) and nothing takes the chat down: the
  worktree's next command tries the sync again (ISOL-23).
  """
  @spec sync_in_background(Path.t(), Path.t()) :: :ok
  def sync_in_background(dir, root \\ Workspace.runtime_root()) do
    dir = Path.expand(dir)

    # Not `Task.async`: nothing waits for this one. Nothing links to it either,
    # so a failure can't reach the chat that started it.
    {:ok, _pid} =
      Task.start(fn ->
        try do
          sync(dir, root)
        rescue
          e ->
            Logger.warning("Could not sync the dependencies of #{dir}: #{Exception.message(e)}")
        end
      end)

    :ok
  end

  @doc """
  Whether a sync of the shared `deps` a worktree compiles against is in flight
  (ISOL-7, ISOL-23), which is what a page that connects mid-sync shows (UI-70).
  A `dir` that isn't a chat worktree of this live tree is never syncing: nothing
  syncs it.
  """
  @spec syncing?(Path.t(), Path.t()) :: boolean()
  def syncing?(dir, root \\ Workspace.runtime_root()) do
    Deploy.worktree_chat(dir, root) != nil and :global.whereis_name(deps_id(root)) != :undefined
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

  # ISOL-7: two syncs of the same `deps` never run at once. They write the same
  # files in the shared tree — a compile into a dependency's own tree, a fetch
  # into the hex cache — and a file torn that way breaks every worktree that
  # compiles against it. So the lock is keyed on that tree, not on the worktree:
  # every worktree of a live tree compiles against the same `deps`, and the two
  # callers that have to serialize are usually two different worktrees'. The
  # nodes list is this node alone — there is one server.
  #
  # A `:global` lock is released when its holder dies, so a sync that crashed
  # can't leave a stale lock behind and block every later command; `after`
  # releases it on the ordinary path.
  defp in_turn(dir, lock, root) do
    id = deps_id(root)

    :global.set_lock({id, self()}, [node()])

    try do
      # ISOL-7: taken, so the tree is this caller's to write. A caller that
      # queued behind another sync of the same tree finds the compile done here
      # and doesn't redo it — the check before the lock is only the fast path
      # for a worktree that was synced long ago.
      in_flight(dir, root, fn ->
        if recorded(dir, root) == lock, do: :ok, else: compile(dir, lock, root)
      end)
    after
      :global.del_lock({id, self()}, [node()])
    end
  end

  # The shared `deps` of a live tree, which is what a sync is serialized on and
  # what a page reads as "syncing" (ISOL-7, ISOL-23).
  defp deps_id(root), do: {:elia_deps_sync, Path.expand(Path.join(root, "deps"))}

  # ISOL-23, UI-70: the chat whose worktree is being compiled says so. The state
  # is a `:global` name held by the syncing process, so it goes when the sync
  # ends — whether it succeeded or failed — and can't outlive it either: naming
  # a dead process is undone like a lock.
  defp in_flight(dir, root, fun) do
    id = deps_id(root)
    chat = Deploy.worktree_chat(dir, root)
    :global.register_name(id, self())
    if chat, do: broadcast(chat, true)

    try do
      fun.()
    after
      if chat, do: broadcast(chat, false)
      :global.unregister_name(id)
    end
  end

  # The event a chat's page follows, on the chat's own topic. `Elia.Tasks`
  # broadcasts `{:subtask, …}` the same way, since the sync isn't a session's
  # own step either.
  defp broadcast(chat, on?) do
    Phoenix.PubSub.broadcast(
      Elia.PubSub,
      Elia.Agent.topic(chat),
      {:agent, chat, {:deps_sync, on?}}
    )
  end

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
