defmodule Elia.Deploy.Runner do
  @moduledoc """
  Runs a deploy — or a rollback (DEPLOY-26) — outside the page that started it
  (DEPLOY-15, DEPLOY-16).

  A deploy is long — it runs the full suite in the live tree, merges, and then
  reloads or restarts the server — and the Settings page that starts it is not a
  safe place to run it: a LiveView cancels its async work when the page goes
  away, and a deploy's own asset change reloads the browser (DEPLOY-12, HOT-9),
  which is exactly when the page goes away. So the deploy runs here, in a process
  Elia's application owns, and the page only asks for it and listens:

      Elia.Deploy.Runner.subscribe()
      :ok = Elia.Deploy.Runner.start(:reload)
      # ... {:deploy_started, %{mode: :reload, started: at}}
      # ... {:deploy_progress, %{step: :tests, phase: :started, at: at, ms: nil}}
      # ... {:deploy_finished, %{mode: :reload, finished: at, result: result}}

  One operation runs at a time (DEPLOY-16): a second request while one is in
  flight is refused with `{:error, :busy}`, whether it is a deploy
  (`start/1`) or a rollback (`rollback/2`).

  The steps of the operation in flight, and the ones that have finished, are
  held here rather than in a page (DEPLOY-22), so a page that mounts while one
  runs — or is reloaded by the deploy's own asset change — shows where it is:
  `state/0` returns `%{running: %{kind, mode, sha, started, step, steps},
  last: %{kind, mode, sha, finished, step, steps, result}}`, where each step is
  `%{step: atom, ms: non_neg_integer | nil, status: :ok | {:failed, binary}}`.

  What the operation is doing and what it did is also written down as it goes,
  in the live tree's data dir (DEPLOY-23, `Elia.Deploy.last_deploy/1`), so the
  record outlives this process: a deploy that restarts the server still says
  what it did to the page that comes up afterwards. This process is that
  record's only writer, so a step and a load are never written over each other.

  The operation itself is `Elia.Deploy.run/2` or `Elia.Deploy.rollback/3`, which
  return what `deploy/1` does: `{:ok, message}`, `{:tests_failed, output}` or
  `{:error, reason}`.
  """

  use GenServer

  alias Elia.{Deploy, Workspace}

  @topic "deploy"

  ## Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a deploy in the background: `:reload` (DEPLOY-6) or `:restart`
  (DEPLOY-7). `:ok`, or `{:error, :busy}` while another operation runs
  (DEPLOY-16).
  """
  @spec start(:reload | :restart) :: :ok | {:error, :busy}
  def start(mode) when mode in [:reload, :restart] do
    GenServer.call(__MODULE__, {:start, {:deploy, mode}}, 5_000)
  end

  @doc """
  Starts going back to a revision the app has run (DEPLOY-26) in the
  background, as an operation of its own (DEPLOY-15, DEPLOY-16): `:ok`, or
  `{:error, :busy}` while another operation runs. It reports its steps and its
  result the way a deploy does.
  """
  @spec rollback(binary(), :reload | :restart) :: :ok | {:error, :busy}
  def rollback(sha, mode) when is_binary(sha) and mode in [:reload, :restart] do
    GenServer.call(__MODULE__, {:start, {:rollback, sha, mode}}, 5_000)
  end

  @doc """
  The operation in flight: `nil`, or
  `%{kind: kind, mode: mode, sha: sha | nil, started: DateTime, step: atom | nil,
  steps: [step]}` (DEPLOY-16, DEPLOY-22).
  """
  @spec running() :: map() | nil
  def running, do: GenServer.call(__MODULE__, :running)

  @doc """
  The last operation that finished: `nil`, or
  `%{kind: kind, mode: mode, sha: sha | nil, finished: DateTime,
  step: nil, steps: [step], result: result}` (DEPLOY-16, DEPLOY-22).
  """
  @spec last() :: map() | nil
  def last, do: GenServer.call(__MODULE__, :last)

  @doc "The operation in flight and the last result: `%{running: _, last: _}` (DEPLOY-16)."
  @spec state() :: %{running: map() | nil, last: map() | nil}
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Subscribes the calling process to deploy events on `Elia.PubSub` (DEPLOY-16)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Elia.PubSub, @topic)

  @doc """
  Forgets the last operation's result, so a page that mounts next starts clean.
  An operation still in flight is left alone. Used by tests, which share the
  application's runner across cases.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc false
  # A step of the running operation (DEPLOY-21, DEPLOY-22): what started or
  # finished, when, how long it took and whether it succeeded. Called by
  # `Elia.Deploy` from the operation's own process, which is what tells a step
  # of this operation from one a test runs by calling `Elia.Deploy.deploy/1`
  # directly.
  @spec step(binary(), atom(), :started | :finished, non_neg_integer() | nil, term()) :: :ok
  def step(root, step, phase, ms, status \\ nil) do
    GenServer.call(__MODULE__, {:step, root, step, phase, ms, status}, 5_000)
  end

  @doc false
  # A revision the app has loaded (DEPLOY-17, DEPLOY-25), recorded with what
  # loaded it — a deploy or a rollback — and how.
  @spec loaded(binary(), binary(), :deploy | :rollback, :reload | :restart) :: :ok
  def loaded(root, sha, by, mode) do
    GenServer.call(__MODULE__, {:loaded, root, sha, by, mode}, 5_000)
  end

  ## Server

  @impl true
  def init(_opts) do
    # The operation runs in a linked process, so its crash reaches us as a
    # message rather than taking the runner down with it.
    Process.flag(:trap_exit, true)
    {:ok, %{pid: nil, root: nil, records: %{}}}
  end

  @impl true
  def handle_call({:start, _spec}, _from, %{pid: pid} = state) when pid != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, spec}, _from, state) do
    root = Workspace.runtime_root()
    started = DateTime.utc_now()

    operation = %{
      kind: kind(spec),
      mode: mode(spec),
      sha: sha(spec),
      started: started,
      finished: nil,
      step: nil,
      steps: [],
      result: nil
    }

    # DEPLOY-23: the operation is in the record before anything runs, so the
    # page that comes back after a restart knows what was going on.
    state = store(state, root, %{record(state, root) | running: operation})

    parent = self()

    pid =
      spawn_link(fn ->
        # DEPLOY-15: this process belongs to the runner, not to the page that
        # asked for the operation, so nothing the page does stops it.
        send(parent, {:deploy_done, run(spec, root)})
      end)

    broadcast({:deploy_started, %{mode: operation.mode, started: started}})
    {:reply, :ok, %{state | pid: pid, root: root}}
  end

  def handle_call(:running, _from, state), do: {:reply, record(state).running, state}
  def handle_call(:last, _from, state), do: {:reply, record(state).last, state}

  def handle_call(:state, _from, state) do
    record = record(state)
    {:reply, %{running: record.running, last: record.last}, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, put_record(state, %{record(state) | last: nil})}
  end

  # A step of the operation in flight (DEPLOY-21, DEPLOY-22). A report that is
  # not this operation's own — a deploy a test runs directly — is ignored: the
  # runner holds what it runs, not what anyone runs.
  def handle_call({:step, _root, _step, _phase, _ms, _status}, _from, %{pid: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:step, root, step, phase, ms, status}, {from, _tag}, %{pid: pid} = state) do
    if from == pid do
      record = record(state, root)
      running = running(record.running, step, phase, ms, status)
      state = store(state, root, %{record | running: running})
      broadcast({:deploy_progress, %{step: step, phase: phase, at: DateTime.utc_now(), ms: ms}})
      {:reply, :ok, state}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:loaded, root, sha, by, mode}, {from, _tag}, state) do
    record = record(state, root)
    revision = %{sha: sha, at: DateTime.utc_now(), by: by, mode: mode}

    # DEPLOY-25: `sha` is the revision the operation went to, so a deploy that
    # loads says which one it loaded. A load by anyone else — a deploy run
    # outside the runner, the record the server makes at boot (DEPLOY-17) —
    # leaves an operation in flight as it is.
    running =
      if record.running && from == state.pid,
        do: %{record.running | sha: sha},
        else: record.running

    record = %{record | running: running, loaded: Deploy.append_revision(record.loaded, revision)}

    {:reply, :ok, store(state, root, record)}
  end

  # DEPLOY-16: an operation's result is kept here, so the page that started it
  # may be long gone — and one that mounts afterwards still finds it.
  @impl true
  def handle_info({:deploy_done, result}, %{pid: pid} = state) when pid != nil do
    {:noreply, finished(result, state)}
  end

  def handle_info({:deploy_done, _result}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    # An operation that raised instead of returning its result. A normal exit
    # comes after the result message and is ignored.
    case reason do
      :normal -> {:noreply, state}
      _reason -> {:noreply, finished({:exit, reason}, state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp kind({:deploy, _mode}), do: :deploy
  defp kind({:rollback, _sha, _mode}), do: :rollback

  defp mode({:deploy, mode}), do: mode
  defp mode({:rollback, _sha, mode}), do: mode

  # A deploy's revision is the one it loads, which it only knows once it has
  # loaded it; a rollback's is the one it is going back to, from the start.
  defp sha({:deploy, _mode}), do: nil
  defp sha({:rollback, sha, _mode}), do: sha

  defp run({:deploy, mode}, root), do: Deploy.run(mode, root)
  defp run({:rollback, sha, mode}, root), do: Deploy.rollback(sha, mode, root)

  defp running(running, step, :started, _ms, _status), do: %{running | step: step}

  defp running(running, step, :finished, ms, status) do
    %{running | step: nil, steps: running.steps ++ [%{step: step, ms: ms, status: status}]}
  end

  defp finished(result, %{root: root} = state) do
    record = record(state, root)

    operation = %{
      record.running
      | finished: DateTime.utc_now(),
        step: nil,
        result: result
    }

    state = store(state, root, %{record | running: nil, last: operation})

    broadcast(
      {:deploy_finished, %{mode: operation.mode, finished: operation.finished, result: result}}
    )

    %{state | pid: nil, root: nil}
  end

  # The record this runner holds for a root: what the file already says about it
  # (a page that comes back after a restart reads that), plus what has happened
  # since.
  defp record(state), do: record(state, Workspace.runtime_root())

  defp record(state, root) do
    Map.get_lazy(state.records, root, fn -> seed(root) end)
  end

  defp seed(root) do
    %{running: nil, last: Deploy.read_record(root).last, loaded: Deploy.loaded_revisions(root)}
  end

  defp put_record(state, record),
    do: %{state | records: Map.put(state.records, Workspace.runtime_root(), record)}

  # DEPLOY-23: the record is written as the operation goes, and this process is
  # its only writer, so what a page reads back is exactly what it holds.
  defp store(state, root, record) do
    Deploy.write_record(root, record)
    %{state | records: Map.put(state.records, root, record)}
  end

  defp broadcast(event), do: Phoenix.PubSub.broadcast(Elia.PubSub, @topic, event)
end
