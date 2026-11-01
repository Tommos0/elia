defmodule Elia.Deploy do
  @moduledoc """
  Deploying a chat's code into the running app (spec: `specs/deployment.md`).

  Elia's own project runs from the *live tree* (`Elia.Workspace.runtime_root/0`):
  that is where the server runs, where the code reloader reloads, and where
  Elia's data lives (DEPLOY-2). A chat in that project never edits the live
  tree: it works in its own git worktree, on branch `chat/<chat id>`, forked
  from `live` when the chat starts (DEPLOY-1, DEPLOY-3). Chats in other projects
  work in the project's folder, with no worktree.

  A *deploy* merges the chat's branch into `live` — fast-forward only, after the
  full test suite has passed in the chat's worktree (DEPLOY-5) — and then loads
  the result into the running app: by hot reload (`Elia.Harness.hot_reload/2`,
  DEPLOY-6) or by restarting the server (`restart/1`, DEPLOY-7). Because the tree
  a chat edits is never the tree that runs, an in-progress or broken edit cannot
  reach the running app at all, and no request ever reloads code (DEPLOY-8).

  A chat works in a worktree when the live tree is on the branch `live`, the
  fork point and deploy target. When it isn't (a tree that was never set up for
  deployment, such as a test workspace), the chat works in the live tree itself,
  as before.
  """

  require Logger

  alias Elia.Workspace

  @live "live"
  @chat_prefix "chat/"

  # What the runtime system exits with when the restart button restarts the
  # server. It must not be 0: `bin/serve` treats a zero exit as a deliberate
  # shutdown and stays down (RESTART-1, RESTART-2), any other status as a crash
  # to recover from.
  @restart_status 75

  ## Paths and branches

  @doc "The dir holding the chats' worktrees: under the live tree's data dir (DEPLOY-1)."
  def worktrees_dir(root \\ Workspace.runtime_root()),
    do: Path.join(Workspace.data_dir(root), "worktrees")

  @doc "The worktree path of a chat (DEPLOY-1)."
  def worktree_path(chat_id, root \\ Workspace.runtime_root()),
    do: Path.join(worktrees_dir(root), chat_id)

  @doc "The branch a chat's worktree is checked out on (DEPLOY-1)."
  def branch(chat_id), do: @chat_prefix <> chat_id

  @doc "The branch a deploy forks from and merges into (DEPLOY-1, DEPLOY-5)."
  def live_branch, do: @live

  @doc """
  The chat whose worktree is at `workspace`, or `nil` when `workspace` isn't a
  chat worktree of this live tree (the live tree itself, or a project folder).
  """
  @spec worktree_chat(binary(), binary()) :: binary() | nil
  def worktree_chat(workspace, root \\ Workspace.runtime_root()) do
    workspace = Path.expand(workspace)

    if Path.dirname(workspace) == worktrees_dir(root), do: Path.basename(workspace)
  end

  @doc """
  Whether the live tree is deployable: it is on the branch `live`, so chats can
  fork their worktrees from it and a deploy can merge back into it (DEPLOY-1,
  DEPLOY-5).
  """
  @spec deployable?(binary()) :: boolean()
  def deployable?(root \\ Workspace.runtime_root()) do
    match?({:ok, @live}, git(root, ["symbolic-ref", "--short", "--quiet", "HEAD"]))
  end

  ## Worktree per chat

  @doc """
  The workspace root of a chat (PROJ-12): its own worktree when it is in Elia's
  own project (DEPLOY-1), the project's folder otherwise, where no worktree is
  created (DEPLOY-3). Falls back to the folder — the live tree — when no
  worktree can be made, so a chat always has a workspace to work in.
  """
  @spec workspace(Elia.Projects.t(), binary()) :: binary()
  def workspace(%{harness?: true} = project, chat_id) do
    case ensure_worktree(chat_id) do
      {:ok, path} ->
        path

      {:error, reason} ->
        Logger.debug("Chat #{chat_id} works in #{project.folder}: #{reason}")
        project.folder
    end
  end

  def workspace(project, _chat_id), do: project.folder

  @doc """
  Creates the chat's worktree, on branch `chat/<chat id>` forked from `live`,
  unless it already exists. Idempotent: a chat that is opened again, or resumes
  after a restart, keeps the worktree (and its uncommitted work) it had
  (DEPLOY-1, DEPLOY-10).
  """
  @spec ensure_worktree(binary(), binary()) :: {:ok, binary()} | {:error, binary()}
  def ensure_worktree(chat_id, root \\ Workspace.runtime_root()) do
    path = worktree_path(chat_id, root)

    cond do
      File.dir?(path) ->
        {:ok, path}

      not deployable?(root) ->
        {:error, "the live tree is not on the branch #{@live}, so it has no fork point"}

      true ->
        add_worktree(chat_id, path, root)
    end
  end

  defp add_worktree(chat_id, path, root) do
    File.mkdir_p!(worktrees_dir(root))

    args =
      if branch_exists?(branch(chat_id), root),
        do: ["worktree", "add", "--force", path, branch(chat_id)],
        else: ["worktree", "add", "--force", "-b", branch(chat_id), path, @live]

    case git(root, args) do
      {:ok, _output} ->
        link_deps(path, root)
        {:ok, path}

      {:error, reason} ->
        {:error, "could not create a worktree for this chat: #{reason}"}
    end
  end

  # A fresh worktree has no dependencies (`deps` is git-ignored), so `mix test`
  # couldn't run there (DEPLOY-5). Share the live tree's, which tests read but
  # never write.
  defp link_deps(path, root) do
    deps = Path.join(root, "deps")
    link = Path.join(path, "deps")

    if File.dir?(deps) and not File.exists?(link), do: File.ln_s(deps, link)
    :ok
  end

  @doc """
  Removes the chat's worktree and deletes its branch (DEPLOY-10). Used when the
  chat is deleted; a branch is kept while its chat exists, since chats are
  resumable.
  """
  @spec remove_worktree(binary(), binary()) :: :ok
  def remove_worktree(chat_id, root \\ Workspace.runtime_root()) do
    path = worktree_path(chat_id, root)

    if File.dir?(path) do
      case git(root, ["worktree", "remove", "--force", path]) do
        {:ok, _} -> :ok
        {:error, _} -> File.rm_rf!(path)
      end

      git(root, ["worktree", "prune"])
    end

    if deployable?(root) or branch_exists?(branch(chat_id), root) do
      git(root, ["branch", "-D", branch(chat_id)])
    end

    :ok
  end

  ## Deploying

  @doc """
  Deploys a chat's code: runs the full test suite in `workspace` — the chat's
  worktree — and then merges its branch into `live`, fast-forward only
  (DEPLOY-5). Nothing is merged when the tests fail, so the running app is
  unaffected (HOT-4).

  `{:ok, message}`, `{:tests_failed, output}` or `{:error, reason}`.
  """
  @spec deploy(binary(), binary()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def deploy(workspace, root \\ Workspace.runtime_root()) do
    case Elia.Harness.run_tests([], workspace) do
      {:ok, _output} -> merge(workspace, root)
      {:error, output} -> {:tests_failed, output}
    end
  end

  @doc """
  Merges a chat's worktree branch into `live`, fast-forward only (DEPLOY-5). A
  workspace that isn't a chat worktree needs no merge: the code is already in
  the live tree. `{:ok, message}` or `{:error, reason}`.
  """
  @spec merge(binary(), binary()) :: {:ok, binary()} | {:error, binary()}
  def merge(workspace, root \\ Workspace.runtime_root()) do
    case worktree_chat(workspace, root) do
      nil ->
        {:ok, "nothing to merge: this chat works in the live tree itself."}

      chat_id ->
        case git(root, ["merge", "--ff-only", branch(chat_id)]) do
          {:ok, output} ->
            {:ok,
             "#{branch(chat_id)} merged into #{@live}.#{if output == "", do: "", else: "\n" <> output}"}

          {:error, reason} ->
            {:error,
             "Could not merge #{branch(chat_id)} into #{@live}. A deploy is fast-forward only, " <>
               "so rebase the chat's branch on #{@live} first.\n\n#{reason}"}
        end
    end
  end

  @doc """
  The hard deploy mode (DEPLOY-7, RESTART-11): deploys the chat's code
  (DEPLOY-5) and then restarts the server, so it comes up on the deployed code
  in a clean process. Only works when `bin/serve` (or another service manager)
  runs the server: it stops the runtime system with a non-zero status, which
  `bin/serve` turns into a restart (RESTART-1, RESTART-2). Nothing is merged or
  restarted when the tests fail.
  """
  @spec restart(binary(), binary()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def restart(workspace, root \\ Workspace.runtime_root()) do
    with :ok <- restartable?() do
      case deploy(workspace, root) do
        {:ok, message} ->
          stop()
          {:ok, "#{message} Restarting the server on the deployed code."}

        {:tests_failed, output} ->
          {:tests_failed, output}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Whether the server can be restarted: only the dev server, run by `bin/serve`
  or a service manager, comes back after it stops (DEPLOY-7). A server started
  by hand in a shell can't be, so the restart button says so instead of stopping
  it for good.
  """
  @spec restartable?() :: :ok | {:error, binary()}
  def restartable? do
    if Elia.Harness.hot_reload_available?() do
      :ok
    else
      {:error,
       "Restarting is only available when the dev server runs, started by bin/serve " <>
         "(or a service manager) so it comes back."}
    end
  end

  # How the server stops for a restart. Tests replace it with a message to
  # themselves; anything else stops the runtime system (status 75, "EX_TEMPFAIL").
  defp stop do
    stop = Application.get_env(:elia, __MODULE__, [])[:stop] || (&System.stop/1)
    stop.(@restart_status)
  end

  @doc """
  The endpoint's code reloader. It never reloads on a request (DEPLOY-8): a
  merge into the live tree stays inert until a deploy loads it.

  Kept as a no-op rather than dropping the plug, because `hot_reload` still
  calls `Phoenix.CodeReloader.reload/1` directly (HOT-5).
  """
  def reload(_endpoint, _opts \\ []), do: :ok

  @doc """
  The `live_reload` patterns for the endpoint (DEPLOY-12): the live tree's own
  static assets only. The pattern is anchored at the live tree, so the copies
  of those assets that appear when a chat's worktree is created (DEPLOY-1) do
  not match: reloading on those would reload the browser while it navigates to
  a new chat, undoing the navigation.
  """
  @spec static_reload_patterns() :: [Regex.t()]
  def static_reload_patterns do
    root = Workspace.runtime_root()

    [~r{^#{Regex.escape(root)}/priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$}]
  end

  ## Git

  defp branch_exists?(branch, root) do
    match?({:ok, _}, git(root, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, String.trim(out)}
    end
  rescue
    e -> {:error, "could not run git: #{Exception.message(e)}"}
  end
end
