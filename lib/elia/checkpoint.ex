defmodule Elia.Checkpoint do
  @moduledoc """
  Snapshots of the workspace, stored as git commits under
  `refs/elia/checkpoints/`.

  Snapshots are built with a temporary index, so they never touch HEAD, the
  current branch or the user's staging area. They include untracked files
  and respect `.gitignore`. Rolling back first snapshots the current state,
  so a rollback can itself be undone.

  The first change in an agent turn takes a checkpoint (`ensure/1`); the
  harness rolls back to it when verification fails.
  """

  use GenServer

  alias Elia.Workspace

  @ref_prefix "refs/elia/checkpoints/"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Takes a checkpoint for `turn_id` unless one exists. `nil` is a no-op.

  `root` is the workspace to snapshot: the chat's own worktree for a chat in
  Elia's own project, so a rollback undoes that chat's work, not the live
  tree's (DEPLOY-1).
  """
  @spec ensure(term(), binary()) :: :ok | {:error, binary()}
  def ensure(turn_id, root \\ Workspace.root())

  def ensure(nil, _root), do: :ok

  def ensure(turn_id, root) do
    case GenServer.call(__MODULE__, {:ensure, turn_id, root}, :infinity) do
      {:ok, _sha} -> :ok
      {:error, reason} -> {:error, "Could not checkpoint the workspace: #{reason}"}
    end
  end

  @doc "The checkpoint taken for `turn_id`, if any."
  def for_turn(turn_id), do: GenServer.call(__MODULE__, {:for_turn, turn_id})

  def create(label, root \\ Workspace.root()),
    do: GenServer.call(__MODULE__, {:create, label, root}, :infinity)

  @doc """
  Replaces `turn_id`'s checkpoint with a snapshot of the workspace as it is now
  (CKPT-10). A turn without a checkpoint is left alone.
  """
  @spec rebase(term(), binary()) :: :ok | {:error, binary()}
  def rebase(turn_id, root \\ Workspace.root())

  def rebase(nil, _root), do: :ok

  def rebase(turn_id, root) do
    case GenServer.call(__MODULE__, {:rebase, turn_id, root}, :infinity) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not checkpoint the workspace: #{reason}"}
    end
  end

  @doc "Absolute paths of files that differ between checkpoint `sha` and now."
  def changed_files(sha, root \\ Workspace.root()),
    do: GenServer.call(__MODULE__, {:changed_files, sha, root}, :infinity)

  def rollback(sha, root \\ Workspace.root()),
    do: GenServer.call(__MODULE__, {:rollback, sha, root}, :infinity)

  @doc "Checkpoints, newest first, as `%{sha, tree, label, at}` maps."
  def list(limit \\ 20, root \\ Workspace.root()) do
    format = "%(objectname)%09%(tree)%09%(creatordate:iso-strict)%09%(subject)"

    # The last --sort is the primary key; the ref name starts with a ms timestamp,
    # which orders checkpoints created within the same second.
    case git(
           [
             "for-each-ref",
             "--sort=-refname",
             "--sort=-creatordate",
             "--count=#{limit}",
             "--format=#{format}",
             @ref_prefix
           ],
           root
         ) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true) do
          [sha, tree, at, label] = String.split(line, "\t", parts: 4)
          %{sha: sha, tree: tree, at: at, label: label}
        end

      {:error, _} ->
        []
    end
  end

  @doc "The git tree of the workspace as it is now (not stored as a checkpoint)."
  @spec current_tree(binary()) :: {:ok, binary()} | {:error, binary()}
  def current_tree(root \\ Workspace.root()),
    do: GenServer.call(__MODULE__, {:current_tree, root}, :infinity)

  @turn_label "before agent turn"
  @rollback_label "before rollback to "

  @doc """
  The best rollback target in `checkpoints` (newest first, as from `list/1`):
  the newest `before agent turn` checkpoint whose tree differs from
  `current_tree`. When the workspace is exactly the result of the most recent
  rollback, only checkpoints older than that rollback's target are considered.
  `nil` if there is none (CKPT-9).
  """
  @spec recommended([map()], binary()) :: map() | nil
  def recommended(checkpoints, current_tree) do
    candidates =
      case rolled_back_to(checkpoints, current_tree) do
        nil -> checkpoints
        index -> Enum.drop(checkpoints, index + 1)
      end

    Enum.find(
      candidates,
      &(String.starts_with?(&1.label, @turn_label) and &1.tree != current_tree)
    )
  end

  # Index of the checkpoint the latest rollback went to, if the workspace is
  # still exactly that checkpoint.
  defp rolled_back_to(checkpoints, current_tree) do
    with %{label: @rollback_label <> prefix} <-
           Enum.find(checkpoints, &String.starts_with?(&1.label, @rollback_label)),
         index when is_integer(index) <-
           Enum.find_index(checkpoints, &String.starts_with?(&1.sha, prefix)),
         true <- Enum.at(checkpoints, index).tree == current_tree do
      index
    else
      _ -> nil
    end
  end

  ## Server

  @impl true
  def init(turns), do: {:ok, turns}

  @impl true
  def handle_call({:ensure, turn_id, root}, _from, turns) do
    case turns do
      %{^turn_id => sha} ->
        {:reply, {:ok, sha}, turns}

      _ ->
        case snapshot("#{@turn_label} #{turn_id}", root) do
          {:ok, sha} -> {:reply, {:ok, sha}, Map.put(turns, turn_id, sha)}
          error -> {:reply, error, turns}
        end
    end
  end

  def handle_call({:for_turn, turn_id}, _from, turns),
    do: {:reply, Map.get(turns, turn_id), turns}

  def handle_call({:rebase, turn_id, root}, _from, turns) do
    case turns do
      %{^turn_id => _old} ->
        case snapshot("#{@turn_label} #{turn_id} (after sub-task)", root) do
          {:ok, sha} -> {:reply, :ok, Map.put(turns, turn_id, sha)}
          error -> {:reply, error, turns}
        end

      _ ->
        {:reply, :ok, turns}
    end
  end

  def handle_call({:create, label, root}, _from, turns),
    do: {:reply, snapshot(label, root), turns}

  def handle_call({:current_tree, root}, _from, turns), do: {:reply, write_tree(root), turns}

  def handle_call({:changed_files, sha, root}, _from, turns) do
    reply =
      with {:ok, tree} <- write_tree(root),
           {:ok, out} <- git(["diff", "--name-only", sha, tree], root),
           {:ok, top} <- toplevel(root) do
        {:ok, for(path <- String.split(out, "\n", trim: true), do: Path.join(top, path))}
      end

    {:reply, reply, turns}
  end

  def handle_call({:rollback, sha, root}, _from, turns) do
    reply =
      with {:ok, _} <- git(["cat-file", "-e", sha <> "^{commit}"], root),
           {:ok, undo} <- snapshot("before rollback to #{String.slice(sha, 0, 12)}", root),
           {:ok, added} <- git(["diff", "--name-only", "--diff-filter=A", sha, undo], root),
           {:ok, top} <- toplevel(root),
           :ok <- delete_files(top, added),
           {:ok, _} <- git(["restore", "--source=#{sha}", "--worktree", "--", ":/"], root) do
        {:ok, undo}
      end

    {:reply, reply, turns}
  end

  ## Git plumbing

  defp snapshot(label, root) do
    with {:ok, tree} <- write_tree(root),
         {:ok, sha} <- git(["commit-tree", tree, "-m", label], root, identity()),
         stamp = System.system_time(:millisecond),
         {:ok, _} <-
           git(["update-ref", "#{@ref_prefix}#{stamp}-#{String.slice(sha, 0, 8)}", sha], root) do
      {:ok, sha}
    end
  end

  defp write_tree(root) do
    index = Path.join(System.tmp_dir!(), "elia-index-#{System.unique_integer([:positive])}")

    # Starting from the real index lets git reuse its cached file hashes.
    with {:ok, real_index} <-
           git(["rev-parse", "--path-format=absolute", "--git-path", "index"], root) do
      if File.exists?(real_index), do: File.cp!(real_index, index)
      env = [{"GIT_INDEX_FILE", index}]

      try do
        with {:ok, _} <- git(["add", "--all", "--", ":/"], root, env) do
          git(["write-tree"], root, env)
        end
      after
        File.rm(index)
      end
    end
  end

  defp delete_files(top, paths) do
    for path <- String.split(paths, "\n", trim: true), do: File.rm(Path.join(top, path))
    :ok
  end

  defp toplevel(root), do: git(["rev-parse", "--show-toplevel"], root)

  defp identity do
    [
      {"GIT_AUTHOR_NAME", "Elia"},
      {"GIT_AUTHOR_EMAIL", "elia@localhost"},
      {"GIT_COMMITTER_NAME", "Elia"},
      {"GIT_COMMITTER_EMAIL", "elia@localhost"}
    ]
  end

  defp git(args, root, env \\ []) do
    case System.cmd("git", args, cd: root, env: env, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
