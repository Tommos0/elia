defmodule Elia.Shell.Lock do
  @moduledoc """
  One lock per worktree around mounting the shared `deps` overlay (ISOL-26).

  A jail mounts the worktree's dependency layer itself (ISOL-7), and two jails
  that mount the same layer at the same instant collide: one of them fails with
  `Can't make overlay mount … No such file or directory` before its command
  runs. Overlapping lifetimes are fine — a mount started a moment after another
  succeeds while the first is still up — so the lock is held only while a jail
  is being set up, and released as soon as the jail says it is up: bubblewrap's
  own `--info-fd` report for a command (`Elia.Shell`), the session's first
  output for a terminal (`Elia.Terminal.Session`).

  A holder that dies without releasing is released by its monitor, so a crashed
  command can't wedge every later one in the worktree. A caller that can't get
  the lock in time runs anyway: a rare collision is better than a command that
  never runs.
  """

  use GenServer

  @doc """
  Takes the lock for `key`, waiting for whoever holds it. Returns `:timeout`
  when it isn't free within `timeout` milliseconds, and `:ok` when there is no
  lock process to ask (a script, a test that starts no application).
  """
  @spec acquire(term(), timeout()) :: :ok | :timeout
  def acquire(key, timeout \\ 30_000) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:acquire, key}, timeout)
    end
  catch
    :exit, _reason ->
      # The call gave up, but it may still be queued: take it out again, so a
      # later grant doesn't hand the lock to a caller that has moved on and would
      # hold it until it died. The caller runs without the lock, as `@moduledoc`
      # says, and a rare collision is better than a command that never runs.
      cancel(key)
      :timeout
  end

  @doc "Releases the lock for `key`, held by the calling process."
  @spec release(term()) :: :ok
  def release(key) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, {:release, key})
    end
  catch
    :exit, _reason -> :ok
  end

  # Cast, not call: this runs on the way out of a call that already timed out, so
  # it must never block.
  defp cancel(key) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:cancel, key, self()})
    end
  end

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{holders: %{}, waiting: %{}}}

  @impl true
  def handle_call({:acquire, key}, {pid, _tag} = from, state) do
    case Map.get(state.holders, key) do
      nil -> {:reply, :ok, hold(state, key, pid)}
      _held -> {:noreply, queue(state, key, from)}
    end
  end

  def handle_call({:release, key}, {pid, _tag}, state) do
    case Map.get(state.holders, key) do
      {^pid, ref} -> {:reply, :ok, hand_over(state, key, ref)}
      # Not the holder: nothing to release, and nothing to say about it.
      _other -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:cancel, key, pid}, state) do
    {:noreply, cancel_waiting(state, key, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.holders, state, fn
        {key, {_pid, ^ref}}, state -> hand_over(state, key, ref)
        _other, state -> state
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp hold(state, key, pid) do
    ref = Process.monitor(pid)
    %{state | holders: Map.put(state.holders, key, {pid, ref})}
  end

  defp queue(state, key, from) do
    waiting = Map.update(state.waiting, key, :queue.from_list([from]), &:queue.in(from, &1))
    %{state | waiting: waiting}
  end

  # A caller whose `GenServer.call` timed out has moved on. It is either still
  # queued — take it out — or it was granted in the meantime and holds the lock,
  # which it can't be relied on to release, so give it back here.
  defp cancel_waiting(state, key, pid) do
    state =
      case Map.get(state.holders, key) do
        {^pid, ref} -> hand_over(state, key, ref)
        _other -> state
      end

    case Map.get(state.waiting, key) do
      nil ->
        state

      waiting ->
        rest =
          waiting
          |> :queue.to_list()
          |> Enum.reject(fn {waiting_pid, _tag} -> waiting_pid == pid end)
          |> :queue.from_list()

        %{state | waiting: Map.put(state.waiting, key, rest)}
    end
  end

  # The holder is done: the next waiter that is still alive gets it, in the
  # order it asked. A waiter that died while queued is skipped rather than
  # granted a lock nobody would ever release.
  defp hand_over(state, key, ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | holders: Map.delete(state.holders, key)}
    grant(state, key)
  end

  defp grant(state, key) do
    case Map.get(state.waiting, key) do
      nil ->
        state

      waiting ->
        case :queue.out(waiting) do
          {{:value, {pid, _tag} = from}, rest} ->
            state = %{state | waiting: Map.put(state.waiting, key, rest)}

            if Process.alive?(pid) do
              GenServer.reply(from, :ok)
              hold(state, key, pid)
            else
              grant(state, key)
            end

          {:empty, _queue} ->
            %{state | waiting: Map.delete(state.waiting, key)}
        end
    end
  end
end
