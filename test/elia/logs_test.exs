defmodule Elia.LogsTest do
  use ExUnit.Case, async: false

  alias Elia.Logs

  require Logger

  setup do
    Logs.clear()
    :ok
  end

  defp entry(level, message) do
    %{at: DateTime.utc_now(), level: level, message: message, mfa: nil, pid: nil}
  end

  # LOG-1, LOG-2
  test "captures a logged event with its level, message, time and source" do
    Logs.subscribe()

    Logger.warning("logs-test: something happened")

    assert_receive {:log_entry, entry}, 1000
    assert entry.level == :warning
    assert entry.message =~ "logs-test: something happened"
    assert %DateTime{} = entry.at
    assert is_pid(entry.pid)

    # The buffer keeps it too, newest first.
    assert [first | _] = Logs.list()
    assert first.message =~ "logs-test: something happened"
  end

  # LOG-4
  test "the handler ignores a malformed event instead of crashing the logger" do
    assert Elia.Logs.Handler.log(:not_an_event, %{}) == :ok

    # Normal logging still works after it.
    Logs.subscribe()
    Logger.warning("logs-test: still alive")
    assert_receive {:log_entry, %{message: message}}, 1000
    assert message =~ "still alive"
  end

  # LOG-3
  test "keeps at most max_entries, newest first" do
    for i <- 1..(Logs.max_entries() + 20) do
      Logs.record(entry(:info, "entry #{i}"))
    end

    entries = Logs.list()
    assert length(entries) == Logs.max_entries()
    # Newest first, and the oldest ten have fallen off.
    assert hd(entries).message == "entry #{Logs.max_entries() + 20}"
    refute Enum.any?(entries, &(&1.message in ["entry 1", "entry 10"]))
  end

  # LOG-7
  test "filters by a minimum level" do
    Logs.record(entry(:debug, "debug one"))
    Logs.record(entry(:info, "info one"))
    Logs.record(entry(:warning, "warning one"))
    Logs.record(entry(:error, "error one"))

    assert Enum.map(Logs.list(), & &1.level) == [:error, :warning, :info, :debug]
    assert Enum.map(Logs.list(level: :warning), & &1.level) == [:error, :warning]
    assert Enum.map(Logs.list(level: :all), & &1.level) == [:error, :warning, :info, :debug]
  end

  # LOG-7
  test "filters by a case-insensitive substring" do
    Logs.record(entry(:info, "Connecting to the database"))
    Logs.record(entry(:info, "Serving a request"))

    assert [found] = Logs.list(query: "DATABASE")
    assert found.message == "Connecting to the database"

    assert Logs.list(query: "nothing here") == []
    assert length(Logs.list(query: "")) == 2
  end

  # LOG-8
  test "clear empties the buffer and notifies subscribers" do
    Logs.record(entry(:info, "before clear"))
    assert Logs.list() != []

    Logs.subscribe()
    Logs.clear()

    assert_receive :logs_cleared, 1000
    assert Logs.list() == []
  end
end
