defmodule Elia.StepTiming do
  @moduledoc """
  Records each loop step beside its chat: when it happened, how long it took and
  what the provider said it cost (TIME-1 to TIME-10).

  One line of JSON per model request, appended to `<chat id>.timing` in
  `Elia.Store.dir()` (TIME-6), so the file reads and greps as plain text and the
  chat's own saved term (STORE-1) never grows with the records. The loop
  measures a step and sends the record to the session, which writes it; a write
  that fails is ignored, so nothing about a turn depends on these records
  (TIME-8).

  A record holds `turn`, `turn_started_at`, `step`, `attempt`, `outcome` (`:ok`,
  `:error` or `:refused`), `started_at`, `finished_at`, `model_ms`, `tool_ms`,
  `approval_wait_ms`, `answer_wait_ms`, `retry_wait_ms`, the provider's
  `input_tokens`/`output_tokens` when it reported them, and `tools` — the calls
  that ran, each with `name`, `ms` and `failed` (TIME-2 to TIME-5).
  """

  alias Elia.Store

  # TIME-2 to TIME-5: the fields a record holds. Only these keys are read back
  # (TIME-9), so a file something else wrote can add nothing to a record.
  @fields %{
    "turn" => :turn,
    "turn_started_at" => :turn_started_at,
    "step" => :step,
    "attempt" => :attempt,
    "outcome" => :outcome,
    "started_at" => :started_at,
    "finished_at" => :finished_at,
    "model_ms" => :model_ms,
    "tool_ms" => :tool_ms,
    "approval_wait_ms" => :approval_wait_ms,
    "answer_wait_ms" => :answer_wait_ms,
    "retry_wait_ms" => :retry_wait_ms,
    "input_tokens" => :input_tokens,
    "output_tokens" => :output_tokens
  }

  @tool_fields %{"name" => :name, "ms" => :ms, "failed" => :failed}

  # TIME-2: the outcome of a request, read back as the atom it was recorded
  # with. A value nothing recorded stays as it came from the file.
  @outcomes %{"ok" => :ok, "error" => :error, "refused" => :refused}

  # TIME-2: the stamps are wall-clock times, read back as `DateTime`s.
  @stamps [:turn_started_at, :started_at, :finished_at]

  @doc "The file a chat's step records are appended to (TIME-6)."
  @spec path(binary()) :: binary()
  def path(id), do: Path.join(Store.dir(), id <> ".timing")

  @doc """
  Appends one step record for the chat (TIME-1, TIME-6, TIME-7). It never
  raises and never reports a failure: a record that can't be written is dropped
  and the turn is unaffected (TIME-8).
  """
  @spec record(binary(), map()) :: :ok
  def record(id, entry) when is_binary(id) and is_map(entry) do
    with true <- Store.valid_id?(id),
         {:ok, line} <- Jason.encode(entry),
         :ok <- File.mkdir_p(Store.dir()),
         :ok <- File.write(path(id), line <> "\n", [:append]) do
      :ok
    else
      _error -> :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def record(_id, _entry), do: :ok

  @doc """
  The chat's step records, oldest first (TIME-9). An id that isn't a valid chat
  id (STORE-4), a chat with no records and a file that can't be read all give
  `[]`; a line that isn't a record is skipped rather than failing the read.
  """
  @spec load(binary()) :: [map()]
  def load(id) do
    with true <- is_binary(id) and Store.valid_id?(id),
         {:ok, data} <- File.read(path(id)) do
      data |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
    else
      _error -> []
    end
  end

  @doc """
  What a chat's records add up to (TIME-13, TIME-14): how many steps it ran, the
  milliseconds it spent in the model, in its tools and waiting — for an
  approval, for an answer and before a retry — the waited total of those three,
  how many steps failed or were retried, and the tokens the records carry.

  A figure a record doesn't carry as a whole number counts as zero, so one
  edited line can't fail a summary (TIME-18), and a token count is reported only
  when a record carries one (TIME-5).
  """
  @spec summary([map()]) :: map()
  def summary(records) when is_list(records) do
    approval = total_ms(records, :approval_wait_ms)
    answer = total_ms(records, :answer_wait_ms)
    retry = total_ms(records, :retry_wait_ms)

    %{
      "steps" => length(records),
      "model_ms" => total_ms(records, :model_ms),
      "tool_ms" => total_ms(records, :tool_ms),
      "approval_wait_ms" => approval,
      "answer_wait_ms" => answer,
      "retry_wait_ms" => retry,
      # TIME-13: the waiting is its own figure beside the work it delayed.
      "waited_ms" => approval + answer + retry,
      "failed_or_retried" => Enum.count(records, &troubled?/1)
    }
    |> tokens(records)
  end

  @doc "Removes a chat's step records, which go with the chat (TIME-10)."
  @spec delete(binary()) :: :ok
  def delete(id) when is_binary(id) do
    if Store.valid_id?(id), do: File.rm(path(id))
    :ok
  end

  def delete(_id), do: :ok

  # TIME-13: the sum of one duration over the records, a record that doesn't
  # carry it as a whole number contributing nothing (TIME-18).
  defp total_ms(records, field) do
    records
    |> Enum.flat_map(&whole(&1, field))
    |> Enum.sum()
  end

  # TIME-2, TIME-14: a step that took more than one attempt, and a request that
  # came back an error or a refusal, are the trouble a summary counts.
  defp troubled?(record) do
    attempt = Map.get(record, :attempt)

    (is_integer(attempt) and attempt > 1) or Map.get(record, :outcome) in [:error, :refused]
  end

  # TIME-14, TIME-5: the tokens the records carry, each figure reported only
  # when some record carries that count.
  defp tokens(figures, records) do
    Enum.reduce([{"input_tokens", :input_tokens}, {"output_tokens", :output_tokens}], figures, fn
      {key, field}, figures ->
        case Enum.flat_map(records, &whole(&1, field)) do
          [] -> figures
          counts -> Map.put(figures, key, Enum.sum(counts))
        end
    end)
  end

  defp whole(record, field) do
    case Map.get(record, field) do
      value when is_integer(value) -> [value]
      _other -> []
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = record} -> [shape(record)]
      _other -> []
    end
  end

  defp shape(record) do
    record
    |> Enum.flat_map(fn
      {"tools", tools} when is_list(tools) -> [{:tools, Enum.map(tools, &shape_tool/1)}]
      {key, value} -> field(key, value)
    end)
    |> Map.new()
  end

  defp field(key, value) do
    case Map.fetch(@fields, key) do
      {:ok, name} -> [{name, shape_value(name, value)}]
      :error -> []
    end
  end

  defp shape_value(name, value) when name in @stamps, do: stamp(value)
  defp shape_value(:outcome, value), do: Map.get(@outcomes, value, value)
  defp shape_value(_name, value), do: value

  defp shape_tool(%{} = tool) do
    tool
    |> Enum.flat_map(fn {key, value} ->
      case Map.fetch(@tool_fields, key) do
        {:ok, name} -> [{name, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp shape_tool(tool), do: tool

  defp stamp(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _error -> text
    end
  end

  defp stamp(other), do: other
end
