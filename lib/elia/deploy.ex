defmodule Elia.Deploy do
  @moduledoc """
  Deploying Elia's own code into the running app (spec: `specs/deployment.md`).

  Elia's own project runs from the *live tree* (`Elia.Workspace.runtime_root/0`):
  that is where the server runs, where the code reloader reloads, and where
  Elia's data lives (DEPLOY-2). Two branches of its repository matter: the
  *trunk* `master`, the chats' fork point and the branch they merge their work
  into (DEPLOY-1, DEPLOY-13), and `live`, the branch the live tree is checked out
  on and a deploy's target (DEPLOY-14).

  A chat in that project never edits the live tree: it works in its own git
  worktree, on branch `chat/<chat id>`, forked from the trunk (DEPLOY-1). When a
  change is done the chat's agent merges its branch into the trunk itself
  (`git push . HEAD:master`, which refuses anything but a fast-forward,
  DEPLOY-13). A *deploy* is then the user's step, from the Settings page
  (`EliaWeb.SettingsLive`): it runs the full test suite in the live tree,
  fast-forwards `live` to the trunk when the tests pass (DEPLOY-5) and loads the
  result into the running app — by hot reload (`hot_reload/1`, DEPLOY-6) or by
  restarting the server (`restart/1`, DEPLOY-7). Because the tree a chat edits is
  never the tree that runs, an in-progress or broken edit cannot reach the
  running app at all, and no request ever reloads code (DEPLOY-8).

  A chat works in a worktree when the live tree is *set up for deployment*
  (`deployable/1`, DEPLOY-14). When it isn't (a tree that was never set up for
  deployment, such as a test workspace), the chat works in the live tree itself,
  as before.
  """

  require Logger

  alias Elia.Workspace

  @live "live"
  @trunk "master"
  @chat_prefix "chat/"

  # What the runtime system exits with when a deploy restarts the server. It
  # must not be 0: `bin/serve` treats a zero exit as a deliberate shutdown and
  # stays down (RESTART-1, RESTART-2), any other status as a crash to recover
  # from.
  @restart_status 75

  # How long the deploy's own fetch of the trunk's dependencies may take
  # (DEPLOY-18): the same as a test run, since it is the same network and the
  # same tree (VERIFY-1).
  @deps_timeout :timer.minutes(10)

  ## Paths and branches

  @doc "The dir holding the chats' worktrees: under the live tree's data dir (DEPLOY-1)."
  def worktrees_dir(root \\ Workspace.runtime_root()),
    do: Path.join(Workspace.data_dir(root), "worktrees")

  @doc "The worktree path of a chat (DEPLOY-1)."
  def worktree_path(chat_id, root \\ Workspace.runtime_root()),
    do: Path.join(worktrees_dir(root), chat_id)

  @doc "The branch a chat's worktree is checked out on (DEPLOY-1)."
  def branch(chat_id), do: @chat_prefix <> chat_id

  @doc "The branch the live tree is checked out on and a deploy fast-forwards (DEPLOY-5)."
  def live_branch, do: @live

  @doc "The trunk: the branch the chats fork from and merge into, and a deploy's target (DEPLOY-13)."
  def trunk_branch, do: @trunk

  @doc """
  The chat whose worktree is at `workspace`, or `nil` when `workspace` isn't a
  chat worktree of this live tree (the live tree itself, or a project folder).
  """
  @spec worktree_chat(binary(), binary()) :: binary() | nil
  def worktree_chat(workspace, root \\ Workspace.runtime_root()) do
    workspace = Path.expand(workspace)

    if Path.dirname(workspace) == worktrees_dir(root), do: Path.basename(workspace)
  end

  ## The trunk and the deploy target (DEPLOY-14)

  @doc """
  Whether the live tree is set up for deployment (DEPLOY-14): it is checked out
  on the branch `live`, has a trunk `master`, and `live` is an ancestor of the
  trunk — a deploy only ever fast-forwards `live` onto it (DEPLOY-5).

  `:ok`, or an error naming what is missing and the one-time fix.
  """
  @spec deployable(binary()) :: :ok | {:error, binary()}
  def deployable(root \\ Workspace.runtime_root()) do
    cond do
      not on_branch?(@live, root) ->
        {:error,
         "The live tree is not on the branch #{@live}: set it up once with " <>
           "`git checkout -b #{@live}`."}

      not branch_exists?(@trunk, root) ->
        {:error,
         "There is no #{@trunk} branch to fork chats from and merge into: create it " <>
           "once with `git branch #{@trunk}`."}

      not ancestor?(@live, @trunk, root) ->
        {:error,
         "#{@trunk} is behind #{@live}, so a deploy could not fast-forward it: " <>
           "bring the trunk up to date once with `git branch -f #{@trunk} #{@live}`."}

      true ->
        :ok
    end
  end

  @doc "Whether the live tree is set up for deployment (DEPLOY-14)."
  @spec deployable?(binary()) :: boolean()
  def deployable?(root \\ Workspace.runtime_root()), do: deployable(root) == :ok

  @doc """
  What the Settings page reports about deployment (CONF-19, DEPLOY-17): how many
  commits on the trunk are not deployed yet, the revision `live` is at, the
  revision the running app has loaded (`nil` when none is recorded), and whether
  the app is behind `live` — a deploy that merged and never reached the load
  (DEPLOY-15). `{:error, reason}` when the live tree isn't set up for deployment
  (DEPLOY-14).
  """
  @spec status(binary()) :: {:ok, map()} | {:error, binary()}
  def status(root \\ Workspace.runtime_root()) do
    with :ok <- deployable(root),
         {:ok, count} <- git(root, ["rev-list", "--count", "#{@live}..#{@trunk}"]),
         {:ok, live} <- git(root, ["rev-parse", @live]) do
      loaded = loaded_revision(root)

      {:ok,
       %{
         pending: String.to_integer(count),
         live: live,
         loaded: loaded,
         behind?: loaded != nil and loaded != live
       }}
    end
  end

  ## What the running app has loaded (DEPLOY-17)

  @doc "Where a deploy records the revision the running app has loaded (DEPLOY-17)."
  @spec loaded_path(binary()) :: binary()
  def loaded_path(root \\ Workspace.runtime_root()),
    do: Path.join(Workspace.data_dir(root), "deployed")

  @doc """
  The revision the running app has loaded (DEPLOY-17), or `nil` when none has
  been recorded yet: a server that started before this was recorded.
  """
  @spec loaded_revision(binary()) :: binary() | nil
  def loaded_revision(root \\ Workspace.runtime_root()) do
    case File.read(loaded_path(root)) do
      {:ok, contents} -> blank_to_nil(String.trim(contents))
      {:error, _reason} -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(sha), do: sha

  @doc """
  Records the revision the running app runs (DEPLOY-17): the one a deploy just
  loaded (DEPLOY-6) or one a restart is about to come up on (DEPLOY-7). The
  server's first start in the live tree counts too — it runs what the tree has
  checked out — so `Elia.Deploy.Runner` records that at boot. A tree that isn't
  set up for deployment (DEPLOY-14) is left alone, and failing to record is
  never a deploy failure.
  """
  @spec record_loaded(binary()) :: :ok
  def record_loaded(root \\ Workspace.runtime_root()) do
    with :ok <- deployable(root),
         {:ok, sha} <- git(root, ["rev-parse", @live]) do
      File.write(loaded_path(root), sha <> "\n")
    end

    :ok
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
  The workspace a chat works in when one already exists (EXPL-17, FLINK-5): its
  own worktree for a chat in Elia's own project, the project's folder otherwise
  (PROJ-12). Unlike `workspace/2` it creates nothing — a page that resolves it —
  the Files page browsing a chat, or a file link checked against its workspace —
  must not fork a branch as a side effect of being read.
  """
  @spec existing_workspace(Elia.Projects.t(), binary() | nil) :: binary()
  def existing_workspace(project, nil), do: project.folder

  def existing_workspace(%{harness?: true} = project, chat_id) do
    path = worktree_path(chat_id)
    if File.dir?(path), do: path, else: project.folder
  end

  def existing_workspace(project, _chat_id), do: project.folder

  @doc """
  Creates the chat's worktree, on branch `chat/<chat id>` forked from the trunk
  `master`, unless it already exists. Idempotent: a chat that is opened again,
  or resumes after a restart, keeps the worktree (and its uncommitted work) it
  had (DEPLOY-1, DEPLOY-10).
  """
  @spec ensure_worktree(binary(), binary()) :: {:ok, binary()} | {:error, binary()}
  def ensure_worktree(chat_id, root \\ Workspace.runtime_root()) do
    path = worktree_path(chat_id, root)

    cond do
      File.dir?(path) ->
        {:ok, path}

      true ->
        case deployable(root) do
          :ok -> add_worktree(chat_id, path, root, @trunk)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp add_worktree(chat_id, path, root, base) do
    File.mkdir_p!(worktrees_dir(root))

    args =
      if branch_exists?(branch(chat_id), root),
        do: ["worktree", "add", "--force", path, branch(chat_id)],
        else: ["worktree", "add", "--force", "-b", branch(chat_id), path, base]

    # The worktree is created *inside* the live tree's data dir, so this call
    # needs that writable: the profile for the harness's own steps in the live
    # tree (ISOL-13), not the masked `:live_tree` one a tool call there gets
    # (ISOL-6).
    case git(root, args, profile: :deps_sync) do
      {:ok, _output} ->
        link_deps(path, root)
        {:ok, path}

      {:error, reason} ->
        {:error, "could not create a worktree for this chat: #{reason}"}
    end
  end

  @doc """
  Creates a sub-task's own worktree (SUBTASK-23, DEPLOY-9): branch
  `chat/<sub-task id>`, forked from its parent's branch `chat/<parent id>`, the
  state the parent is in when it hands the work over. Idempotent, like
  `ensure_worktree/2`, so the same worktree is reused.
  """
  @spec ensure_child_worktree(binary(), binary(), binary()) ::
          {:ok, binary()} | {:error, binary()}
  def ensure_child_worktree(child_id, parent_id, root \\ Workspace.runtime_root()) do
    path = worktree_path(child_id, root)

    cond do
      File.dir?(path) ->
        {:ok, path}

      branch_exists?(branch(parent_id), root) ->
        add_worktree(child_id, path, root, branch(parent_id))

      true ->
        {:error, "the parent chat has no worktree to fork from"}
    end
  end

  # A fresh worktree has no dependencies (`deps` is git-ignored), so `mix test`
  # couldn't run there (DEPLOY-5). Share the live tree's, which a command reads
  # through an overlay and writes in its own layer (ISOL-7).
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
      # The worktree itself lives under the live tree's data dir, so its
      # removal is one of the harness's own steps there (ISOL-13).
      case git(root, ["worktree", "remove", "--force", path], profile: :deps_sync) do
        {:ok, _} -> :ok
        {:error, _} -> File.rm_rf!(path)
      end

      git(root, ["worktree", "prune"], profile: :deps_sync)
    end

    if branch_exists?(branch(chat_id), root) do
      git(root, ["branch", "-D", branch(chat_id)])
    end

    Elia.Deps.remove(path, root)
    :ok
  end

  ## Deploying

  @doc """
  Deploys the trunk into the live tree (DEPLOY-5): fast-forwards `live` to
  `master`, runs the full test suite there, and rolls `live` back when the tests
  fail, so nothing is deployed and the running app is unaffected (HOT-4).

  `{:ok, message}`, `{:tests_failed, output}` or `{:error, reason}`. Nothing to
  deploy when `live` is already at the trunk: no tests run, and the message says
  so.
  """
  @spec deploy(binary()) :: {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def deploy(root \\ Workspace.runtime_root()) do
    with :ok <- deployable(root),
         :ok <- clean?(root),
         {:ok, %{pending: pending}} <- status(root) do
      case pending do
        0 -> {:ok, "Nothing to deploy: #{@live} is already #{@trunk}."}
        _ -> merge_and_test(pending, root)
      end
    end
  end

  @doc """
  Fast-forwards `live` to the trunk `master` (DEPLOY-5). A merge can only ever
  be a fast-forward: the trunk is at or ahead of `live` (DEPLOY-14).
  `{:ok, message}` or `{:error, reason}`.
  """
  @spec merge(binary()) :: {:ok, binary()} | {:error, binary()}
  def merge(root \\ Workspace.runtime_root()) do
    case git(root, ["merge", "--ff-only", @trunk]) do
      {:ok, _output} ->
        {:ok, "#{@trunk} merged into #{@live}."}

      {:error, reason} ->
        {:error,
         "Could not merge #{@trunk} into #{@live}. A deploy is fast-forward only, so " <>
           "#{@live} must be an ancestor of #{@trunk} (DEPLOY-14).\n\n#{reason}"}
    end
  end

  @doc """
  The soft deploy mode (DEPLOY-6): deploys the trunk (DEPLOY-5), then recompiles
  the live tree and loads the changed modules into the running app, keeping
  running state. Only available when the endpoint's code reloader is on
  (HOT-2, HOT-7).
  """
  @spec hot_reload(binary()) :: {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def hot_reload(root \\ Workspace.runtime_root()) do
    if hot_reload_available?() do
      case deploy(root) do
        {:ok, deployed} -> load(deployed, root)
        other -> other
      end
    else
      {:error,
       "Hot reload is only available when the endpoint's code reloader is on " <>
         "(`code_reloader: true`)."}
    end
  end

  @doc """
  The hard deploy mode (DEPLOY-7, RESTART-11): deploys the trunk (DEPLOY-5) and
  then restarts the server, so it comes up on the deployed code in a clean
  process. Only works when `bin/serve` (or another service manager) runs the
  server: it stops the runtime system with a non-zero status, which `bin/serve`
  turns into a restart (RESTART-1, RESTART-2). Nothing is deployed or restarted
  when the tests fail.
  """
  @spec restart(binary()) :: {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def restart(root \\ Workspace.runtime_root()) do
    with :ok <- restartable?() do
      case deploy(root) do
        {:ok, deployed} ->
          # DEPLOY-17: the server comes back on this revision, so record it
          # before it stops.
          record_loaded(root)
          stop()
          {:ok, "#{deployed} Restarting the server on the deployed code."}

        other ->
          other
      end
    end
  end

  @doc """
  Runs a deploy in one of its modes (DEPLOY-6, DEPLOY-7): `:reload` for the hot
  reload, `:restart` for the restart. What `Elia.Deploy.Runner` calls, so a
  deploy started from the Settings page runs outside the page (DEPLOY-15).
  """
  @spec run(:reload | :restart, binary()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def run(mode, root \\ Workspace.runtime_root())

  def run(:reload, root), do: hot_reload(root)
  def run(:restart, root), do: restart(root)

  @doc """
  Whether the server can be restarted: only a server run by `bin/serve` or
  another service manager comes back after it stops (DEPLOY-7). A server
  started by hand in a shell can't be, so the Settings page says so instead of
  stopping it for good.
  """
  @spec restartable?() :: :ok | {:error, binary()}
  def restartable? do
    if hot_reload_available?() do
      :ok
    else
      {:error,
       "Restarting is only available when the server runs, started by bin/serve " <>
         "(or a service manager) so it comes back."}
    end
  end

  @doc "Whether in-VM code reloading is available (the endpoint's code reloader, HOT-2, HOT-7)."
  def hot_reload_available? do
    Code.ensure_loaded?(Mix) and
      Application.get_env(:elia, EliaWeb.Endpoint)[:code_reloader] == true
  end

  @doc """
  Which supervised processes a reload could not change (HOT-10): what the loaded
  code asks for that the running server does not have, and what it runs that the
  code no longer asks for. A reload loads modules but cannot add a child to a
  tree that was built at boot (DEPLOY-6), so a difference here is a change only a
  restart makes (DEPLOY-7).
  """
  @spec changed_children([Supervisor.child_spec() | {module(), term()} | module()]) ::
          %{missing: [term()], extra: [term()]}
  def changed_children(asked \\ Elia.Application.children()) do
    wanted = Enum.map(asked, &child_id/1)

    running =
      for {id, _pid, _type, _modules} <- Supervisor.which_children(Elia.Supervisor), do: id

    %{missing: wanted -- running, extra: running -- wanted}
  end

  @doc """
  What a hot reload adds to its message when it could not change the tree
  (HOT-10): nothing at all when no child differs, since a reload that changed no
  supervised process needs no restart.
  """
  @spec restart_notice(map()) :: binary()
  def restart_notice(changes \\ changed_children())

  def restart_notice(%{missing: [], extra: []}), do: ""

  def restart_notice(%{missing: missing, extra: extra}) do
    lines =
      [
        missing != [] && "Not running: #{names(missing)}.",
        extra != [] && "Still running, though the code no longer asks for it: #{names(extra)}."
      ]
      |> Enum.reject(&(&1 == false))

    "\n\nA hot reload loads modules but cannot change the supervisor's children, so " <>
      "only a restart starts or stops:\n" <> Enum.join(lines, "\n")
  end

  # DEPLOY-5: merge, fetch dependencies, test in the live tree, and undo the
  # merge when either of those fails, so a failed deploy changes nothing.
  defp merge_and_test(count, root) do
    with {:ok, before} <- git(root, ["rev-parse", @live]),
         {:ok, _merged} <- merge(root) do
      case fetch_deps(root) do
        :ok -> test_merged(count, before, root)
        {:error, reason} -> {:error, fetch_failed(reason) <> rollback_note(before, root)}
      end
    end
  end

  defp test_merged(count, before, root) do
    # ISOL-14: the merged trunk's suite runs in the live tree, jailed by
    # default — no chat's setting is involved (ISOL-15), and the live tree's
    # `:live_tree` profile is what `Elia.Harness.run_tests/2` gets from the
    # working directory it runs in (ISOL-13).
    case Elia.Harness.run_tests([], root) do
      {:ok, _output} ->
        {:ok, "#{commits(count)} merged into #{@live}."}

      {:error, output} ->
        {:tests_failed, output <> rollback_note(before, root)}
    end
  end

  # DEPLOY-18: a dependency a chat added lives in that chat's own dependency
  # layer (ISOL-7), which the live tree never sees, so the merged trunk's
  # `mix.lock` is fetched here before its suite runs. In the live tree, whose own
  # `deps` is writable under the `:live_tree` profile (ISOL-13, ISOL-14); a lock
  # that is already satisfied fetches nothing.
  defp fetch_deps(root) do
    case Elia.Shell.run("mix deps.get", cd: root, timeout: @deps_timeout) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        {:error, "mix deps.get exited with #{status}:\n" <> Elia.Shell.truncate(output, 2_000)}

      {:timeout, output} ->
        {:error, "mix deps.get timed out:\n" <> Elia.Shell.truncate(output, 2_000)}
    end
  end

  defp fetch_failed(reason) do
    "Could not fetch the trunk's dependencies (DEPLOY-18):\n" <> reason
  end

  defp commits(1), do: "1 commit from #{@trunk}"
  defp commits(count), do: "#{count} commits from #{@trunk}"

  # HOT-4: the merge is undone when the tests fail, so `live` and the live tree
  # are left exactly as they were.
  defp rollback_note(sha, root) do
    case git(root, ["reset", "--hard", sha]) do
      {:ok, _output} ->
        ""

      {:error, reason} ->
        "\n\nThe tests failed and #{@live} could not be rolled back to " <>
          "#{String.slice(sha, 0, 12)}: #{reason}"
    end
  end

  # A deploy merges into the live tree and rolls back with `git reset --hard`
  # when the tests fail (DEPLOY-5), so it refuses a tree with uncommitted changes
  # rather than touching them.
  defp clean?(root) do
    case git(root, ["status", "--porcelain"]) do
      {:ok, ""} ->
        :ok

      {:ok, _changes} ->
        {:error,
         "The live tree has uncommitted changes: commit or discard them before deploying."}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # HOT-5: recompile the live tree and load the changed modules. Loading is a
  # function so tests can replace it (`config :elia, Elia.Deploy, load: fun`):
  # a real recompile inside a test run would rebuild Elia's own endpoint.
  defp load(deployed, root) do
    case loader().(EliaWeb.Endpoint) do
      :ok ->
        Elia.Skills.reload()
        # DEPLOY-17: what the app runs now, so a merge that never loads shows.
        record_loaded(root)
        {:ok, "#{deployed} Recompiled and reloaded the running app.#{restart_notice()}"}

      {:error, output} ->
        {:error, "Compilation failed:\n" <> Elia.Shell.truncate(output, 20_000)}
    end
  end

  defp loader do
    Application.get_env(:elia, __MODULE__, [])[:load] || (&Phoenix.CodeReloader.reload/1)
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

  # HOT-10: a child's id, derived the way the supervisor itself derives it, so
  # the loaded code's list and the running tree are compared the same way.
  defp child_id(child), do: Supervisor.child_spec(child, []).id

  defp names(ids), do: Enum.map_join(ids, ", ", &inspect/1)

  ## Git

  defp on_branch?(branch, root) do
    match?({:ok, ^branch}, git(root, ["symbolic-ref", "--short", "--quiet", "HEAD"]))
  end

  defp branch_exists?(branch, root) do
    match?({:ok, _}, git(root, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp ancestor?(branch, other, root) do
    match?({:ok, _}, git(root, ["merge-base", "--is-ancestor", branch, other]))
  end

  # Every git call the harness makes goes through `Elia.Shell.run/2` (ISOL-1):
  # jailed by default, with the environment rebuilt from the allowlist (ISOL-8)
  # rather than the full server environment `System.cmd/3` inherited. The
  # working directory, the arguments and the reading of the exit status and
  # output are as they were. A run whose jail was skipped says so above git's
  # own output (ISOL-12), which is what `strip_notice/1` takes off.
  defp git(root, args, opts \\ []) do
    command = "git " <> Enum.map_join(args, " ", &quote_arg/1)
    opts = Keyword.merge([cd: root, timeout: :timer.minutes(2)], opts)

    case Elia.Shell.run(command, opts) do
      {:ok, output, 0} -> {:ok, out(output)}
      {:ok, output, _status} -> {:error, out(output)}
      {:timeout, output} -> {:error, "timed out: #{out(output)}"}
    end
  rescue
    e -> {:error, "could not run git: #{Exception.message(e)}"}
  end

  defp out(output) do
    output
    |> String.replace_leading(Elia.Shell.jail_skipped_notice() <> "\n", "")
    |> String.trim()
  end

  # git's arguments go through a shell (SHELL-2), so each is quoted: a path with
  # a space, or a quote, still reaches git as one argument.
  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
