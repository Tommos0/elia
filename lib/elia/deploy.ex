defmodule Elia.Deploy do
  @moduledoc """
  Deploying Elia's own code into the running app (spec: `specs/deployment.md`).

  Elia's own project runs from the *live tree* (`Elia.Workspace.runtime_root/0`):
  that is where the server runs, where the code reloader reloads, and where
  Elia's data lives (DEPLOY-2). Two branches of its repository matter: the
  *trunk* `master`, the chats' fork point and the branch their work is merged
  into (DEPLOY-13), and `live`, the branch the live tree is checked out on and a
  deploy's target (DEPLOY-14).

  A chat in that project works in the project's folder, which is the live tree
  itself (DEPLOY-1, PROJ-12). The harness creates no worktree and no branch for
  a chat: before a chat changes code it makes itself a git worktree inside that
  folder, on branch `chat/<chat id>`, forked from the trunk (DEPLOY-28), so the
  tree it was given stays as it was and nothing half-done is in the tree that
  runs. When the work is done the chat's agent merges that branch into the trunk
  itself (`git push . HEAD:master`, which refuses anything but a fast-forward,
  DEPLOY-13), and removes the worktree and its branch once it is merged. A
  *deploy* is then the user's step, from the Settings page
  (`EliaWeb.SettingsLive`): it runs the full test suite in the live tree,
  fast-forwards `live` to the trunk when the tests pass (DEPLOY-5), makes the
  tree's front end current — the Node packages and the bundle a browser loads
  (DEPLOY-19) — on every deploy, merge or not (DEPLOY-20) — and loads the result
  into the running app, by hot reload
  (`hot_reload/1`, DEPLOY-6) or by restarting the server (`restart/1`,
  DEPLOY-7). No request ever reloads code (DEPLOY-8). A deploy can be asked to
  leave the live tree's suite out (DEPLOY-40), which is the checkbox the
  Settings page offers beside its deploy buttons (CONF-36).
  """

  require Logger

  alias Elia.Workspace

  @live "live"
  @trunk "master"

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

  # How long pushing a trunk to a remote may take (DEPLOY-42): the network
  # again, and a tree being sent over it.
  @push_timeout :timer.minutes(5)

  # How long a lock must sit untouched before it is one a killed git process
  # left rather than one a command is holding (DEPLOY-46): git holds a lock for
  # the length of one command, so a lock that is neither open nor this old is
  # one nothing is using.
  @stale_lock_seconds 60

  # The bundle the browser loads, checked after the build (DEPLOY-24): the two
  # entry points the endpoint serves, named as they are under the assets
  # directory — which is also what the build stages them as (DEPLOY-31).
  @bundle ~w(js/app.js css/app.css)

  # Where the bundle lives in a tree (DEPLOY-24), and where the build writes the
  # copy of it the deploy checks and promotes (DEPLOY-31): inside the assets
  # directory the tree ignores, so it is never over the files the endpoint serves
  # and a rejected deploy has nothing to undo (DEPLOY-32).
  @assets "priv/static/assets"
  @staging "priv/static/assets/.staging"

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

  ## Branches

  @doc "The branch the live tree is checked out on and a deploy fast-forwards (DEPLOY-5)."
  def live_branch, do: @live

  @doc "The trunk: the branch the chats fork from and merge into, and a deploy's target (DEPLOY-13)."
  def trunk_branch, do: @trunk

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
  records that at boot (DEPLOY-36). A tree that isn't set up for deployment
  (DEPLOY-14) is left alone, and failing to record is never a deploy failure.
  """
  @spec record_loaded(binary(), :deploy | :rollback, :reload | :restart) :: :ok
  def record_loaded(root \\ Workspace.runtime_root(), by \\ :deploy, mode \\ :reload),
    do: write_loaded(root, by, mode, :runner)

  @doc false
  # DEPLOY-36: the revision the server comes up on, which the runner records at
  # its own start. Every other load is written through the runner — the record's
  # only writer (DEPLOY-23), since the operation it belongs to is the runner's
  # own child — and this one cannot be: the process recording it *is* the
  # runner, which has not reached its loop yet, and a boot has no operation of
  # its own to keep in step. So it is written here, by the runner's own boot.
  #
  # A directory that is no git tree at all is left alone before git runs: it is
  # not a live tree anything could be deployed to (DEPLOY-14), and a server may
  # well come up with no tree yet — a test run's scratch workspace is made after
  # the application starts.
  @spec record_boot(binary()) :: :ok
  def record_boot(root \\ Workspace.runtime_root()) do
    if File.exists?(Path.join(root, ".git")),
      do: write_loaded(root, :deploy, :restart, :direct)

    :ok
  end

  # DEPLOY-17, DEPLOY-36: what the app is running, recorded where a page reads
  # it back — the loaded revision and the list the revisions are kept in.
  defp write_loaded(root, by, mode, route) do
    with :ok <- deployable(root),
         {:ok, sha} <- git(root, ["rev-parse", @live]) do
      File.mkdir_p(Workspace.data_dir(root))
      File.write(loaded_path(root), sha <> "\n")
      # DEPLOY-25: the record keeps the revisions the app has run, so one it has
      # run and no longer is can still be named and gone back to (DEPLOY-26).
      record_revision(root, sha, by, mode, route)
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

  ## What the last deploy brought (DEPLOY-27)

  @doc """
  What the revision the app runs has that the one it ran before it does not
  (DEPLOY-27): the changes the last deploy brought into the running app, which
  is what the dashboard's "What's new" card shows (DASH-14).

  `{:ok, %{commits: commits, at: at, before: before}}`, where `commits` is
  newest first — each `%{sha: full, short: abbreviated, subject: its first
  line}`, merge commits left out — `at` is when the running revision was
  loaded, and `before` is the abbreviated sha of the revision before it.

  The record (DEPLOY-23, DEPLOY-25) is what says which two revisions those are;
  the commits come from one `git log <before>..<now>` in the live tree, the way
  `status/1` answers from git (DEPLOY-17). `commits` is empty and `before` is
  `nil` when the record holds no earlier revision — a tree that has only the
  revision the server came up on — and `at` is `nil` when it holds none at all.
  `{:error, reason}` when that git call fails.
  """
  @spec changes(binary()) :: {:ok, map()} | {:error, binary()}
  def changes(root \\ Workspace.runtime_root()) do
    case loaded_revisions(root) do
      [] ->
        {:ok, %{commits: [], at: nil, before: nil}}

      [%{sha: sha, at: at} | rest] ->
        before =
          case rest do
            [%{sha: before} | _older] -> before
            [] -> nil
          end

        case commits_between(before, sha, root) do
          {:ok, commits} -> {:ok, %{commits: commits, at: at, before: before && short(before)}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  ## Pushing a project's trunk to a remote (DEPLOY-41 to DEPLOY-44)

  @doc """
  Pushes `master` to one of `root`'s remotes (DEPLOY-41).

  A push is no deploy: it merges nothing, runs no suite, loads nothing and is
  never rolled back. It is not an operation of the runner (`Elia.Deploy.Runner`)
  either, so it takes no step of a deploy and writes nothing to the record
  (DEPLOY-21, DEPLOY-23), and the folder it runs in is any project's — not only
  Elia's own (PROJ-56).

  The one command it runs is unjailed (DEPLOY-42): the user's credentials — a
  credential store, an SSH key, `~/.gitconfig` — are outside a command's jail on
  purpose (ISOL-5), so a jailed push could not authenticate. It is a fixed
  command whose only part of the caller's is the remote name, and it is told not
  to prompt, so a missing credential comes back as git's message rather than
  waiting on a terminal that is not there.

  `{:ok, message}` — git's own output, or that the remote already had the trunk
  — or `{:error, reason}` for a refusal: a non-fast-forward because the remote
  has commits the folder does not, a remote that is not there, a credential that
  did not work.
  """
  @spec push(binary(), binary()) :: {:ok, binary()} | {:error, binary()}
  def push(root, remote) do
    opts = [
      jail: false,
      timeout: @push_timeout,
      env: [{"GIT_TERMINAL_PROMPT", "0"}],
      max_output: @record_text
    ]

    case git(root, ["push", remote, @trunk], opts) do
      {:ok, output} -> {:ok, pushed(output, remote)}
      {:error, reason} -> {:error, "Could not push #{@trunk} to #{remote}.\n\n" <> reason}
    end
  end

  # DEPLOY-41: what the push did, as the page reports it. git answers "nothing
  # to send" in the same shape as it answers that it sent something, so the
  # up-to-date case is told apart rather than shown as a push that moved bytes.
  defp pushed(output, remote) do
    if output =~ "Everything up-to-date" do
      "#{remote} already had #{@trunk}: nothing to push."
    else
      "Pushed #{@trunk} to #{remote}.\n\n" <> output
    end
  end

  @doc """
  The remotes `root`'s repository has configured (DEPLOY-44), as `git remote`
  lists them — `{:ok, []}` for a repository with none — or `{:error, reason}`
  when git cannot answer, which a folder that is no git repository, and one that
  is gone (PROJ-27), both do.

  A project's page offers one push control per remote this names (PROJ-56), so a
  folder with none gets no button and is told what is missing instead (PROJ-57).
  """
  @spec remotes(binary()) :: {:ok, [binary()]} | {:error, binary()}
  def remotes(root) do
    case git(root, ["remote"]) do
      {:ok, ""} -> {:ok, []}
      {:ok, names} -> {:ok, String.split(names, "\n", trim: true)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  How `root`'s `master` stands against one of its remotes (DEPLOY-43): the
  commits on `master` that the folder's own `<remote>/master` remote-tracking
  ref does not have, `nil` when there is no such ref yet — nothing has been
  pushed to that remote from this folder — or `{:error, reason}` when the folder
  has no such remote to push to.

  It reads the ref the folder already holds and fetches nothing, so asking costs
  no network request; a push updates that ref (DEPLOY-41).
  """
  @spec pending(binary(), binary()) ::
          {:ok, %{pending: non_neg_integer() | nil}} | {:error, binary()}
  def pending(root, remote) do
    case git(root, ["remote", "get-url", remote]) do
      {:ok, _url} -> pending_commits(root, remote)
      {:error, _no_remote} -> {:error, no_remote(remote)}
    end
  end

  defp no_remote(remote) do
    "This project's folder has no #{remote} remote to push to: add one with " <>
      "`git remote add #{remote} <url>`."
  end

  # DEPLOY-43: a folder that has never pushed has no `<remote>/master` of its
  # own, and what a push would send is then the whole trunk.
  defp pending_commits(root, remote) do
    case git(root, ["rev-parse", "--verify", "--quiet", "refs/remotes/#{remote}/#{@trunk}"]) do
      {:ok, _sha} ->
        case git(root, ["rev-list", "--count", "#{remote}/#{@trunk}..#{@trunk}"]) do
          {:ok, count} -> {:ok, %{pending: String.to_integer(count)}}
          {:error, reason} -> {:error, reason}
        end

      {:error, _none} ->
        {:ok, %{pending: nil}}
    end
  end

  # DEPLOY-27: the commits one revision has that another does not, in the order
  # `git log` lists them (newest first). A merge is not a change of its own, so
  # merges are left out; with nothing to compare with there is nothing to report
  # and no git call to make.
  defp commits_between(nil, _sha, _root), do: {:ok, []}

  defp commits_between(before, sha, root) do
    case git(root, ["log", "--no-merges", "--format=%H%x1f%s", "#{before}..#{sha}"]) do
      {:ok, ""} -> {:ok, []}
      {:ok, output} -> {:ok, Enum.map(String.split(output, "\n"), &commit/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit(line) do
    case String.split(line, "\x1f", parts: 2) do
      [sha, subject] -> %{sha: sha, short: short(sha), subject: subject}
      [sha] -> %{sha: sha, short: short(sha), subject: ""}
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
  # same revision not twice, and only the last few kept. A revision the app
  # loads again goes on being the newest — it is what the app runs — but keeps
  # the time it was first loaded, so a load that brought no new revision
  # (DEPLOY-20) does not make the changes already recorded look new (DASH-14).
  @spec append_revision([map()], map()) :: [map()]
  def append_revision(loaded, revision) do
    case Enum.find(loaded, &(&1.sha == revision.sha)) do
      %{at: at} -> [%{revision | at: at} | Enum.reject(loaded, &(&1.sha == revision.sha))]
      nil -> [revision | loaded] |> Enum.take(@keep_revisions)
    end
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
  # restart stops the server (DEPLOY-17) — unless the runner is the one writing
  # it, at its own boot (DEPLOY-36), where a call to itself is no call at all.
  defp record_revision(root, sha, by, mode, route) do
    revision = %{sha: sha, at: DateTime.utc_now(), by: by, mode: mode}

    case writer(route) do
      nil ->
        record = read_record(root)
        write_record(root, %{record | loaded: append_revision(loaded_revisions(root), revision)})

      _pid ->
        Elia.Deploy.Runner.loaded(root, sha, by, mode)
    end
  end

  defp writer(:direct), do: nil
  defp writer(:runner), do: Process.whereis(Elia.Deploy.Runner)

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

  ## The workspace of a chat

  # A chat's workspace root is the folder of its project (PROJ-12, DEPLOY-1,
  # DEPLOY-3): the live tree for a chat in Elia's own project, since that
  # project's folder *is* the live tree. Nothing here creates a worktree or a
  # branch for a chat (the resolution is `project.folder`, in the session and the
  # pages that need it); a chat that is about to change code makes itself a
  # worktree inside that folder (DEPLOY-28), and every later step in that chat
  # works there by its working directory (`Elia.Workdir`, WD-1), not by its
  # workspace root.

  ## Deploying

  @doc """
  Deploys the trunk into the live tree (DEPLOY-5): fast-forwards `live` to
  `master`, runs the full test suite there, and rolls `live` back when the tests
  fail, so nothing is deployed and the running app is unaffected (HOT-4). A
  deploy asked to leave the suite out merges untested instead (DEPLOY-40).

  `{:ok, message}`, `{:tests_failed, output}` or `{:error, reason}`. Nothing to
  merge when `live` is already at the trunk: no tests run, but the tree's front
  end is still made current before the load (DEPLOY-20), and the message says so.
  Uncommitted changes in the live tree are put aside in the stash before
  anything runs, and the message says so (DEPLOY-37).
  """
  @spec deploy(binary(), keyword()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def deploy(root \\ Workspace.runtime_root(), opts \\ []) do
    with :ok <- deployable(root),
         {:ok, set_aside} <- set_aside(root) do
      case status(root) do
        {:ok, %{pending: 0}} -> nothing_to_merge(root)
        {:ok, %{pending: pending}} -> merge_and_test(pending, root, skip_tests?(opts))
        {:error, reason} -> {:error, reason}
      end
      |> with_set_aside(set_aside)
    end
  end

  # DEPLOY-40: running the suite is what a deploy does; only a deploy that was
  # asked to leave it out does not.
  defp skip_tests?(opts), do: Keyword.get(opts, :skip_tests, false) == true

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
  be a fast-forward: the trunk is at or ahead of `live` (DEPLOY-14). A merge
  that fails leaves the live tree as it found it (DEPLOY-38).
  `{:ok, message}` or `{:error, reason}`.
  """
  @spec merge(binary()) :: {:ok, binary()} | {:error, binary()}
  def merge(root \\ Workspace.runtime_root()) do
    with {:ok, before} <- git(root, ["rev-parse", @live]) do
      # DEPLOY-38: whose changes the tree's are if the merge fails — the caller's
      # when it was already dirty, this merge's when it was not.
      clean = clean?(root) == :ok

      case git(root, ["merge", "--ff-only", @trunk]) do
        {:ok, _output} ->
          {:ok, "#{@trunk} merged into #{@live}."}

        {:error, reason} ->
          {:error, merge_error(reason) <> undo_merge(before, clean, root)}
      end
    end
  end

  # DEPLOY-39: git's own refusal to take a lock is reported as what it is, with
  # the file to remove, rather than as the merge's other failure — a trunk that
  # is not ahead of `live` (DEPLOY-14) — which a lock is not.
  defp merge_error(reason) do
    case lock_file(reason) do
      nil ->
        "Could not merge #{@trunk} into #{@live}. A deploy is fast-forward only, so " <>
          "#{@live} must be an ancestor of #{@trunk} (DEPLOY-14).\n\n#{reason}"

      lock ->
        "Could not merge #{@trunk} into #{@live}: git could not take #{lock}.\n\n" <>
          "#{reason}\n\nA git process that was killed leaves its lock behind: remove " <>
          "#{lock} once no git process is running and deploy again."
    end
  end

  # DEPLOY-39: the lock file git names when it cannot take one — the fingerprint
  # of a git process that died instead of removing it.
  defp lock_file(reason) do
    case Regex.run(~r/Unable to create '([^']+\.lock)'/, reason) do
      [_, lock] -> lock
      _ -> nil
    end
  end

  @doc """
  Clears the locks a killed git process left in the live tree's repository
  (DEPLOY-46): the `.lock` files of the repository's own git directory — git's
  `HEAD`, index and reflog locks and the ones under `refs/`, where Elia's own
  snapshot and checkpoint refs are locked (SNAP-2) — when nothing holds them and
  they are older than a minute. A lock a process has open, or one taken a moment
  ago, is left where it is. Linked worktrees' git directories are not touched.

  `{:ok, %{removed: paths, kept: [{path, reason}]}}` — the files removed and the
  ones left, each named relative to the live tree, a left one with why: `:held`
  or `:fresh` — or `{:error, reason}` when the live tree's git directory cannot
  be found. It needs no lock of its own, being the way out of a tree where every
  git call fails.
  """
  @spec clear_locks(binary()) ::
          {:ok, %{removed: [binary()], kept: [{binary(), :held | :fresh}]}}
          | {:error, binary()}
  def clear_locks(root \\ Workspace.runtime_root()) do
    with {:ok, dir} <- git_dir(root) do
      {removed, kept} =
        dir
        |> lock_files()
        |> Enum.reduce({[], []}, &tally(&1, root, &2))

      {:ok, %{removed: Enum.sort(removed), kept: Enum.sort(kept)}}
    end
  end

  # DEPLOY-46: each lock is either removed or left where it is, with why, and
  # both are named relative to the live tree.
  defp tally(path, root, {removed, kept}) do
    case clear(path) do
      :removed -> {[relative(path, root) | removed], kept}
      {:kept, reason} -> {removed, [{relative(path, root), reason} | kept]}
    end
  end

  # DEPLOY-46: the repository's own git directory — the one the live tree is
  # checked out in. A `.git` file is a linked worktree's or a submodule's
  # pointer, followed to the directory it names.
  defp git_dir(root) do
    path = Path.join(root, ".git")

    cond do
      File.dir?(path) ->
        {:ok, path}

      File.regular?(path) ->
        case File.read(path) do
          {:ok, "gitdir: " <> dir} ->
            {:ok, Path.expand(String.trim(dir), root)}

          _ ->
            {:error, "The live tree's git directory could not be read from #{path}."}
        end

      true ->
        {:error, "The live tree has no git directory: #{path} is not there."}
    end
  end

  # DEPLOY-46: the locks git takes — its `HEAD`, index and reflog locks at the
  # top of the git directory, and the ones under `refs/`. Nothing under
  # `worktrees/`: another tree's git directory is its own (DEPLOY-28).
  defp lock_files(dir) do
    dir
    |> Path.join("*.lock")
    |> Path.wildcard()
    |> Kernel.++(Path.wildcard(Path.join(dir, "logs/**/*.lock")))
    |> Kernel.++(Path.wildcard(Path.join(dir, "refs/**/*.lock")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # DEPLOY-46: a lock is cleared when nothing holds it and it is not fresh; a
  # file that cannot be removed is left and reported as held.
  defp clear(path) do
    cond do
      held?(path) ->
        {:kept, :held}

      fresh?(path) ->
        {:kept, :fresh}

      true ->
        case File.rm(path) do
          :ok -> :removed
          {:error, :enoent} -> :removed
          {:error, _reason} -> {:kept, :held}
        end
    end
  end

  # DEPLOY-46: whether a process has the file open, read from the file
  # descriptors `/proc` keeps for each of them — the directory the suite can
  # point elsewhere with `:proc_root` (the way the dashboard's stats do).
  defp held?(path) do
    real = real_path(path)

    Path.wildcard(Path.join(proc_root(), "*/fd/*"))
    |> Enum.any?(fn fd ->
      case File.read_link(fd) do
        {:ok, target} -> target == real or String.starts_with?(target, real <> " (deleted)")
        _ -> false
      end
    end)
  end

  defp proc_root, do: Application.get_env(:elia, :proc_root, "/proc")

  defp real_path(path) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, real} -> to_string(real)
      _ -> path
    end
  end

  # DEPLOY-46: a lock taken within the last minute is a command's own, not a
  # killed process's leftover.
  defp fresh?(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> System.system_time(:second) - stat.mtime < @stale_lock_seconds
      _ -> false
    end
  end

  defp relative(path, root), do: Path.relative_to(path, root)

  # DEPLOY-38: whether the live tree has nothing uncommitted — the question
  # `set_aside/1` asks of the same call (DEPLOY-37), asked here without stashing
  # anything: a merge is not where the user's changes get put aside.
  defp clean?(root) do
    case git(root, ["status", "--porcelain"]) do
      {:ok, ""} -> :ok
      _ -> :error
    end
  end

  # DEPLOY-38: `git merge --ff-only` writes the index and the working files
  # before it moves the branch, so a merge that cannot finish — a lock it could
  # not take (DEPLOY-39), a process killed halfway — leaves changes nobody made,
  # and every later deploy is refused for them (DEPLOY-5). They are put back
  # from the revision the merge started at, without moving `live`.
  #
  # `git reset --hard` is not the way back here: it needs the very lock that
  # stopped the merge (a reset updates the ref it is checked out on), so the
  # one case it is there for is the one it fails. `git read-tree --reset -u`
  # restores the index and the working files and leaves the ref alone, which is
  # all that is undone: HEAD did not move. A tree that was dirty before the
  # merge keeps the changes that are the caller's.
  defp undo_merge(_before, false, _root), do: ""

  defp undo_merge(before, true, root) do
    if clean?(root) == :ok do
      ""
    else
      case git(root, ["read-tree", "--reset", "-u", before]) do
        {:ok, _output} ->
          "\n\nNothing was merged: the live tree is back at #{short(before)}."

        {:error, reason} ->
          "\n\n#{@live} could not be put back to #{short(before)}: #{reason}"
      end
    end
  end

  @doc """
  The soft deploy mode (DEPLOY-6): deploys the trunk (DEPLOY-5), then recompiles
  the live tree and loads the changed modules into the running app, keeping
  running state. Only available when the endpoint's code reloader is on
  (HOT-2, HOT-7).
  """
  @spec hot_reload(binary(), keyword()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def hot_reload(root \\ Workspace.runtime_root(), opts \\ []),
    do: deploy_and_load(root, :deploy, opts)

  # Both modes report the load as the operation's last step (DEPLOY-21): `:load`
  # for the hot reload, `:restart` for the restart.
  defp deploy_and_load(root, by, opts) do
    if hot_reload_available?() do
      case deploy(root, opts) do
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
  @spec restart(binary(), keyword()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def restart(root \\ Workspace.runtime_root(), opts \\ []) do
    with :ok <- restartable?() do
      case deploy(root, opts) do
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
  (DEPLOY-14), `sha` is not one the app has run
  (DEPLOY-25), or is the revision it is running now; uncommitted changes in the
  tree are put aside first (DEPLOY-37). A rollback that fails
  after it has moved `live` — a front end it cannot build (DEPLOY-24) — puts
  `live` back where it was and loads nothing. Returns what `deploy/1` does.
  """
  @spec rollback(binary(), :reload | :restart, binary()) ::
          {:ok, binary()} | {:error, binary()}
  def rollback(sha, mode, root \\ Workspace.runtime_root())

  def rollback(sha, mode, root) when mode in [:reload, :restart] do
    with :ok <- deployable(root),
         {:ok, set_aside} <- set_aside(root) do
      load_revision(sha, mode, root) |> with_set_aside(set_aside)
    end
  end

  # DEPLOY-25, DEPLOY-26: a rollback goes back only to a revision the app has
  # run and is not running now, in a mode the tree can load; the reset is a step
  # the rollback reports (DEPLOY-21).
  defp load_revision(sha, mode, root) do
    with {:ok, sha} <- ran?(sha, root),
         :ok <- not_running?(sha, root),
         :ok <- mode_available?(mode),
         {:ok, before} <- git(root, ["rev-parse", @live]),
         {:ok, _note} <- step(:reset, root, fn -> reset_to(sha, root) end) do
      after_reset(sha, mode, before, root)
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
  deploy started from the Settings page runs outside the page (DEPLOY-15). Its
  options are the deploy's own, so `skip_tests: true` runs one that leaves the
  live tree's suite out (DEPLOY-40).
  """
  @spec run(:reload | :restart, binary(), keyword()) ::
          {:ok, binary()} | {:tests_failed, binary()} | {:error, binary()}
  def run(mode, root \\ Workspace.runtime_root(), opts \\ [])

  def run(:reload, root, opts), do: hot_reload(root, opts)
  def run(:restart, root, opts), do: restart(root, opts)

  # DEPLOY-33: what says that something outside the VM started the server and
  # will bring it back is a marker in its environment — set by `bin/serve`
  # (RESTART-12), or by another service manager that runs it (RESTART-8) — not
  # Mix or the code reloader, which a server started by hand in a shell has the
  # same of.
  @supervised "ELIA_SUPERVISED"

  @doc """
  Whether the server can be restarted: only a server run by `bin/serve` or
  another service manager comes back after it stops (DEPLOY-7, DEPLOY-33). A
  server started by hand in a shell can't be — nothing is waiting to start it
  again — so the Settings page says so instead of stopping it for good.
  """
  @spec restartable?() :: :ok | {:error, binary()}
  def restartable? do
    if supervised?() do
      :ok
    else
      {:error,
       "Restarting is only available when the server runs, started by bin/serve " <>
         "(or a service manager) so it comes back."}
    end
  end

  # DEPLOY-33: the marker `bin/serve` exports before it runs the server
  # (RESTART-12), read from the environment when it is asked for.
  defp supervised?, do: System.get_env(@supervised) == "1"

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
  # reaches is never reported — the suite included, when the deploy was asked to
  # leave it out (DEPLOY-40).
  defp merge_and_test(count, root, skip?) do
    with {:ok, before} <- git(root, ["rev-parse", @live]),
         {:ok, _merged} <- step(:merge, root, fn -> merge(root) end) do
      deps_and_test(count, before, root, skip?)
    end
  end

  defp deps_and_test(count, before, root, skip?) do
    case step(:deps, root, fn -> fetch_deps(root) end) do
      {:ok, _output} -> test_merged(count, before, root, skip?)
      {:error, reason} -> {:error, fetch_failed(reason) <> rollback_note(before, root)}
    end
  end

  # DEPLOY-40: the suite left out — the merge is kept whatever it is, so the
  # deploy says the tests were skipped: what it loads has not been tested
  # (CONF-20, CONF-22).
  defp test_merged(count, before, root, true),
    do: after_tests(count, before, root, " The test suite was skipped.")

  defp test_merged(count, before, root, false) do
    case step(:tests, root, fn -> run_suite(root) end) do
      {:ok, _output} ->
        after_tests(count, before, root, "")

      {:tests_failed, output} ->
        {:tests_failed, output <> rollback_note(before, root)}

      {:error, reason} ->
        {:error, reason <> rollback_note(before, root)}
    end
  end

  # DEPLOY-19: the tree is deployed, so what a browser loads from it is made
  # current before anything loads the tree itself.
  defp after_tests(count, before, root, note) do
    case front_end(root) do
      {:ok, front_end} -> {:ok, "#{commits(count)} merged into #{@live}.#{note}#{front_end}"}
      {:error, reason} -> {:error, front_end_failed(reason) <> rollback_note(before, root)}
    end
  end

  # ISOL-14: the merged trunk's suite runs in the live tree, jailed by default —
  # no chat's setting is involved (ISOL-15), and the workspace the jail holds is
  # the live tree the caller names (ISOL-13).
  defp run_suite(root) do
    case Elia.Harness.run_tests([], root) do
      {:ok, output} -> {:ok, output}
      {:error, output} -> {:tests_failed, output}
    end
  end

  # DEPLOY-18: a dependency a chat added lives in the `deps` of the worktree it
  # made itself (DEPLOY-29), which the live tree has never seen, so the merged
  # trunk's `mix.lock` is fetched here before its suite runs — in the live tree,
  # which the jail holds (ISOL-13, ISOL-14); a lock that is already satisfied
  # fetches nothing.
  defp fetch_deps(root) do
    case Elia.Shell.run("mix deps.get", cd: root, workspace: root, timeout: @deps_timeout) do
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
      build_staged(root)
    else
      {:ok, ""}
    end
  end

  defp build_staged(root) do
    staging = Path.join(root, @staging)
    # DEPLOY-32: nothing a previous attempt staged is promoted, or left
    # behind, whatever this one does: a deploy starts from the state it found.
    File.rm_rf(staging)

    result =
      with {:ok, _packages} <-
             step(:packages, root, fn -> seam(:packages, &install/1).(root) end),
           {:ok, _assets} <- step(:assets, root, fn -> seam(:assets, &build/1).(root) end) do
        # DEPLOY-24, DEPLOY-31, DEPLOY-32: after the build, what it staged is
        # checked and then promoted — in that order, so a build that wrote
        # nothing, or one whose bundle is incomplete, has changed nothing the
        # browser can fetch.
        case promote(staging, root) do
          :ok -> {:ok, " The live tree's front end was rebuilt."}
          {:error, reason} -> {:error, reason}
        end
      end

    File.rm_rf(staging)
    result
  end

  defp seam(name, default), do: Application.get_env(:elia, __MODULE__, [])[name] || default

  # DEPLOY-24, DEPLOY-31, DEPLOY-32: the bundle the build staged, checked and
  # then promoted over the two files the endpoint serves — in that order, so a
  # build that exits 0 having written nothing — a wiped `priv/static`, a
  # misconfigured `esbuild` or `tailwind` — is a failed deploy rather than a
  # running app with no stylesheet or no hook, and nothing a browser fetches has
  # changed. The error names the file the browser would have loaded.
  defp promote(staging, root) do
    case Enum.find(@bundle, &missing?(Path.join(staging, &1))) do
      nil ->
        Enum.each(@bundle, fn file ->
          File.cp!(Path.join(staging, file), Path.join([root, @assets, file]))
        end)

        :ok

      file ->
        {:error,
         "The build left no bundle: #{Path.join(@assets, file)} is missing or empty " <>
           "(DEPLOY-24, DEPLOY-31)."}
    end
  end

  defp missing?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size == 0
      {:error, _reason} -> true
    end
  end

  # DEPLOY-19: a Node package a chat added is in the worktree that chat made
  # itself (DEPLOY-29), which the live tree has never installed — and without it
  # the tree can't build a bundle at all, since the build is what resolves the
  # import. Run in the live tree, which is the workspace the jail holds
  # (ISOL-13, ISOL-14) the way the fetch above is.
  defp install(root) do
    run_step(root, "npm install --prefix assets --no-audit --no-fund")
  end

  # The build the live tree's own watchers run while the server is up (HOT-7),
  # here by hand and before anything loads the tree: what writes `priv/static`,
  # and so what makes the browser's live reload fire (DEPLOY-12). DEPLOY-31: it
  # writes its bundle into the staging directory rather than over the files the
  # endpoint serves, and only the promotion moves those (DEPLOY-32).
  defp build(root) do
    run_step(root, "mix assets.build", env: [{"ELIA_ASSET_OUT", Path.join(root, @staging)}])
  end

  defp run_step(root, command, opts \\ []) do
    # DEPLOY-19: in the live tree, jailed the way DEPLOY-18's fetch is — the
    # tree the jail holds is the one the step runs in (ISOL-13, ISOL-14).
    case Elia.Shell.run(
           command,
           [cd: root, workspace: root, timeout: @front_end_timeout] ++ opts
         ) do
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

  # DEPLOY-37: the live tree is also where a chat works (DEPLOY-1), so a change
  # nobody committed there — a spec drafted before the worktree existed
  # (DEPLOY-28), an edit left behind — is an ordinary state rather than a reason
  # to hold up a deploy. It is put aside in the stash, untracked files included,
  # so a deploy merges and tests the tree as committed and DEPLOY-5's
  # `git reset --hard` has nothing of the user's to lose. `{:ok, ""}` for a tree
  # that was already clean, `{:ok, note}` for one whose changes were put aside.
  defp set_aside(root) do
    case git(root, ["status", "--porcelain"]) do
      {:ok, ""} ->
        {:ok, ""}

      {:ok, _changes} ->
        put_aside(root)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_aside(root) do
    message = "elia deploy: uncommitted changes put aside before deploying"

    case git(root, ["stash", "push", "--include-untracked", "--message", message]) do
      {:ok, _output} ->
        {:ok, set_aside_note()}

      {:error, reason} ->
        {:error, "The live tree's uncommitted changes could not be put aside: " <> reason}
    end
  end

  defp set_aside_note do
    " The live tree had uncommitted changes: they were put aside in the stash " <>
      "before anything ran. `git stash list` shows them and `git stash pop` brings them back."
  end

  # What the note `set_aside/1` returns says is added to the operation's result,
  # whatever that result is (DEPLOY-37): a deploy or rollback that went on, and
  # one that failed for another reason, both left the user's changes in the
  # stash and both say so.
  defp with_set_aside(result, ""), do: result
  defp with_set_aside({:ok, message}, note), do: {:ok, message <> note}
  defp with_set_aside({:tests_failed, output}, note), do: {:tests_failed, output <> note}
  defp with_set_aside({:error, reason}, note), do: {:error, reason <> note}

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
    # HOT-11: the tree this reload compiles was already compiled by the deploy's
    # own front-end step (DEPLOY-19), in a command of its own and jailed
    # (ISOL-13), so this server's Mix listener never heard it and a compile here
    # would find nothing stale. Purge what that compile wrote first.
    purge_recompiled()

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

  @doc """
  Purges the app's own modules the tree has compiled since this server started,
  and returns them (HOT-11).

  A deploy's front-end step compiles the live tree before the load step runs
  (DEPLOY-19), and a deploy's steps are jailed (ISOL-13): the compile's
  `{:modules_compiled, …}` never reaches this server's Mix listener, because
  Mix's cross-process pubsub rendezvous is a file in the command's own `/tmp`
  and not this process's. The load step's own compile would therefore find
  nothing stale and load nothing (HOT-5), leaving the tree stale until a restart
  — so the modules that compile wrote are purged here, and the reload's compile
  loads them. It is what Phoenix's own reloader falls back to when no Mix
  listener is started at all.

  `ebin` is a parameter so a test can point this at a scratch directory instead
  of the app's own build.
  """
  @spec purge_recompiled(Path.t() | nil) :: [module()]
  def purge_recompiled(ebin \\ nil) do
    started = started_at()

    for beam <- Path.wildcard(Path.join(ebin || app_ebin(), "*.beam")),
        compiled_since?(beam, started) do
      module = beam |> Path.basename(".beam") |> String.to_atom()
      :code.purge(module)
      :code.delete(module)
      module
    end
  end

  # When this server started, in seconds, which `Elia.Application.start/2`
  # records (HOT-11). A reload in a VM that never started the app — a script
  # driving `Elia.Deploy` — has purged nothing newer than its own start.
  defp started_at do
    :persistent_term.get({__MODULE__, :started_at}, System.system_time(:second))
  end

  # The app this server runs, compiled where `Mix.Project` says — the path
  # Phoenix's own reloader purges from (HOT-11).
  defp app_ebin, do: Path.join(Mix.Project.app_path(Mix.Project.config()), "ebin")

  # A beam file's own time is when the tree compiled it, and both sides are
  # Unix seconds, so a file's time and the clock's agree. `File.stat/1` gives
  # the time the shape this Elixir's `File.Stat` carries.
  defp compiled_since?(beam, started) do
    case File.stat(beam) do
      {:ok, %File.Stat{mtime: mtime}} -> unix_seconds(mtime) > started
      _ -> false
    end
  end

  # :calendar's epoch is year 0, Unix time's is 1970.
  defp unix_seconds({{_, _, _}, {_, _, _}} = erl_datetime),
    do: :calendar.datetime_to_gregorian_seconds(erl_datetime) - 62_167_219_200

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
  of those assets in a worktree a chat made for itself (DEPLOY-28) do not
  match: reloading on those would reload the browser while it navigates to
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
    command = "git " <> Enum.map_join(Elia.Shell.harness_git_flags() ++ args, " ", &quote_arg/1)
    # The live tree's own git work — the jail holds it (ISOL-1, ISOL-13).
    opts = Keyword.merge([cd: root, workspace: root, timeout: :timer.minutes(2)], opts)

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
