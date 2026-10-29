defmodule Elia.LLM.Catalog do
  @moduledoc """
  Caches each provider's model list for 10 minutes in an ETS table. Fetches
  run inside this process, so concurrent callers for a cold provider share one
  request; cache reads (`peek/1`) go straight to the table and never wait on a
  fetch in flight. Failed fetches are not cached.
  """

  use GenServer

  @ttl :timer.minutes(10)
  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec models(binary()) :: {:ok, [Elia.LLM.Provider.model()]} | {:error, binary()}
  def models(key) do
    case peek(key) do
      {:ok, models} -> {:ok, models}
      :miss -> GenServer.call(__MODULE__, {:models, key}, :timer.minutes(1))
    end
  end

  @doc "Cached models for `key`, or `:miss` - never fetches nor waits on a fetch."
  @spec peek(binary()) :: {:ok, [Elia.LLM.Provider.model()]} | :miss
  def peek(key) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, fetched_at, models}] when now - fetched_at < @ttl -> {:ok, models}
      _ -> :miss
    end
  end

  def clear(key), do: GenServer.call(__MODULE__, {:clear, key})

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl true
  def handle_call({:models, key}, _from, state) do
    now = System.monotonic_time(:millisecond)

    # Another caller may have filled the cache while this one queued.
    case peek(key) do
      {:ok, models} ->
        {:reply, {:ok, models}, state}

      :miss ->
        case fetch(key) do
          {:ok, models} ->
            :ets.insert(@table, {key, now, models})
            {:reply, {:ok, models}, state}

          error ->
            :ets.delete(@table, key)
            {:reply, error, state}
        end
    end
  end

  def handle_call({:clear, key}, _from, state) do
    :ets.delete(@table, key)
    {:reply, :ok, state}
  end

  defp fetch(key) do
    case Elia.LLM.provider_info(key) do
      nil ->
        {:error, "Unknown provider"}

      %{module: module} ->
        api_key =
          case Elia.LLM.api_key(key) do
            {_source, api_key} -> api_key
            nil -> nil
          end

        module.list_models(api_key)
    end
  end
end
