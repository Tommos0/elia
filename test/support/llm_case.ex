defmodule Elia.LLMCase do
  @moduledoc """
  Helpers for tests that touch settings, API keys or provider HTTP calls.

  `reset_settings/0` empties the scratch settings database and the model
  catalog cache. `configure/2` replaces a provider's config for the test,
  routing its requests to `Req.Test` stub named after the provider module.
  Stubs are shared, since the catalog and LiveView tasks call from other
  processes; tests using them must not be async.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  def reset_settings do
    clear = fn ->
      :ok = Elia.Settings.delete_all()
      for info <- Elia.LLM.providers(), do: Elia.LLM.Catalog.clear(info.key)
    end

    clear.()
    on_exit(clear)
    Req.Test.set_req_test_to_shared()
    :ok
  end

  @doc """
  CONF-28: hold the settings process, so that the settings operations a test
  starts are in flight and not yet applied. That is the barrier a race needs to
  be deterministic: with the process held, every racer's read-modify-write is
  waiting in it before any of them runs. Let it go with `resume_settings/0`; a
  test that ends still holding it is let go for it.

  Nothing may call `Elia.Settings` from the test process while it is held.
  """
  def suspend_settings do
    :sys.suspend(Elia.Settings)

    on_exit(fn ->
      if Process.whereis(Elia.Settings), do: :sys.resume(Elia.Settings)
    end)

    :ok
  end

  @doc "CONF-28: let a suspended settings process go (`suspend_settings/0`)."
  def resume_settings, do: :sys.resume(Elia.Settings)

  @doc """
  CONF-28: wait (briefly) until `count` operations are waiting in the suspended
  settings process, so a test knows they are all in flight before letting it go.
  Returns `:timeout` when they never get there, which is what a settings
  operation that never reaches the process looks like.
  """
  def wait_queued(count, timeout \\ 500) do
    wait_for_queue(count, System.monotonic_time(:millisecond) + timeout)
  end

  defp wait_for_queue(count, deadline) do
    cond do
      queue_length() >= count ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(5)
        wait_for_queue(count, deadline)

      true ->
        :timeout
    end
  end

  defp queue_length do
    case Process.whereis(Elia.Settings) do
      pid when is_pid(pid) ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, length} -> length
          _ -> 0
        end

      _ ->
        0
    end
  end

  def configure(module, opts \\ []) do
    previous = Application.get_env(:elia, module)

    Application.put_env(
      :elia,
      module,
      Keyword.merge([api_key: nil, req_options: [plug: {Req.Test, module}]], opts)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:elia, module, previous),
        else: Application.delete_env(:elia, module)
    end)
  end

  @doc """
  Answers a provider's catalog request with `models` (none by default), so a
  choice that asks the catalog (VISION-7) makes no real request.
  """
  def stub_catalog(module, models \\ []) do
    Req.Test.stub(module, &Req.Test.json(&1, %{"data" => models}))
  end

  @doc "Streams OpenAI-style chunks as SSE, recording each request body."
  def stub_openrouter_stream(test_pid, chunks) do
    stub_openai_stream(Elia.LLM.OpenRouter, test_pid, chunks)
  end

  @doc """
  Streams OpenAI-style chunks as SSE from `module`, recording each request body.

  The shape is the one OpenRouter and the local llama.cpp server both speak
  (LOCAL-10), so one helper covers either.
  """
  def stub_openai_stream(module, test_pid, chunks) do
    Req.Test.stub(module, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, conn.req_headers, Jason.decode!(body)})

      data =
        Enum.map_join(chunks, fn chunk -> "data: #{Jason.encode!(chunk)}\n\n" end) <>
          ": PROCESSING\n\ndata: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, data)
    end)
  end
end
