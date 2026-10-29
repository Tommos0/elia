defmodule Elia.Settings do
  @moduledoc """
  User settings (API keys, the selected model) in a DETS table outside the
  workspace, so they are never committed or rolled back.

  The file lives at `$XDG_DATA_HOME/elia/settings.dets` (by default
  `~/.local/share/elia/settings.dets`):

      config :elia, Elia.Settings, path: "/custom/settings.dets"

  This process owns the table; reads and writes go straight to DETS from the
  caller.
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

  def get(key, default \\ nil) do
    case :dets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> default
    end
  end

  def put(key, value) do
    with :ok <- :dets.insert(@table, {key, value}), do: :dets.sync(@table)
  end

  def delete(key) do
    with :ok <- :dets.delete(@table, key), do: :dets.sync(@table)
  end

  @doc false
  def delete_all do
    with :ok <- :dets.delete_all_objects(@table), do: :dets.sync(@table)
  end

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
  def terminate(_reason, _path), do: :dets.close(@table)
end
