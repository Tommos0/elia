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
  fast-forwards `live` to the trunk when the tests pass (DEPLOY-5), makes the
  tree's front end current — the Node packages and the bundle a browser loads
  (DEPLOY-19) — on every deploy, merge or not (DEPLOY-20) — and loads the result
  into the running app, by hot reload
  (`hot_reload/1`, DEPLOY-6) or by restarting the server (`restart/1`,
  DEPLOY-7). Because the tree a chat edits is
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

  # How long installing the trunk's Node packages and building the live tree's
  # assets may take (DEPLOY-19): the same network and the same tree again, and a
  # first `npm install` on a cold cache is the slow one.
  @front_end_timeout :timer.minutes(10)

  # The bundle the browser loads, checked after the build (DEPLOY-24): the two
  # entry points the endpoint serves.
  @bundle ~w(priv/static/assets/js/app.js priv/static/assets/css/app.css)

  # The steps a deploy or a rollback takes (DEPLOY-21): the order a deploy takes
  # them is the order they are reported in, and what the record can hold. A
  # rollback takes the reset and then the front end and the load (DEPLOY-26).
  @steps [:merge, :deps, :tests, :packages, :assets, :reset, :load, :restart]

  # How much of a step's failure and of an operation's result the record keeps
  # (DEPLOY-23): a page renders them, so a whole test suite's output does not
  # belong in a file read on every mount.
  @record_text 20_000

  # How many revisions the record keeps (DEPLOY-25): a few, so a revision the
  # app has run and no longer is can still be named and gone back to.
  @keep_revisions 10

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
  loaded (DEPLOY-6), one a rollback went back to (DEPLOY-26), or one a restart
  is about to come up on (DEPLOY-7). The server's first start in the live tree
  counts too — it runs what the tree has checked out — so `Elia.Deploy.Runner`
  records that at boot. A tree that isn't set up for deployment (DEPLOY-14) is
  left alone, and failing to record is never a deploy failure.
  """
  @spec record_loaded(binary(), :deploy | :rollback, :reload | :restart) :: :ok
  def record_loaded(root \\ Workspace.runtime_root(), by \\ :deploy, mode \\ :reload) do
    with :ok <- deployable(root),
         {:ok, sha} <- git(root, ["rev-parse", @live]) do
      File.mkdir_p(Workspace.data_dir(root))
      File.write(loaded_path(root), sha <> "\n")
      # DEPLOY-25: the record keeps the revisions the app has run, so one it has
      # run and no longer is can still be named and gone back to (DEPLOY-26).
      record_revision(root, sha, by, mode)
    end

    :ok
  end

  ## What a deploy is doing, and what it did (DEPLOY-21 to DEPLOY-25)

  @doc """
  A short human label for a step of a deploy or of a rollback (DEPLOY-21).

  The two pages that render the steps — the Settings section (CONF-21) and the
  recovery page (RECOVER-11) — take their wording from here, so they cannot
  disagree about it.
  """
  @spec step_label(atom()) :: binary()
  def step_label(:merge), do: "Merging the trunk into the live tree"
  def step_label(:deps), do: "Fetching the trunk's dependencies in the live tree"
  def step_label(:tests), do: "Running the tests in the live tree"
  def step_label(:packages), do: "Installing the live tree's Node packages"
  def step_label(:assets), do: "Building the live tree's assets"
  def step_label(:reset), do: "Moving the live tree back to that revision"
  def step_label(:load), do: "Hot reloading the running app"
  def step_label(:restart), do: "Restarting the server"
  def step_label(step), do: to_string(step)

  @doc "Where the record of what a deploy is doing and has done is kept (DEPLOY-23)."
  @spec record_path(binary()) :: binary()
  def record_path(root \\ Workspace.runtime_root()),
    do: Path.join(Workspace.data_dir(root), "deploy.json")

  @doc """
  The last operation, from the record (DEPLOY-23): the deploy or rollback in
  flight, or the last one that ended.

  `%{kind: :deploy | :rollback, mode: :reload | :restart, sha: binary | nil,
  started: DateTime.t(), finished: DateTime.t() | nil, step: atom | nil,
  steps: [%{step: atom, ms: non_neg_integer | nil, status: :ok | {:failed,
  binary}}], result: term | nil}`, and `nil` when there is no record at all.

  `finished` and `result` are `nil` for an operation that never ended — the VM
  died under it, which is what a restart deploy leaves behind (DEPLOY-23,
  CONF-22) — and `step` is the step it is on now (DEPLOY-21). A record that
  cannot be read reads as `nil` rather than crashing a page.
  """
  @spec last_deploy(binary()) :: map() | nil
  def last_deploy(root \\ Workspace.runtime_root()) do
    case read_file(root) do
      {:ok, %{running: running}} when is_map(running) -> running
      {:ok, %{last: last}} when is_map(last) -> last
      _ -> nil
    end
  end

  @doc """
  The revisions the app has run (DEPLOY-25), newest first: `%{sha, at, by, mode}`
  for each — when it was loaded, and by a deploy or a rollback, hot reloaded or
  restarted. The newest is the revision `loaded_revision/1` and `status/1`
  report (DEPLOY-17).

  A tree that has only the loaded-revision file and no record reports that one
  revision, so a tree deployed before the record existed still has a rollback
  target (DEPLOY-26); a record that cannot be read reports nothing, and nothing
  crashes a page that renders it.
  """
  @spec loaded_revisions(binary()) :: [map()]
  def loaded_revisions(root \\ Workspace.runtime_root()) do
    case read_file(root) do
      {:ok, %{loaded: [_ | _] = loaded}} -> loaded
      {:ok, _record} -> from_deployed(root)
      :missing -> from_deployed(root)
      :corrupt -> []
    end
  end

  # The upgrade path (DEPLOY-25): a tree deployed before the record existed has
  # the revision the app runs in `.elia/deployed` and nothing else.
  defp from_deployed(root) do
    case loaded_revision(root) do
      nil -> []
      sha -> [%{sha: sha, at: loaded_at(root), by: :deploy, mode: :reload}]
    end
  end

  # When that revision was loaded is not recorded; the file's own time is the
  # closest thing to it, and a file that has none reads as just now.
  defp loaded_at(root) do
    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(loaded_path(root), time: :posix),
         {:ok, at} <- DateTime.from_unix(mtime) do
      at
    else
      _ -> DateTime.utc_now()
    end
  end

  @doc false
  # The record as it is on disk, or an empty one. What the runner seeds itself
  # from (DEPLOY-22, DEPLOY-23) and what the readers answer from.
  @spec read_record(binary()) :: %{running: map() | nil, last: map() | nil, loaded: [map()]}
  def read_record(root \\ Workspace.runtime_root()) do
    case read_file(root) do
      {:ok, record} -> record
      _ -> %{running: nil, last: nil, loaded: []}
    end
  end

  defp read_file(root) do
    case File.read(record_path(root)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, record} when is_map(record) -> {:ok, decode_record(record)}
          _ -> :corrupt
        end

      {:error, _reason} ->
        :missing
    end
  end

  @doc false
  # Writes the record (DEPLOY-23). The runner is its only writer, so what a page
  # reads back is what the runner holds: the operation in flight, the last one,
  # and the revisions the app has run (DEPLOY-25). A record that cannot be
  # written is never a deploy failure — the page that reads it is one that
  # already lost the process that made it.
  @spec write_record(binary(), map()) :: :ok
  def write_record(root, record) do
    if File.dir?(root) do
      path = record_path(root)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(encode_record(record), pretty: true))
    end

    :ok
  rescue
    e -> Logger.warning("Could not write the deploy record: #{Exception.message(e)}")
  end

  @doc false
  # Adds a revision to the ones the app has run (DEPLOY-25): newest first, the
  # same revision not twice, and only the last few kept.
  @spec append_revision([map()], map()) :: [map()]
  def append_revision(loaded, revision) do
    [revision | Enum.reject(loaded, &(&1.sha == revision.sha))] |> Enum.take(@keep_revisions)
  end

  # The record's shape on disk. Everything a page reads comes back through
  # `last_deploy/1` and `loaded_revisions/1`, so the encoding is the module's
  # own business.
  defp encode_record(record) do
    %{
      "running" => encode_operation(record.running),
      "last" => encode_operation(record.last),
      "loaded" => Enum.map(record.loaded, &encode_revision/1)
    }
  end

  defp encode_operation(nil), do: nil

  defp encode_operation(operation) do
    %{
      "kind" => to_string(operation.kind),
      "mode" => to_string(operation.mode),
      "sha" => operation.sha,
      "started" => DateTime.to_iso8601(operation.started),
      "finished" => operation.finished && DateTime.to_iso8601(operation.finished),
      "step" => operation.step && to_string(operation.step),
      "steps" => Enum.map(operation.steps, &encode_step/1),
      "result" => encode_result(operation.result)
    }
  end

  defp encode_step(%{step: step, ms: ms, status: status}) do
    %{"step" => to_string(step), "ms" => ms, "status" => encode_status(status)}
  end

  defp encode_status(:ok), do: "ok"
  defp encode_status({:failed, reason}), do: %{"failed" => text(reason)}
  defp encode_status(nil), do: nil

  defp encode_result(nil), do: nil
  defp encode_result({:ok, message}), do: %{"ok" => text(message)}
  defp encode_result({:tests_failed, output}), do: %{"tests_failed" => text(output)}
  defp encode_result({:error, reason}), do: %{"error" => text(reason)}
  defp encode_result({:exit, reason}), do: %{"exit" => text(reason)}
  defp encode_result(other), do: %{"other" => inspect(other)}

  defp encode_revision(%{sha: sha, at: at, by: by, mode: mode}) do
    %{
      "sha" => sha,
      "at" => DateTime.to_iso8601(at),
      "by" => to_string(by),
      "mode" => to_string(mode)
    }
  end

  # A message the record keeps: a page renders it, so it is cut to size the way
  # a command's output is (SHELL-4).
  defp text(value) when is_binary(value), do: Elia.Shell.truncate(value, @record_text)
  defp text(value), do: value |> inspect() |> Elia.Shell.truncate(@record_text)

  defp decode_record(record) do
    %{
      running: decode_operation(record["running"]),
      last: decode_operation(record["last"]),
      loaded: decode_revisions(record["loaded"])
    }
  end

  defp decode_operation(operation) when is_map(operation) do
    %{
      kind: name(operation["kind"], [:deploy, :rollback], :deploy),
      mode: name(operation["mode"], [:reload, :restart], :reload),
      sha: operation["sha"],
      started: datetime(operation["started"]),
      finished: datetime(operation["finished"]),
      step: name(operation["step"], @steps, nil),
      steps: decode_steps(operation["steps"]),
      result: decode_result(operation["result"])
    }
  end

  defp decode_operation(_other), do: nil

  defp decode_steps(steps) when is_list(steps), do: Enum.flat_map(steps, &decode_step/1)
  defp decode_steps(_other), do: []

  defp decode_step(%{"step" => step} = entry) when is_binary(step) do
    case name(step, @steps, nil) do
      nil -> []
      step -> [%{step: step, ms: entry["ms"], status: decode_status(entry["status"])}]
    end
  end

  defp decode_step(_other), do: []

  defp decode_status("ok"), do: :ok
  defp decode_status(%{"failed" => reason}), do: {:failed, reason}
  defp decode_status(_other), do: nil

  defp decode_result(%{"ok" => message}), do: {:ok, message}
  defp decode_result(%{"tests_failed" => output}), do: {:tests_failed, output}
  defp decode_result(%{"error" => reason}), do: {:error, reason}
  defp decode_result(%{"exit" => reason}), do: {:exit, reason}
  defp decode_result(%{"other" => other}), do: other
  defp decode_result(_other), do: nil

  defp decode_revisions(revisions) when is_list(revisions),
    do: Enum.flat_map(revisions, &decode_revision/1)

  defp decode_revisions(_other), do: []

  defp decode_revision(%{"sha" => sha, "at" => at} = revision) when is_binary(sha) do
    case datetime(at) do
      nil ->
        []

      at ->
        [
          %{
            sha: sha,
            at: at,
            by: name(revision["by"], [:deploy, :rollback], :deploy),
            mode: name(revision["mode"], [:reload, :restart], :reload)
          }
        ]
    end
  end

  defp decode_revision(_other), do: []

  # A name the record wrote: the atom it stands for, never a new atom made from
  # a file's contents (DEPLOY-23).
  defp name(value, known, default) when is_binary(value),
    do: Enum.find(known, default, &(to_string(&1) == value))

  defp name(_value, _known, default), do: default

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  # DEPLOY-25: the revision the app has loaded, kept in the record. The runner
  # is the record's only writer (DEPLOY-23), so this goes through it — the
  # operation process is the runner's own child, and the call is done before a
  # restart stops the server (DEPLOY-17).
  defp record_revision(root, sha, by, mode) do
    revision = %{sha: sha, at: DateTime.utc_now(), by: by, mode: mode}

    case Process.whereis(Elia.Deploy.Runner) do
      nil ->
        record = read_record(root)
        write_record(root, %{record | loaded: append_revision(loaded_revisions(root), revision)})

      _pid ->
        Elia.Deploy.Runner.loaded(root, sha, by, mode)
    end
  end

  ## A step of an operation (DEPLOY-21)

  # Runs one step of an operation, reporting when it started and when it ended,
  # how long it took and whether it succeeded (DEPLOY-21), and returns what the
  # step returned: `{:ok, _}`, `{:tests_failed, output}` or `{:error, reason}`,
  # which is what the operation does next.
  defp step(name, root, fun) do
    report(root, name, :started, nil, nil)
    started = System.monotonic_time(:millisecond)
    outcome = fun.()
    ms = System.monotonic_time(:millisecond) - started
    report(root, name, :finished, ms, step_status(outcome))
    outcome
  end

  defp step_status({:ok, _value}), do: :ok
  defp step_status({:tests_failed, output}), do: {:failed, text(output)}
  defp step_status({:error, reason}), do: {:failed, text(reason)}

  # DEPLOY-22: a step belongs to the runner, which holds it and tells the pages
  # (CONF-21, RECOVER-12). An operation run outside the runner — a test calling
  # `deploy/1` — has no operation to report to, and the runner ignores a report
  # that is not its own operation's.
  defp report(root, step, phase, ms, status) do
    case Process.whereis(Elia.Deploy.Runner) do
      nil -> :ok
      _pid -> Elia.Deploy.Runner.step(root, step, phase, ms, status)
    end
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
        seed_build(path, root)
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

  # BUILD-1: a fresh worktree has no build output of its own either, so its
  # first compile would build every dependency from source — 29 s of a 35 s cold
  # `mix compile`, and 28 s of 33 s under `MIX_ENV=test`, measured. Seed it with
  # a copy of the live tree's: a dependency's sources are the same files at the
  # same path in both trees (ISOL-7), so Mix finds its artifacts current in the
  # worktree and skips them (BUILD-4), while the worktree's own modules are
  # always compiled from the worktree's own sources. A copy and not a compile
  # (BUILD-3), taken once, with the worktree (BUILD-1) — and the worktree's own,
  # so a deploy rewriting the live tree's `_build` while a command reads the
  # worktree's cannot be read through it, and no chat's compile writes the
  # artifacts the server runs from (BUILD-2). A copy that fails leaves the
  # worktree usable, with no build output, as it was before (BUILD-5).
  defp seed_build(path, root) do
    build = Path.join(root, "_build")
    target = Path.join(path, "_build")

    if File.dir?(build) and not File.exists?(target) do
      command = "cp -a #{quote_arg(build)} #{quote_arg(target)}"

      # The harness's own step in the live tree, the same profile the worktree's
      # `git worktree add` runs with (ISOL-13): the tree is bound as it is, so
      # the worktree inside it is writable too.
      case Elia.Shell.run(command, cd: root, profile: :deps_sync, timeout: :timer.minutes(2)) do
        {:ok, _output, 0} ->
          :ok

        other ->
          Logger.debug("could not seed #{target}: #{Elia.Shell.truncate(inspect(other), 500)}")
      end
    end

    :ok
  rescue
    e -> Logger.debug("could not seed #{path}/_build: #{Exception.message(e)}")
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
  merge when `live` is already at the trunk: no tests run, but the tree's front
  end is still made current before the load (DEPLOY-20), and the message says so.
  """
  @spec deploy(binary()) :: {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def deploy(root \\ Workspace.runtime_root()) do
    with :ok <- deployable(root),
         :ok <- clean?(root),
         {:ok, %{pending: pending}} <- status(root) do
      case pending do
        0 -> nothing_to_merge(root)
        _ -> merge_and_test(pending, root)
      end
    end
  end

  # DEPLOY-5, DEPLOY-20: the trunk is already deployed, so there is nothing to
  # merge and no suite to run — but the tree's front end is still made current
  # before the load. What a deploy loads is then always what the tree it loads
  # builds: a bundle that is missing or stale for any other reason (the live
  # tree never installed a Node package a chat added, so its own watchers can't
  # build one) is repaired by deploying, rather than only by a deploy that
  # happens to have something to merge. A front end that can't be built fails
  # the deploy as it does after a merge: nothing is loaded.
  defp nothing_to_merge(root) do
    nothing = "Nothing to deploy: #{@live} is already #{@trunk}."

    case front_end(root) do
      {:ok, note} -> {:ok, nothing <> note}
      {:error, reason} -> {:error, front_end_failed(reason)}
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
  def hot_reload(root \\ Workspace.runtime_root()), do: deploy_and_load(root, :deploy)

  # Both modes report the load as the operation's last step (DEPLOY-21): `:load`
  # for the hot reload, `:restart` for the restart.
  defp deploy_and_load(root, by) do
    if hot_reload_available?() do
      case deploy(root) do
        {:ok, deployed} -> load(deployed, root, by)
        other -> other
      end
    else
      {:error, hot_reload_unavailable()}
    end
  end

  defp hot_reload_unavailable do
    "Hot reload is only available when the endpoint's code reloader is on " <>
      "(`code_reloader: true`)."
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
        {:ok, deployed} -> stop_for(deployed, root, :deploy)
        other -> other
      end
    end
  end

  # DEPLOY-7: the server stops, and `bin/serve` starts it again on the tree it
  # left. DEPLOY-17 records the revision it comes back on before it stops, and
  # DEPLOY-23's record is written the same way, so the page that comes up
  # afterwards says what the deploy did — the step is never reported as
  # finished, because the VM this process runs in is gone.
  defp stop_for(prefix, root, by) do
    message =
      if by == :rollback,
        do: "Restarting the server on the code it went back to.",
        else: "Restarting the server on the deployed code."

    case step(:restart, root, fn -> stopping(root, by, message) end) do
      {:ok, note} -> {:ok, "#{prefix} #{note}"}
      other -> other
    end
  end

  defp stopping(root, by, message) do
    record_loaded(root, by, :restart)
    stop()
    {:ok, message}
  end

  @doc """
  Goes back to a revision the app has run (DEPLOY-26): a load, not a merge.

  `live` is moved to `sha` — a `git reset --hard`, since a deploy only ever
  fast-forwards forward (DEPLOY-5) — that revision's front end is made current
  (DEPLOY-19) and checked (DEPLOY-24), and it is loaded the way a deploy is:
  hot reloaded (DEPLOY-6) or restarted (DEPLOY-7), recorded as loaded by a
  rollback (DEPLOY-17, DEPLOY-25). Its steps are reported like a deploy's
  (DEPLOY-21) and what it did is recorded (DEPLOY-23).

  Refused, changing nothing, when the live tree isn't set up for deployment
  (DEPLOY-14), has uncommitted changes, `sha` is not one the app has run
  (DEPLOY-25), or is the revision it is running now. A rollback that fails
  after it has moved `live` — a front end it cannot build (DEPLOY-24) — puts
  `live` back where it was and loads nothing. Returns what `deploy/1` does.
  """
  @spec rollback(binary(), :reload | :restart, binary()) ::
          {:ok, binary()} | {:error, binary()}
  def rollback(sha, mode, root \\ Workspace.runtime_root())

  def rollback(sha, mode, root) when mode in [:reload, :restart] do
    with :ok <- deployable(root),
         :ok <- clean?(root),
         {:ok, sha} <- ran?(sha, root),
         :ok <- not_running?(sha, root),
         :ok <- mode_available?(mode),
         {:ok, before} <- git(root, ["rev-parse", @live]) do
      case step(:reset, root, fn -> reset_to(sha, root) end) do
        {:ok, _note} -> after_reset(sha, mode, before, root)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A rollback only goes back to a revision the app has run (DEPLOY-25), and the
  # record is what says which those are (DEPLOY-23).
  defp ran?(sha, root) do
    case Enum.find(loaded_revisions(root), &same_revision?(&1.sha, sha)) do
      nil ->
        {:error,
         "The app has not run #{short(sha)}, so there is nothing to go back to: " <>
           "a rollback loads a revision it has loaded before (DEPLOY-25)."}

      %{sha: full} ->
        {:ok, full}
    end
  end

  defp same_revision?(full, sha),
    do: full == sha or (sha != "" and String.starts_with?(full, sha))

  defp not_running?(sha, root) do
    if running_revision(root) == sha do
      {:error,
       "The app is running #{short(sha)} already: there is nothing to go back to (DEPLOY-26)."}
    else
      :ok
    end
  end

  # DEPLOY-17: the revision the app runs, as `status/1` reports it; the record's
  # newest is the same revision when the loaded-revision file is missing.
  defp running_revision(root) do
    loaded_revision(root) ||
      case loaded_revisions(root) do
        [%{sha: sha} | _] -> sha
        [] -> nil
      end
  end

  defp mode_available?(:restart), do: restartable?()

  defp mode_available?(:reload) do
    if hot_reload_available?(), do: :ok, else: {:error, hot_reload_unavailable()}
  end

  defp reset_to(sha, root) do
    case git(root, ["reset", "--hard", sha]) do
      {:ok, _output} ->
        {:ok, "#{@live} is at #{short(sha)} again."}

      {:error, reason} ->
        {:error, "Could not move #{@live} back to #{short(sha)} (DEPLOY-26):\n#{reason}"}
    end
  end

  defp after_reset(sha, mode, before, root) do
    case front_end(root) do
      {:ok, note} -> go_back(sha, mode, root, note)
      # DEPLOY-26: a rollback that fails once `live` has moved leaves the tree
      # the app is running — nothing is loaded from a revision whose front end
      # it could not make current (DEPLOY-24).
      {:error, reason} -> {:error, front_end_failed(reason) <> rollback_note(before, root)}
    end
  end

  defp go_back(sha, :reload, root, note) do
    case step(:load, root, fn -> reload_now(root, :rollback) end) do
      {:ok, message} -> {:ok, "#{went_back(sha)}#{note} #{message}"}
      other -> other
    end
  end

  defp go_back(sha, :restart, root, note), do: stop_for(went_back(sha) <> note, root, :rollback)

  defp went_back(sha), do: "Rolled #{@live} back to #{short(sha)}."

  defp short(sha), do: String.slice(sha, 0, 7)

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
  # merge when either of those fails, so a failed deploy changes nothing. Each
  # of those is a step the deploy reports (DEPLOY-21), and a step it never
  # reaches is never reported.
  defp merge_and_test(count, root) do
    with {:ok, before} <- git(root, ["rev-parse", @live]) do
      case step(:merge, root, fn -> merge(root) end) do
        {:ok, _merged} -> deps_and_test(count, before, root)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp deps_and_test(count, before, root) do
    case step(:deps, root, fn -> fetch_deps(root) end) do
      {:ok, _output} -> test_merged(count, before, root)
      {:error, reason} -> {:error, fetch_failed(reason) <> rollback_note(before, root)}
    end
  end

  defp test_merged(count, before, root) do
    case step(:tests, root, fn -> run_suite(root) end) do
      {:ok, _output} ->
        # DEPLOY-19: the tree is deployed, so what a browser loads from it is
        # made current before anything loads the tree itself.
        case front_end(root) do
          {:ok, note} ->
            {:ok, "#{commits(count)} merged into #{@live}.#{note}"}

          {:error, reason} ->
            {:error, front_end_failed(reason) <> rollback_note(before, root)}
        end

      {:tests_failed, output} ->
        {:tests_failed, output <> rollback_note(before, root)}

      {:error, reason} ->
        {:error, reason <> rollback_note(before, root)}
    end
  end

  # ISOL-14: the merged trunk's suite runs in the live tree, jailed by default —
  # no chat's setting is involved (ISOL-15), and the live tree's `:live_tree`
  # profile is what `Elia.Harness.run_tests/2` gets from the working directory
  # it runs in (ISOL-13).
  defp run_suite(root) do
    case Elia.Harness.run_tests([], root) do
      {:ok, output} -> {:ok, output}
      {:error, output} -> {:tests_failed, output}
    end
  end

  # DEPLOY-18: a dependency a chat added lives in that chat's own dependency
  # layer (ISOL-7), which the live tree never sees, so the merged trunk's
  # `mix.lock` is fetched here before its suite runs. In the live tree, whose own
  # `deps` is writable under the `:live_tree` profile (ISOL-13, ISOL-14); a lock
  # that is already satisfied fetches nothing.
  defp fetch_deps(root) do
    case Elia.Shell.run("mix deps.get", cd: root, timeout: @deps_timeout) do
      {:ok, output, 0} ->
        {:ok, output}

      {:ok, output, status} ->
        {:error, "mix deps.get exited with #{status}:\n" <> Elia.Shell.truncate(output, 2_000)}

      {:timeout, output} ->
        {:error, "mix deps.get timed out:\n" <> Elia.Shell.truncate(output, 2_000)}
    end
  end

  defp fetch_failed(reason) do
    "Could not fetch the trunk's dependencies (DEPLOY-18):\n" <> reason
  end

  # DEPLOY-19: the front end the tree will serve, made current before it is
  # loaded. `{:ok, note}` — the note is what the deploy's message adds, and is
  # empty for a tree with no front end — or `{:error, reason}`.
  #
  # The two things it does are the operation's `:packages` and `:assets` steps
  # (DEPLOY-21). A test replaces the whole step (`config :elia, Elia.Deploy,
  # front_end: fun`), the way it replaces `load:` and `stop:`, or either of the
  # two steps on its own (`packages: fun`, `assets: fun`).
  defp front_end(root) do
    case Application.get_env(:elia, __MODULE__, [])[:front_end] do
      # A replaced step is not reported as a step of its own: the steps a
      # deploy reports are the ones the code takes (DEPLOY-21).
      nil -> build_front_end(root)
      front_end -> front_end.(root)
    end
  end

  # A tree with no `assets/` is not a project with a front end — a test's
  # throwaway live tree, say — and there is nothing to install or build for one,
  # and so nothing to check (DEPLOY-24).
  defp build_front_end(root) do
    if File.exists?(Path.join(root, "assets/package.json")) do
      with {:ok, _packages} <-
             step(:packages, root, fn -> seam(:packages, &install/1).(root) end),
           {:ok, _assets} <- step(:assets, root, fn -> seam(:assets, &build/1).(root) end) do
        # DEPLOY-24: after the build, and inside the step that builds.
        case bundle?(root) do
          :ok -> {:ok, " The live tree's front end was rebuilt."}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:ok, ""}
    end
  end

  defp seam(name, default), do: Application.get_env(:elia, __MODULE__, [])[name] || default

  # DEPLOY-24: the bundle the browser loads, checked after the build. A build
  # that exits 0 having written nothing — a wiped `priv/static`, a misconfigured
  # `esbuild` or `tailwind` — is a failed deploy rather than a running app with
  # no stylesheet or no hook.
  defp bundle?(root) do
    case Enum.find(@bundle, &missing?(Path.join(root, &1))) do
      nil -> :ok
      file -> {:error, "The build left no bundle: #{file} is missing or empty (DEPLOY-24)."}
    end
  end

  defp missing?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size == 0
      {:error, _reason} -> true
    end
  end

  # DEPLOY-19: a Node package a chat added lives in that chat's own dependency
  # layer (ISOL-7), which the live tree has never installed — and without it the
  # tree can't build a bundle at all, since the build is what resolves the
  # import. Run from the live tree's own directory, so it gets the live tree's
  # profile (ISOL-13, ISOL-14) the way the fetch above does.
  defp install(root) do
    run_step(root, "npm install --prefix assets --no-audit --no-fund")
  end

  # The build the live tree's own watchers run while the server is up (HOT-7),
  # here by hand and before anything loads the tree: what writes `priv/static`,
  # and so what makes the browser's live reload fire (DEPLOY-12).
  defp build(root), do: run_step(root, "mix assets.build")

  defp run_step(root, command) do
    case Elia.Shell.run(command, cd: root, timeout: @front_end_timeout) do
      {:ok, output, 0} ->
        {:ok, output}

      {:ok, output, status} ->
        {:error, "#{command} exited with #{status}:\n" <> Elia.Shell.truncate(output, 2_000)}

      {:timeout, output} ->
        {:error, "#{command} timed out:\n" <> Elia.Shell.truncate(output, 2_000)}
    end
  end

  defp front_end_failed(reason) do
    "Could not build the live tree's front end (DEPLOY-19):\n" <> reason
  end

  defp commits(1), do: "1 commit from #{@trunk}"
  defp commits(count), do: "#{count} commits from #{@trunk}"

  # HOT-4, DEPLOY-26: the operation's move of `live` is undone when a later step
  # fails, so the live tree and its branch are left exactly as they were.
  defp rollback_note(sha, root) do
    case git(root, ["reset", "--hard", sha]) do
      {:ok, _output} ->
        ""

      {:error, reason} ->
        "\n\n#{@live} could not be put back to #{short(sha)}: #{reason}"
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

  # HOT-5, DEPLOY-26: recompile the live tree and load the changed modules, as
  # the operation's `:load` step (DEPLOY-21). Loading is a function so tests can
  # replace it (`config :elia, Elia.Deploy, load: fun`): a real recompile inside
  # a test run would rebuild Elia's own endpoint.
  defp load(deployed, root, by) do
    case step(:load, root, fn -> reload_now(root, by) end) do
      {:ok, note} -> {:ok, "#{deployed} #{note}"}
      other -> other
    end
  end

  defp reload_now(root, by) do
    case loader().(EliaWeb.Endpoint) do
      :ok ->
        Elia.Skills.reload()
        # DEPLOY-17: what the app runs now, so a merge that never loads shows;
        # DEPLOY-25: and it is one of the revisions the app has run.
        record_loaded(root, by, :reload)
        {:ok, "Recompiled and reloaded the running app.#{restart_notice()}"}

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
    |> Elia.Shell.strip_notices()
    |> String.trim()
  end

  # git's arguments go through a shell (SHELL-2), so each is quoted: a path with
  # a space, or a quote, still reaches git as one argument.
  defp quote_arg(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"
end
