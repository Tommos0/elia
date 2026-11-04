defmodule Elia.Deploy.Runner do
  @moduledoc """
  Runs a deploy outside the page that started it (DEPLOY-15, DEPLOY-16).

  A deploy is long — it runs the full suite in the live tree, merges, and then
  reloads or restarts the server — and the Settings page that starts it is not a
  safe place to run it: a LiveView cancels its async work when the page goes
  away, and a deploy's own asset change reloads the browser (DEPLOY-12, HOT-9),
  which is exactly when the page goes away. So the deploy runs here, in a process
  Elia's application owns, and the page only asks for it and listens:

      Elia.Deploy.Runner.subscribe()
      :ok = Elia.Deploy.Runner.start(:reload)
      # ... {:deploy_started, %{mode: :reload, started: at}}
      # ... {:deploy_finished, %{mode: :reload, finished: at, result: result}}

  One deploy runs at a time (DEPLOY-16): a second request while one is in flight
  is refused with `{:error, :busy}`. The deploy in flight and the result of the
  last one are kept here rather than in a page, so a page that mounts while a
  deploy runs — or after one finished — shows both (`state/0`, `running/0`,
  `last/0`).

  The deploy itself is `Elia.Deploy.run/1`, which returns what `deploy/1` does:
  `{:ok, message}`, `{:tests_failed, output}` or `{:error, reason}`.
  """

  use GenServer

  alias Elia.Deploy

  @topic "deploy"

  ## Client

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts a deploy in the background: `:reload` (DEPLOY-6) or `:restart`
  (DEPLOY-7). `:ok`, or `{:error, :busy}` while another deploy runs (DEPLOY-16).
  """
  @spec start(:reload | :restart) :: :ok | {:error, :busy}
  def start(mode) when mode in [:reload, :restart] do
    GenServer.call(__MODULE__, {:start, mode}, 5_000)
  end

  @doc "The deploy in flight: `nil`, or `%{mode: mode, started: DateTime}` (DEPLOY-16)."
  @spec running() :: map() | nil
  def running, do: GenServer.call(__MODULE__, :running)

  @doc """
  The last deploy that finished: `nil`, or
  `%{mode: mode, finished: DateTime, result: result}` (DEPLOY-16).
  """
  @spec last() :: map() | nil
  def last, do: GenServer.call(__MODULE__, :last)

  @doc "The deploy in flight and the last result: `%{running: _, last: _}` (DEPLOY-16)."
  @spec state() :: %{running: map() | nil, last: map() | nil}
  def state, do: GenServer.call(__MODULE__, :state)

  @doc "Subscribes the calling process to deploy events on `Elia.PubSub` (DEPLOY-16)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Elia.PubSub, @topic)

  @doc """
  Forgets the last deploy's result, so a page that mounts next starts clean. A
  deploy still in flight is left alone. Used by tests, which share the
  application's runner across cases.
  """
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  ## Server

  @impl true
  def init(_opts) do
    # The deploy runs in a linked process, so its crash reaches us as a message
    # rather than taking the runner down with it.
    Process.flag(:trap_exit, true)
    {:ok, %{running: nil, pid: nil, last: nil}}
  end

  @impl true
  def handle_call({:start, _mode}, _from, %{running: running} = state)
      when running != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:start, mode}, _from, state) do
    info = %{mode: mode, started: DateTime.utc_now()}
    parent = self()

    pid =
      spawn_link(fn ->
        # DEPLOY-15: this process belongs to the runner, not to the page that
        # asked for the deploy, so nothing the page does stops it.
        send(parent, {:deploy_done, Deploy.run(mode)})
      end)

    broadcast({:deploy_started, info})
    {:reply, :ok, %{state | running: info, pid: pid}}
  end

  def handle_call(:running, _from, state), do: {:reply, state.running, state}
  def handle_call(:last, _from, state), do: {:reply, state.last, state}
  def handle_call(:state, _from, state), do: {:reply, Map.take(state, [:running, :last]), state}
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | last: nil}}

  # DEPLOY-16: a deploy's result is kept here, so the page that started it may
  # be long gone — and one that mounts afterwards still finds it.
  @impl true
  def handle_info({:deploy_done, result}, state) do
    {:noreply, finished(result, state)}
  end

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    # A deploy that raised instead of returning its result. A normal exit comes
    # after the result message and is ignored.
    case reason do
      :normal -> {:noreply, state}
      _reason -> {:noreply, finished({:exit, reason}, state)}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp finished(result, %{running: %{mode: mode}} = state) do
    info = %{mode: mode, finished: DateTime.utc_now(), result: result}
    broadcast({:deploy_finished, info})
    %{state | running: nil, pid: nil, last: info}
  end

  defp broadcast(event), do: Phoenix.PubSub.broadcast(Elia.PubSub, @topic, event)
end
