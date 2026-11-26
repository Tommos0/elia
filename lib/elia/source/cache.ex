defmodule Elia.Source.Cache do
  @moduledoc """
  The parsed definitions of a workspace's own source, kept between reads
  (`Elia.Source`, FUNC-4): the files they were made from, and what was read from
  them.

  An entry is only used while those files are the same ones — `Elia.Source` holds
  it to that, and drops an entry it cannot trust — so a function that is edited,
  added or removed is read again as the next message is rendered. The table is
  public: the readers and writers are the processes rendering a message, and this
  process only owns it.

  Without this process — a hot reload adds no child to a running tree (HOT-10) —
  `Elia.Source` reads the source on every render, as it would with no cache at
  all.
  """

  use GenServer

  @table :elia_source_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The definitions for `root` when its files still have `identity`, else `nil`."
  @spec fetch(binary(), term()) :: {integer(), %{binary() => Elia.Source.definition()}} | nil
  def fetch(root, identity) do
    case :ets.lookup(@table, root) do
      [{^root, ^identity, entry}] -> entry
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(binary(), term(), {integer(), %{binary() => Elia.Source.definition()}}) :: :ok
  def put(root, identity, entry) do
    :ets.insert(@table, {root, identity, entry})
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
