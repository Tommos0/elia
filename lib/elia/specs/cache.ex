defmodule Elia.Specs.Cache do
  @moduledoc """
  The parsed spec corpus, kept per workspace between reads (`Elia.Specs`,
  CITE-4): the files it was made from, and what was read from them.

  An entry is only used while those files are the same ones — `Elia.Specs` holds
  it to that, and drops an entry it cannot trust — so a spec that is edited,
  added or removed is read again as the next message is rendered. The table is
  public: the readers and writers are the processes rendering a message, and
  this process only owns it.

  Without this process — a hot reload adds no child to a running tree (HOT-10) —
  `Elia.Specs` reads the corpus on every render, as it would with no cache at
  all.
  """

  use GenServer

  @table :elia_specs_cache

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The corpus for `root` when its files still have `identity`, else `nil`."
  @spec fetch(binary(), term()) :: %{binary() => binary()} | nil
  def fetch(root, identity) do
    case :ets.lookup(@table, root) do
      [{^root, ^identity, requirements}] -> requirements
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @spec put(binary(), term(), %{binary() => binary()}) :: :ok
  def put(root, identity, requirements) do
    :ets.insert(@table, {root, identity, requirements})
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
