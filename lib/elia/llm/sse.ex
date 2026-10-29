defmodule Elia.LLM.SSE do
  @moduledoc "Incremental Server-Sent Events parser."

  @doc """
  Feeds a chunk into the parser. Returns the complete events found so far as
  `%{event: binary | nil, data: binary}` maps, plus the leftover buffer.
  """
  @spec parse(binary(), binary()) :: {[map()], binary()}
  def parse(buffer, chunk) do
    parts =
      (buffer <> chunk)
      |> String.replace("\r\n", "\n")
      |> String.split("\n\n")

    {complete, [rest]} = Enum.split(parts, -1)
    events = for raw <- complete, event = parse_event(raw), do: event
    {events, rest}
  end

  defp parse_event(raw) do
    {event, data} =
      raw
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn
        "event:" <> name, {_, data} -> {String.trim(name), data}
        "data:" <> line, {event, data} -> {event, [String.trim_leading(line, " ") | data]}
        _other, acc -> acc
      end)

    if data == [], do: nil, else: %{event: event, data: data |> Enum.reverse() |> Enum.join("\n")}
  end
end
