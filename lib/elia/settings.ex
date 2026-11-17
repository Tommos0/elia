defmodule Elia.Settings do
  @moduledoc """
  User settings (API keys, the selected model) in a DETS table outside the
  workspace, so they are never committed or rolled back.

  The file lives at `$XDG_DATA_HOME/elia/settings.dets` (by default
  `~/.local/share/elia/settings.dets`):

      config :elia, Elia.Settings, path: "/custom/settings.dets"

  This process owns the table and carries out every operation on it (CONF-28),
  so the operations have one order; `update/3` is the read-modify-write
  (CONF-29), which is what a caller that has to build on what is stored uses —
  a key pair generated when there is none, a subscription list with one added
  or removed, a context length added to a stored selection.
  """

  use GenServer

  @table :elia_settings

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path do
    Application.get_env(:elia, __MODULE__, [])[:path] ||
      Path.join([data_home(), "elia", "settings.dets"])
  end

  defp data_home do
    case System.get_env("XDG_DATA_HOME") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join([System.user_home!(), ".local", "share"])
    end
  end

  @doc "CONF-28: what is stored under `key`, or `default` when there is none."
  def get(key, default \\ nil), do: GenServer.call(__MODULE__, {:get, key, default})

  @doc "CONF-28: store `value` under `key`."
  def put(key, value), do: GenServer.call(__MODULE__, {:put, key, value})

  @doc "CONF-28: forget what is stored under `key`."
  def delete(key), do: GenServer.call(__MODULE__, {:delete, key})

  @doc """
  CONF-29: read `key`, apply `fun` to what it read, store the result and return
  it, as one operation — no other settings operation is applied in between, so a
  value built from the stored one is never lost to another writer that read the
  same one. A caller that stores what it computed from the stored value uses
  this rather than a `get/2` followed by a `put/2`.

  The write is the point of the call, so a database that refuses it is a failure
  the caller cannot do anything about: it raises rather than returning one.

  `fun` runs in the settings process, so it must not call back into
  `Elia.Settings` — that would wait on the process running it.
  """
  @spec update(term(), term(), (term() -> term())) :: term()
  def update(key, default \\ nil, fun) when is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, key, default, fun})
  end

  @doc false
  def delete_all, do: GenServer.call(__MODULE__, :delete_all)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    path = path()
    dir = Path.dirname(path)

    # Holds secrets: keep other users out of a directory we create (but leave
    # an existing one, which may be shared, alone).
    unless File.dir?(dir) do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
    end

    case :dets.open_file(@table, file: String.to_charlist(path), type: :set) do
      {:ok, @table} ->
        File.chmod(path, 0o600)
        {:ok, path}

      {:error, reason} ->
        {:stop, {:settings_open_failed, path, reason}}
    end
  end

  @impl true
  def handle_call({:get, key, default}, _from, path), do: {:reply, lookup(key, default), path}

  def handle_call({:put, key, value}, _from, path), do: {:reply, insert(key, value), path}

  def handle_call({:delete, key}, _from, path), do: {:reply, remove(key), path}

  def handle_call({:update, key, default, fun}, _from, path) do
    value = fun.(lookup(key, default))

    case insert(key, value) do
      :ok -> {:reply, value, path}
      {:error, reason} -> raise "settings: could not store #{inspect(key)}: #{inspect(reason)}"
    end
  end

  def handle_call(:delete_all, _from, path), do: {:reply, clear(), path}

  @impl true
  def terminate(_reason, _path), do: :dets.close(@table)

  # ── internals ──────────────────────────────────────────────────────────────

  defp lookup(key, default) do
    case :dets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> default
    end
  end

  # CONF-3: every write is synced before it returns.
  defp insert(key, value) do
    with :ok <- :dets.insert(@table, {key, value}), do: :dets.sync(@table)
  end

  defp remove(key) do
    with :ok <- :dets.delete(@table, key), do: :dets.sync(@table)
  end

  defp clear do
    with :ok <- :dets.delete_all_objects(@table), do: :dets.sync(@table)
  end
end
