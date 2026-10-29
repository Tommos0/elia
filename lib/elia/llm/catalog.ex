defmodule Elia.LLM.Catalog do
  @moduledoc """
  Caches each provider's model list for 10 minutes. Fetches run inside this
  process, so concurrent callers for a cold provider share one request.
  Failed fetches are not cached.
  """

  use GenServer

  @ttl :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec models(binary()) :: {:ok, [Elia.LLM.Provider.model()]} | {:error, binary()}
  def models(key), do: GenServer.call(__MODULE__, {:models, key}, :timer.minutes(1))

  def clear(key), do: GenServer.call(__MODULE__, {:clear, key})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:models, key}, _from, cache) do
    now = System.monotonic_time(:millisecond)

    case cache do
      %{^key => {fetched_at, models}} when now - fetched_at < @ttl ->
        {:reply, {:ok, models}, cache}

      _ ->
        case fetch(key) do
          {:ok, models} -> {:reply, {:ok, models}, Map.put(cache, key, {now, models})}
          error -> {:reply, error, Map.delete(cache, key)}
        end
    end
  end

  def handle_call({:clear, key}, _from, cache), do: {:reply, :ok, Map.delete(cache, key)}

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
