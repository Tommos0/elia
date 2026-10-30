defmodule EliaWeb.TimeAgo do
  @moduledoc "Human-readable relative times, e.g. \"10 minutes ago\" (UI-34)."

  @doc "Describes `at` relative to `now`; dates older than a week are shown as `YYYY-MM-DD`."
  @spec format(DateTime.t(), DateTime.t()) :: String.t()
  def format(%DateTime{} = at, %DateTime{} = now \\ DateTime.utc_now()) do
    seconds = max(DateTime.diff(now, at), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> plural(div(seconds, 60), "minute")
      seconds < 86_400 -> plural(div(seconds, 3600), "hour")
      seconds < 7 * 86_400 -> plural(div(seconds, 86_400), "day")
      true -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  defp plural(1, unit), do: "1 #{unit} ago"
  defp plural(n, unit), do: "#{n} #{unit}s ago"
end
