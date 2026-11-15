defmodule Elia.Store.Cache do
  @moduledoc """
  What `Elia.Store` remembers of each saved chat between reads (STORE-45): the
  file's identity — its inode, size and modification time — and what was
  decoded from that file, minus the messages.

  An entry is only used while the file still has the identity it was made from.
  Every save renames a new file into place (STORE-2), which changes the inode,
  so a write by anything is seen at the next read without this process hearing
  of it. The table is public: readers and writers are the processes calling
  `Elia.Store`, and this process only owns it.

  Without this process — a hot reload adds no child to a running tree (HOT-10)
  — `Elia.Store` decodes every read, as it did before there was a cache.
  """

  use GenServer

  @table :elia_store_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The entry for `id` when its file still has `identity`, else `nil`."
  @spec fetch(binary(), term()) :: map() | nil
  def fetch(id, identity) do
    case :ets.lookup(@table, id) do
      [{^id, ^identity, record}] -> record
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(binary(), term(), map()) :: :ok
  def put(id, identity, record) do
    :ets.insert(@table, {id, identity, record})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec drop(binary()) :: :ok
  def drop(id) do
    :ets.delete(@table, id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops every entry whose id is not in `ids`: their files are gone."
  @spec keep_only(MapSet.t()) :: :ok
  def keep_only(ids) do
    for id <- :ets.select(@table, [{{:"$1", :_, :_}, [], [:"$1"]}]),
        not MapSet.member?(ids, id),
        do: :ets.delete(@table, id)

    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
