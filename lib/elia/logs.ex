defmodule Elia.Logs do
  @moduledoc """
  An in-memory ring buffer of the server's recent log events, for the Logs
  page (`specs/log-viewer.md`).

  `Elia.Logs.Handler`, an Erlang logger handler attached on start, forwards
  every event the logger emits to this process, which keeps the last
  `max_entries/0` of them and broadcasts each new one on `Elia.PubSub`.
  """

  use GenServer

  @handler_id :elia_logs
  @topic "logs"
  # LOG-3
  @max 500

  # Ascending severity, for the minimum-level filter (LOG-7).
  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The most entries kept (LOG-3)."
  def max_entries, do: @max

  @doc "The PubSub topic new entries are broadcast on (LOG-6)."
  def topic, do: @topic

  @doc "The known levels, least to most severe (LOG-7)."
  def levels, do: @levels

  @doc """
  Records a captured log event (LOG-1). Does nothing when the buffer isn't
  running, so the logger never sees an error (LOG-4).
  """
  def record(entry) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record, entry})
    end

    :ok
  end

  @doc """
  The captured entries, newest first, filtered by `:level` (a minimum,
  default `:all`) and `:query` (a case-insensitive substring, LOG-7).
  """
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  @doc "Empties the buffer and tells every subscriber (LOG-8)."
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "Subscribes the caller to new entries and clears (LOG-6, LOG-8)."
  def subscribe do
    Phoenix.PubSub.subscribe(Elia.PubSub, @topic)
  end

  @impl true
  def init(_opts) do
    attach_handler()
    {:ok, %{entries: [], next_id: 1}}
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    entry = Map.put(entry, :id, state.next_id)
    broadcast({:log_entry, entry})

    state = %{
      state
      | entries: Enum.take([entry | state.entries], @max),
        next_id: state.next_id + 1
    }

    {:noreply, state}
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    {:reply, Enum.filter(state.entries, &matches?(&1, opts)), state}
  end

  def handle_call(:clear, _from, state) do
    broadcast(:logs_cleared)
    {:reply, :ok, %{state | entries: []}}
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Elia.PubSub, @topic, message)

  defp matches?(entry, opts) do
    at_or_above?(entry.level, Keyword.get(opts, :level, :all)) and
      contains?(entry, Keyword.get(opts, :query))
  end

  defp at_or_above?(_level, :all), do: true

  defp at_or_above?(level, minimum) do
    index(level) >= index(minimum)
  end

  defp index(level), do: Enum.find_index(@levels, &(&1 == level)) || 0

  defp contains?(_entry, nil), do: true
  defp contains?(_entry, ""), do: true

  defp contains?(entry, query) do
    query = String.downcase(query)

    String.contains?(String.downcase(entry.message), query) or
      String.contains?(String.downcase(source(entry)), query)
  end

  defp source(%{mfa: nil, pid: nil}), do: ""
  defp source(%{mfa: nil, pid: pid}), do: inspect(pid)
  defp source(%{mfa: mfa, pid: nil}), do: inspect(mfa)
  defp source(%{mfa: mfa, pid: pid}), do: "#{inspect(mfa)} #{inspect(pid)}"

  # LOG-1, LOG-4: attach the handler once, replacing a stale one after a reload.
  defp attach_handler do
    _ = :logger.remove_handler(@handler_id)
    _ = :logger.add_handler(@handler_id, Elia.Logs.Handler, %{})
    :ok
  end
end
