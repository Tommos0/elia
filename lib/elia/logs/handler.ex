defmodule Elia.Logs.Handler do
  @moduledoc """
  An Erlang logger handler that forwards every event the logger emits to
  `Elia.Logs`, which keeps the recent ones in memory (`specs/log-viewer.md`).

  It never blocks or crashes the logger (LOG-4): the event is formatted here
  and handed to the buffer without waiting, and any failure (for example the
  buffer not running yet, or an unexpected event) is ignored.
  """

  @behaviour :logger_handler

  # LOG-2: long messages are truncated before they reach the buffer.
  @truncate 4096

  @impl true
  def adding_handler(config), do: {:ok, config}

  @impl true
  def removing_handler(_config), do: :ok

  @impl true
  def log(%{level: level, meta: meta} = event, _config) when is_map(meta) do
    Elia.Logs.record(%{
      at: at(meta[:time]),
      level: level,
      message: message(event),
      mfa: meta[:mfa],
      pid: meta[:pid]
    })

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # LOG-4: anything that isn't a logger event is ignored.
  def log(_event, _config), do: :ok

  defp message(event) do
    event
    |> Logger.Formatter.format_event(@truncate)
    |> IO.chardata_to_string()
  end

  defp at(nil), do: DateTime.utc_now()
  defp at(microseconds), do: DateTime.from_unix!(microseconds, :microsecond)
end
