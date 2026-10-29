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

  @doc "Streams OpenAI-style chunks as SSE, recording each request body."
  def stub_openrouter_stream(test_pid, chunks) do
    Req.Test.stub(Elia.LLM.OpenRouter, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.request_path, conn.req_headers, Jason.decode!(body)})

      data =
        Enum.map_join(chunks, fn chunk -> "data: #{Jason.encode!(chunk)}\n\n" end) <>
          ": OPENROUTER PROCESSING\n\ndata: [DONE]\n\n"

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, data)
    end)
  end
end
