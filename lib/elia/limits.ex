defmodule Elia.Limits do
  @moduledoc """
  The per-chat turn limits (LIMIT-1): a step limit, a wall-clock budget in
  minutes, a token budget, and whether reaching any of them pauses the turn for
  the user (LOOP-19) instead of ending it with an error (LOOP-3).

  An empty value (`nil`) means "no limit of this chat's own", so the loop's own
  default applies — for the token budget that is no budget at all (LIMIT-12), so
  a turn's token spend is unlimited until the chat sets one. `pause_on_limit` is
  on by default (LIMIT-9), so a chat that sets no limits of its own pauses at the
  loop's step limit rather than ending its turn with an error (LOOP-3); a chat
  that turns it off keeps the old ending. This module is the one place that knows
  the shape, the defaults, what may be set (LIMIT-7) and the loop options a set
  of limits gives (LIMIT-3).
  """

  @keys [:max_steps, :max_minutes, :max_tokens, :pause_on_limit]
  # LIMIT-1, LIMIT-9: no step limit of this chat's own, no time budget, no token
  # budget, and pausing.
  @defaults %{max_steps: nil, max_minutes: nil, max_tokens: nil, pause_on_limit: true}

  # LIMIT-7: what the chat settings page may set. A sub-task's own budget comes
  # from `spawn_task` instead (SUBTASK-12, SUBTASK-18) and is capped there.
  @max_steps 1_000
  @max_minutes 1_440

  @typedoc "LIMIT-1: `nil` is no limit of this chat's own."
  @type t :: %{
          max_steps: pos_integer() | nil,
          max_minutes: number() | nil,
          max_tokens: pos_integer() | nil,
          pause_on_limit: boolean()
        }

  @doc "The limits of a chat that sets none (LIMIT-1)."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "The defaults, over the values `map` carries (LIMIT-2, STORE-28)."
  @spec new(map() | keyword()) :: t()
  def new(map \\ %{}) do
    given =
      map
      |> Map.new()
      |> Map.take(@keys)
      # A value of the wrong type (a hand-edited or corrupt file, STORE-28) is
      # dropped rather than passed on to the loop.
      |> Enum.filter(fn {key, value} -> valid?(key, value) end)
      |> Map.new()

    Map.merge(@defaults, given)
  end

  defp valid?(:max_steps, value), do: is_nil(value) or (is_integer(value) and value >= 1)
  defp valid?(:max_minutes, value), do: is_nil(value) or (is_number(value) and value > 0)
  # LIMIT-12: no upper bound — any whole number of tokens above 0 will do.
  defp valid?(:max_tokens, value), do: is_nil(value) or (is_integer(value) and value >= 1)
  defp valid?(:pause_on_limit, value), do: is_boolean(value)

  @doc """
  Only the values that aren't the default (STORE-27), so a chat that sets none
  stores nothing and one that clears a limit drops it from its file.
  """
  @spec stored(t() | map()) :: map()
  def stored(limits) do
    limits
    |> new()
    |> Enum.reject(fn {key, value} -> value == @defaults[key] end)
    |> Map.new()
  end

  @doc """
  Checks a map of changes (LIMIT-7): `{:ok, changes}` with only the limit keys,
  or `{:error, message}` naming what is wrong. A key that isn't in the map isn't
  changed (`nil` is no limit, so a key that is must be one to clear it).
  """
  @spec validate(map() | keyword()) :: {:ok, map()} | {:error, binary()}
  def validate(changes) do
    changes = Map.new(changes)

    with :ok <- check_steps(Map.get(changes, :max_steps)),
         :ok <- check_minutes(Map.get(changes, :max_minutes)),
         :ok <- check_tokens(Map.get(changes, :max_tokens)),
         :ok <- check_pause(Map.get(changes, :pause_on_limit)) do
      {:ok, Map.take(changes, @keys)}
    end
  end

  defp check_steps(nil), do: :ok

  defp check_steps(steps) when is_integer(steps) and steps >= 1 and steps <= @max_steps,
    do: :ok

  defp check_steps(_),
    do: {:error, "the step limit must be a whole number from 1 to #{@max_steps}"}

  defp check_minutes(nil), do: :ok

  defp check_minutes(minutes)
       when is_number(minutes) and minutes > 0 and minutes <= @max_minutes,
       do: :ok

  defp check_minutes(_),
    do: {:error, "the time budget must be a number of minutes above 0, at most #{@max_minutes}"}

  defp check_pause(nil), do: :ok
  defp check_pause(pause) when is_boolean(pause), do: :ok
  defp check_pause(_), do: {:error, "pause at a limit must be on or off"}

  # LIMIT-7, LIMIT-12: a token budget has no upper bound.
  defp check_tokens(nil), do: :ok
  defp check_tokens(tokens) when is_integer(tokens) and tokens >= 1, do: :ok

  defp check_tokens(_),
    do: {:error, "the token budget must be a whole number of tokens above 0"}

  @doc """
  The limits as loop options (LIMIT-3): `:max_steps` (LOOP-16), `:budget_ms`
  (LOOP-20), `:token_budget` (LOOP-22) and `:pause_on_limit` (LOOP-19), with
  only the ones this chat sets.
  """
  @spec loop_opts(t() | map()) :: keyword()
  def loop_opts(limits) do
    limits = new(limits)

    []
    |> maybe_put(:max_steps, limits.max_steps)
    |> maybe_put(:budget_ms, budget_ms(limits.max_minutes))
    |> maybe_put(:token_budget, limits.max_tokens)
    |> maybe_put(:pause_on_limit, if(limits.pause_on_limit, do: true))
  end

  @doc "A number of minutes as a wall-clock budget in milliseconds (LOOP-20)."
  @spec budget_ms(number() | nil) :: pos_integer() | nil
  def budget_ms(nil), do: nil
  def budget_ms(minutes) when is_number(minutes), do: trunc(minutes * 60_000)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
