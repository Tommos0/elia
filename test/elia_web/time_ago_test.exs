defmodule EliaWeb.TimeAgoTest do
  use ExUnit.Case, async: true

  alias EliaWeb.TimeAgo

  @now ~U[2026-10-30 12:00:00Z]

  defp ago(seconds), do: TimeAgo.format(DateTime.add(@now, -seconds), @now)

  # UI-34
  test "describes recent times relative to now" do
    assert ago(0) == "just now"
    assert ago(59) == "just now"
    assert ago(60) == "1 minute ago"
    assert ago(10 * 60) == "10 minutes ago"
    assert ago(3600) == "1 hour ago"
    assert ago(3 * 3600) == "3 hours ago"
    assert ago(86_400) == "1 day ago"
    assert ago(2 * 86_400) == "2 days ago"
  end

  # UI-34
  test "shows a date after a week" do
    assert ago(7 * 86_400) == "2026-10-23"
  end

  # UI-34: a clock that moved backwards doesn't produce a negative age.
  test "treats future times as just now" do
    assert ago(-120) == "just now"
  end
end
