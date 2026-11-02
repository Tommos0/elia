defmodule Elia.LLM.RetryTest do
  use ExUnit.Case, async: false

  alias Elia.LLM.Retry

  # LLM-34
  test "the stream idle timeout is 90 seconds, and configurable" do
    previous = Application.get_env(:elia, :stream_idle_timeout)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:elia, :stream_idle_timeout),
        else: Application.put_env(:elia, :stream_idle_timeout, previous)
    end)

    Application.delete_env(:elia, :stream_idle_timeout)
    assert Retry.stream_idle_timeout() == :timer.seconds(90)
    assert Retry.stream_idle_timeout() < :timer.minutes(10)

    Application.put_env(:elia, :stream_idle_timeout, 1234)
    assert Retry.stream_idle_timeout() == 1234
  end

  # LLM-35
  test "a stalled stream or a closed connection is retryable only before any data" do
    timeout = %Req.TransportError{reason: :timeout}
    closed = %Req.TransportError{reason: :closed}

    assert Retry.retryable?(timeout, false)
    assert Retry.retryable?(closed, false)

    # A partial stream can't be replayed without emitting its events twice.
    refute Retry.retryable?(timeout, true)
    refute Retry.retryable?(closed, true)
  end

  # LLM-35
  test "other transport errors are not retryable" do
    refute Retry.retryable?(%Req.TransportError{reason: :econnrefused}, false)
    refute Retry.retryable?(%Req.TransportError{reason: :nxdomain}, false)
    refute Retry.retryable?(%RuntimeError{message: "boom"}, false)
  end

  # LLM-31
  test "GET requests retry only a closed connection" do
    assert Retry.closed?(%Req.Request{}, %Req.TransportError{reason: :closed})
    refute Retry.closed?(%Req.Request{}, %Req.TransportError{reason: :timeout})
    refute Retry.closed?(%Req.Request{}, %RuntimeError{message: "boom"})
  end
end
