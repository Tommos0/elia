defmodule Elia.LLM.StreamTimeoutTest do
  @moduledoc """
  The stream idle timeout (LLM-34) and the retry of a stream that stalled
  before any data (LLM-35), over a real socket.

  `Req.Test`'s plug adapter never applies Req's `receive_timeout`, so the
  timeout only shows itself against a real HTTP server — here a Bandit one whose
  plug stops sending. The idle timeout is set to #{300}ms, so a run that
  exceeds it many times over still finishes in well under a second.
  """
  use ExUnit.Case, async: false

  alias Elia.LLM.{Anthropic, Error, Message, OpenRouter}

  # The idle timeout these tests run under, and the pacing of the "live" answer:
  # one piece every @gap_ms, @pieces of them, so the whole stream takes longer
  # than the idle timeout without ever going quiet for that long.
  @idle_ms 300
  @gap_ms 60
  @pieces 6

  # Long enough that a stalling plug never answers, and the server's own
  # shutdown (100ms) is what ends it.
  @stall_ms 60_000

  @providers [Anthropic, OpenRouter]

  setup do
    previous = Application.get_env(:elia, :stream_idle_timeout)
    Application.put_env(:elia, :stream_idle_timeout, @idle_ms)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:elia, :stream_idle_timeout),
        else: Application.put_env(:elia, :stream_idle_timeout, previous)
    end)
  end

  # LLM-34, LLM-35
  test "a stream that goes silent is cut off quickly, and not retried once it sent something" do
    for provider <- @providers do
      counter = :counters.new(1, [])
      port = start_server(provider, fn _n -> :stalled end, counter)
      configure(provider, port)

      started = System.monotonic_time(:millisecond)

      # LLM-36: a stalled stream that already sent data is a transport
      # failure, so the turn's own retry may ask again.
      assert {:error, %Error{transient: true} = error} = stream(provider)
      assert to_string(error) =~ "API request failed: timeout"
      assert System.monotonic_time(:millisecond) - started < 2_000
      # It already sent a byte, so a fresh attempt could repeat its events.
      assert :counters.get(counter, 1) == 1
    end
  end

  # LLM-34
  test "a stream that keeps sending is never cut off, however long it takes" do
    for provider <- @providers do
      counter = :counters.new(1, [])
      port = start_server(provider, fn _n -> :live end, counter)
      configure(provider, port)

      started = System.monotonic_time(:millisecond)
      assert {:ok, %{stop_reason: :end_turn}} = stream(provider)
      elapsed = System.monotonic_time(:millisecond) - started

      # The answer took longer than the idle timeout, yet ran to the end: the
      # timeout is idle, not a cap on the whole response.
      assert elapsed > @idle_ms
      assert :counters.get(counter, 1) == 1
    end
  end

  # LLM-35
  test "a stream that stalled before any data arrived is retried on a fresh connection" do
    for provider <- @providers do
      counter = :counters.new(1, [])

      port =
        start_server(provider, fn n -> if n == 1, do: :silent, else: :live end, counter)

      configure(provider, port)

      assert {:ok, %{stop_reason: :end_turn}} = stream(provider)
      assert :counters.get(counter, 1) == 2
    end
  end

  ## The stalled server

  defp start_server(provider, mode, counter) do
    plug = fn conn, _opts ->
      :counters.add(counter, 1, 1)
      mode.(:counters.get(counter, 1)) |> send_stream(conn, provider)
    end

    # A plug that sleeps is not shutting down; the short shutdown_timeout keeps
    # the test's teardown quick instead of waiting for it.
    pid =
      start_supervised!(
        {Bandit, plug: plug, port: 0, thousand_island_options: [shutdown_timeout: 100]}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # :silent — answers nothing at all, then goes quiet: the client's idle timeout
  #           fires with no data received, which is retryable.
  defp send_stream(:silent, conn, _provider) do
    Process.sleep(@stall_ms)
    conn
  end

  # :stalled — sends the headers and one SSE comment, then goes quiet: data has
  #            arrived, so a retry could repeat an event, and there must be none.
  defp send_stream(:stalled, conn, _provider) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    {:ok, conn} = Plug.Conn.chunk(conn, ": keep-alive\n\n")

    Process.sleep(@stall_ms)
    conn
  end

  # :live — a whole, valid answer, paced so that every gap is well inside the
  #         idle timeout while the total run is not.
  defp send_stream(:live, conn, provider) do
    conn =
      conn |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)

    provider
    |> sse()
    |> pieces(@pieces)
    |> Enum.reduce(conn, fn piece, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, piece)
      Process.sleep(@gap_ms)
      conn
    end)
  end

  # A complete SSE answer, in each provider's own shape.
  defp sse(Anthropic) do
    [
      %{"type" => "message_start", "message" => %{"model" => "test-model"}},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}}
    ]
    |> Enum.map_join(fn event ->
      "event: #{event["type"]}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end

  defp sse(OpenRouter) do
    delta = %{"model" => "test-model", "choices" => [%{"delta" => %{"content" => "hi"}}]}
    stop = %{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]}

    "data: #{Jason.encode!(delta)}\n\n" <>
      "data: #{Jason.encode!(stop)}\n\ndata: [DONE]\n\n"
  end

  defp pieces(body, n) do
    step = max(div(byte_size(body), n), 1)

    for start <- 0..(byte_size(body) - 1)//step do
      binary_part(body, start, min(step, byte_size(body) - start))
    end
  end

  ## Calls and configuration

  defp stream(provider),
    do: provider.stream(%{messages: [Message.user("hi")]}, fn _ -> :ok end)

  defp configure(provider, port) do
    previous = Application.get_env(:elia, provider)

    Application.put_env(:elia, provider,
      api_key: "test-key",
      base_url: "http://localhost:#{port}",
      req_options: []
    )

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:elia, provider),
        else: Application.put_env(:elia, provider, previous)
    end)
  end
end
