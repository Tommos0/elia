defmodule Elia.Worktrees do
  @moduledoc """
  The worktrees the chats of this installation have, and the sweep that removes
  the ones nothing needs any more (WTREE-3 to WTREE-12).

  A chat in Elia's own project makes itself a git worktree before it changes
  code (DEPLOY-28) and, when its work is merged, leaves that worktree where it
  is (WTREE-5) — so the tree a resumed chat still works in outlives the chat
  being done, and the worktree of a chat that was deleted does not stay for
  ever. Nothing tells the harness that a worktree was made: the chat's own
  command made it (DEPLOY-1), so this module reads the filesystem —
  `<project folder>/tmp/worktrees/<chat id>` under every project's folder
  (WTREE-3, WTREE-10). `scan/1` reads that into the table the views read
  (`exists?/1`, WTREE-1 to WTREE-4) and `sweep/1` removes from it (WTREE-6 to
  WTREE-9).

  The process sweeps on an interval of its own (WTREE-10) and measures every age
  against the `now` it is handed, which is how a test places a sweep in time.
  """

  use GenServer

  require Logger

  # WTREE-4: the set the views read — a table rather than a call, so drawing a
  # chat's row costs no round trip. A row is `{chat id, the folder it was found
  # in}`, so a scan of one folder leaves another folder's rows alone.
  @table :elia_worktrees

  # WTREE-10: how often the sweep runs.
  @interval_ms 60_000
  # WTREE-6, WTREE-7: the least age a worktree's chat must have been done for,
  # or a worktree of a chat that is gone must have (an hour).
  @min_age_ms 3_600_000

  @doc "WTREE-10: the interval between sweeps, in milliseconds."
  @spec interval_ms() :: pos_integer()
  def interval_ms, do: setting(:interval_ms, @interval_ms)

  @doc "WTREE-6, WTREE-7: the least age the sweep removes at, in milliseconds."
  @spec min_age_ms() :: pos_integer()
  def min_age_ms, do: setting(:min_age_ms, @min_age_ms)

  defp setting(key, default) do
    :elia |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  WTREE-1 to WTREE-4: whether that chat has a worktree, as the last scan found
  it. A chat nothing has scanned reads as having none.
  """
  @spec exists?(binary()) :: boolean()
  def exists?(id) when is_binary(id) do
    case :ets.whereis(@table) do
      :undefined -> false
      table -> :ets.member(table, id)
    end
  rescue
    # WTREE-4: the table can go with its process between those two calls.
    ArgumentError -> false
  end

  def exists?(_id), do: false

  @doc "WTREE-4: the chat ids that have a worktree, as the last scan found them."
  @spec ids() :: [binary()]
  def ids do
    case :ets.whereis(@table) do
      :undefined -> []
      table -> Enum.map(:ets.tab2list(table), &elem(&1, 0))
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  WTREE-3, WTREE-4, WTREE-10: reads the filesystem and makes the set what it
  finds — every `<project folder>/tmp/worktrees/<chat id>` directory (DEPLOY-28)
  under the live tree (DEPLOY-3) and the folder of each registered project
  (PROJ-3, PROJ-4), or under `:folders` where a caller names them. Answers what
  it found, each a `%{chat_id: id, path: path, folder: folder}`.
  """
  @spec scan(keyword()) :: [map()]
  def scan(opts \\ []) do
    folders = Keyword.get(opts, :folders, folders())
    found = Enum.flat_map(folders, &worktrees_in/1)
    replace(found, folders)
    found
  end

  @doc "WTREE-3: the worktrees one project folder holds."
  @spec worktrees_in(binary()) :: [map()]
  def worktrees_in(folder) do
    root = Path.join([folder, "tmp", "worktrees"])

    case File.ls(root) do
      {:ok, names} ->
        for name <- names, File.dir?(Path.join(root, name)) do
          %{chat_id: name, path: Path.join(root, name), folder: folder}
        end

      {:error, _} ->
        []
    end
  end

  # WTREE-10: every folder a chat of this installation works in — the live tree
  # for Elia's own project (DEPLOY-3), each project's folder otherwise.
  defp folders do
    Elia.Projects.list()
    |> Enum.map(& &1.folder)
    |> Enum.uniq()
  end

  # WTREE-4: the rows of the folders just read become what was found there; the
  # rows of any other folder stay.
  defp replace(found, folders) do
    table = table()
    Enum.each(folders, &:ets.match_delete(table, {:_, &1}))
    Enum.each(found, &:ets.insert(table, {&1.chat_id, &1.folder}))
    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, read_concurrency: true])
      table -> table
    end
  end

  @doc """
  WTREE-6 to WTREE-11: one sweep — it scans first (WTREE-4), then removes what it
  may and leaves the rest, each with the reason it stayed. `now` is the moment
  the ages are measured against (the moment of the call by default), `min_age_ms`
  the least age (default `min_age_ms/0`) and `folders` the folders to read
  (default every folder a chat works in, WTREE-10). Answers
  `%{removed: [worktree], left: [worktree with :reason]}`.
  """
  @spec sweep(keyword()) :: %{removed: [map()], left: [map()]}
  def sweep(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    min_age = Keyword.get(opts, :min_age_ms, min_age_ms())
    running = running_ids()

    results =
      opts
      |> Keyword.take([:folders])
      |> scan()
      |> Enum.map(&sweep_one(&1, now, min_age, running))

    removed = for {worktree, :removed} <- results, do: worktree

    # WTREE-4: a worktree that is gone is no longer marked.
    Enum.each(removed, &:ets.delete(table(), &1.chat_id))

    %{
      removed: removed,
      left:
        for(
          {worktree, reason} <- results,
          reason != :removed,
          do: Map.put(worktree, :reason, reason)
        )
    }
  end

  defp sweep_one(worktree, now, min_age, running) do
    # WTREE-6: a chat whose turn is running is left alone whatever the age — its
    # worktree is the directory its own commands run in (SHELL-2).
    if MapSet.member?(running, worktree.chat_id) do
      {worktree, :running}
    else
      case removal_gate(worktree, now, min_age) do
        # WTREE-8: what a chat left uncommitted is not discarded.
        :ok -> if clean?(worktree.path), do: remove(worktree), else: {worktree, :uncommitted}
        reason -> {worktree, reason}
      end
    end
  end

  # WTREE-6: the chat is marked done and its last save is at least the least age
  # ago. WTREE-7: the chat is gone and the worktree's own directory is that old.
  # WTREE-12: a chat that is not done keeps its worktree however old it is.
  defp removal_gate(worktree, now, min_age) do
    case Elia.Store.load_meta(worktree.chat_id) do
      %{done: true} = meta -> if aged?(saved_at(meta), now, min_age), do: :ok, else: :recent
      nil -> if aged?(modified_at(worktree.path), now, min_age), do: :ok, else: :recent
      _open -> :not_done
    end
  end

  # STORE-1, STORE-34: when the chat was last saved, which for a chat marked done
  # is when it was marked done.
  defp saved_at(meta) do
    case Map.get(meta, :updated_at) do
      %DateTime{} = at -> DateTime.to_unix(at, :millisecond)
      _none -> 0
    end
  end

  defp modified_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime * 1000
      {:error, _} -> 0
    end
  end

  defp aged?(at, now, min_age), do: DateTime.to_unix(now, :millisecond) - at >= min_age

  # WTREE-8: `git status --porcelain` printing anything — a modified file, a file
  # git does not ignore — keeps the worktree where it is.
  defp clean?(path) do
    case git(path, ["status", "--porcelain"]) do
      {out, 0} -> String.trim(out) == ""
      _ -> false
    end
  end

  # WTREE-6, WTREE-7, WTREE-9: the worktree goes, and its branch with it only
  # when that branch's work is already in the trunk.
  defp remove(worktree) do
    case git(worktree.folder, ["worktree", "remove", worktree.path]) do
      {_out, 0} ->
        branch = "chat/#{worktree.chat_id}"
        # WTREE-11: what went, and the branch's fate.
        log(:info, "worktree swept: #{worktree.path} (#{branch_fate(worktree.folder, branch)})")
        {worktree, :removed}

      {out, code} ->
        log(:warning, "worktree left: #{worktree.path} (#{code}: #{String.trim(out)})")
        {worktree, :failed}
    end
  end

  # WTREE-9: a branch is dropped only when its commits are in the trunk already;
  # one holding work that has not landed stays.
  defp branch_fate(folder, branch) do
    if merged?(folder, branch) do
      case git(folder, ["branch", "-D", branch]) do
        {_out, 0} -> "branch #{branch} deleted"
        {out, code} -> "branch #{branch} left (#{code}: #{String.trim(out)})"
      end
    else
      "branch #{branch} left: its work is not in the trunk"
    end
  end

  defp merged?(folder, branch) do
    case git(folder, ["merge-base", "--is-ancestor", branch, "master"]) do
      {_out, 0} -> true
      _ -> false
    end
  end

  defp git(dir, args) do
    System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
  rescue
    # No git to run: nothing is swept, and the server stays up.
    _ -> {"git is not available", 127}
  end

  defp log(level, message), do: Logger.log(level, message)

  # WTREE-6: the sessions whose turn is running (SESS-28), for the sweep to leave
  # their worktrees alone. A registry that isn't up yet reads as none running.
  defp running_ids do
    MapSet.new(Elia.Agent.running())
  rescue
    _ -> MapSet.new()
  end

  @impl true
  def init(_opts) do
    table()
    # WTREE-4: the set is what the filesystem says when the server comes up, so
    # the views have it before the first interval has passed.
    scan()
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_quietly()
    schedule()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # WTREE-10: an interval of `0` runs no timer: the server scans on the way up
  # (WTREE-4) and `sweep/1` is there to call, which is what a test run does.
  defp schedule do
    case interval_ms() do
      interval when interval > 0 -> Process.send_after(self(), :sweep, interval)
      _none -> :ok
    end
  end

  # A sweep that fails must not take the process with it and repeat every
  # interval: the next one is another chance.
  defp sweep_quietly do
    sweep()
  rescue
    error -> log(:warning, "worktree sweep failed: #{inspect(error)}")
  end
end
