defmodule Elia.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API provider (raw HTTP + SSE streaming via Req).

  Configuration (`config :elia, Elia.LLM.Anthropic, ...`):

    * `:api_key` - defaults to `ANTHROPIC_API_KEY`; a key saved in Settings wins
    * `:model` - defaults to `"claude-opus-5-5"`
    * `:max_tokens` - defaults to `64_000`
    * `:effort` - `output_config.effort`, defaults to `"high"`
    * `:thinking_display` - `"updates"` (progress notes), `"summarized"` or `"omitted"`
    * `:prices` - `%{model_id => {input, output}}` USD per million tokens,
      merged over the built-in table (the Models API has no prices)
    * `:fallbacks` - server-side refusal fallback, `"default"` or `nil` to disable
    * `:base_url`, `:req_options` - transport overrides (tests use `Req.Test`)
  """

  @behaviour Elia.LLM.Provider

  require Logger

  alias Elia.LLM.{Message, SSE}

  @api_version "2026-10-21"
  @fallback_beta "server-side-fallback-2026-07-01"
  @thinking_updates_beta "thinking-display-updates-2026-08-18"
  @retry_statuses [408, 429, 500, 502, 503, 504, 529]
  @max_retries 2

  # The Models API has no prices, so the picker uses Anthropic's published
  # first-party rates (USD per million input/output tokens). Override or extend
  # with `config :elia, Elia.LLM.Anthropic, prices: %{"model-id" => {in, out}}`.
  @prices %{
    "claude-fable-5-1" => {10.0, 50.0},
    "claude-fable-5" => {10.0, 50.0},
    "claude-opus-5-5" => {4.0, 20.0},
    "claude-opus-5" => {5.0, 25.0},
    "claude-opus-4-8" => {5.0, 25.0},
    "claude-opus-4-7" => {5.0, 25.0},
    "claude-opus-4-6" => {5.0, 25.0},
    "claude-sonnet-5-5" => {2.0, 10.0},
    "claude-sonnet-5" => {2.0, 10.0},
    "claude-sonnet-4-6" => {3.0, 15.0},
    # Up to 100K-token prompts; longer prompts cost $0.50 / $2.50.
    "claude-haiku-5-5" => {0.1, 0.5},
    "claude-haiku-4-5" => {1.0, 5.0}
  }

  @defaults [
    base_url: "https://api.anthropic.com",
    model: "claude-opus-5-5",
    max_tokens: 64_000,
    effort: "high",
    thinking_display: "updates",
    fallbacks: "default",
    req_options: []
  ]

  @impl true
  def stream(request, on_event) do
    config = config()

    case Elia.LLM.api_key("anthropic") do
      {_source, key} ->
        do_stream(build_body(request, config), key, config, on_event, 0)

      nil ->
        {:error, "No Anthropic API key: add one in Settings or set ANTHROPIC_API_KEY"}
    end
  end

  @impl true
  def default_model, do: config()[:model]

  @impl true
  def check_key(api_key) do
    case get_models(api_key, limit: 1) do
      {:ok, _models} -> :ok
      error -> error
    end
  end

  # Without a key (or if listing fails) offer just the configured model.
  @impl true
  def list_models(api_key) do
    fallback = [%{id: default_model(), name: default_model()}]

    models =
      with key when is_binary(key) <- api_key,
           {:ok, [_ | _] = models} <- get_models(key, limit: 1000) do
        models
      else
        _ -> fallback
      end

    {:ok, Enum.map(models, &put_prices/1)}
  end

  defp put_prices(model) do
    prices = Map.merge(@prices, config()[:prices] || %{})
    # Dated snapshot ids (e.g. "claude-haiku-4-5-20251001") price like their alias.
    alias_id = String.replace(model.id, ~r/-\d{8}$/, "")

    case Map.get(prices, model.id) || Map.get(prices, alias_id) do
      {prompt, completion} ->
        Map.merge(model, %{prompt_price: prompt, completion_price: completion})

      nil ->
        model
    end
  end

  defp get_models(api_key, params) do
    config = config()

    options =
      Keyword.merge(
        [
          url: config[:base_url] <> "/v1/models",
          params: params,
          headers: [{"x-api-key", api_key}, {"anthropic-version", @api_version}],
          retry: false,
          receive_timeout: :timer.seconds(15)
        ],
        config[:req_options]
      )

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
        {:ok,
         for model <- data do
           %{
             id: model["id"],
             name: model["display_name"] || model["id"],
             context_length: model["max_input_tokens"]
           }
         end}

      {:ok, %Req.Response{status: status, body: %{"error" => %{"message" => message}}}} ->
        {:error, "Anthropic API error #{status}: #{message}"}

      {:ok, %Req.Response{status: status}} ->
        {:error, "Anthropic API error #{status}"}

      {:error, exception} ->
        {:error, "Anthropic API request failed: #{Exception.message(exception)}"}
    end
  end

  defp config, do: Keyword.merge(@defaults, Application.get_env(:elia, __MODULE__, []))

  ## Request

  @doc false
  def build_body(request, config) do
    thinking =
      case config[:thinking_display] do
        nil -> %{"type" => "adaptive"}
        display -> %{"type" => "adaptive", "display" => display}
      end

    %{
      "model" => request[:model] || config[:model],
      "max_tokens" => request[:max_tokens] || config[:max_tokens],
      "stream" => true,
      "messages" => encode_messages(request.messages),
      "thinking" => thinking,
      "output_config" => %{"effort" => config[:effort]},
      # Auto-place a cache breakpoint on the last cacheable block each turn.
      "cache_control" => %{"type" => "ephemeral"}
    }
    |> put_unless_empty("system", request[:system])
    |> put_unless_empty("tools", Enum.map(request[:tools] || [], &encode_tool/1))
    |> put_unless_empty("fallbacks", config[:fallbacks])
  end

  defp put_unless_empty(map, _key, value) when value in [nil, "", []], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp encode_tool(tool) do
    %{"name" => tool.name, "description" => tool.description, "input_schema" => tool.input_schema}
  end

  @doc false
  def encode_messages(messages) do
    messages
    |> Enum.map(fn %Message{role: role, content: content} ->
      {if(role == :assistant, do: "assistant", else: "user"),
       Enum.flat_map(content, &encode_block/1)}
    end)
    |> Enum.reject(fn {_role, content} -> content == [] end)
    # Tool results followed by a user message become one user turn.
    |> Enum.chunk_by(fn {role, _} -> role end)
    |> Enum.map(fn [{role, _} | _] = turns ->
      %{"role" => role, "content" => Enum.flat_map(turns, &elem(&1, 1))}
    end)
  end

  # Our own blocks go back byte-for-byte; the API checks history is append-only.
  defp encode_block(%{raw: {__MODULE__, raw}}), do: [raw]
  defp encode_block(%{type: :text, text: text}), do: [%{"type" => "text", "text" => text}]

  defp encode_block(%{type: :tool_call} = call) do
    [%{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => call.input}]
  end

  defp encode_block(%{type: :tool_result} = result) do
    [
      %{
        "type" => "tool_result",
        "tool_use_id" => result.tool_call_id,
        "content" => result.content,
        "is_error" => result.is_error
      }
    ]
  end

  # Reasoning and opaque blocks from another provider mean nothing here.
  defp encode_block(_block), do: []

  defp headers(api_key, body) do
    betas =
      [
        body["fallbacks"] && @fallback_beta,
        get_in(body, ["thinking", "display"]) == "updates" && @thinking_updates_beta
      ]
      |> Enum.filter(& &1)

    [{"x-api-key", api_key}, {"anthropic-version", @api_version}] ++
      if betas == [], do: [], else: [{"anthropic-beta", Enum.join(betas, ",")}]
  end

  ## Transport

  defp do_stream(body, api_key, config, on_event, attempt) do
    options =
      Keyword.merge(
        [
          url: config[:base_url] <> "/v1/messages",
          json: body,
          headers: headers(api_key, body),
          retry: false,
          receive_timeout: :timer.minutes(10),
          into: fn {:data, chunk}, {req, resp} ->
            {:cont, {req, handle_chunk(resp, chunk, on_event)}}
          end
        ],
        config[:req_options]
      )

    case Req.post(options) do
      {:ok, %Req.Response{status: 200} = resp} ->
        finish(Req.Response.get_private(resp, :stream, new_state()))

      {:ok, %Req.Response{status: status} = resp}
      when status in @retry_statuses and attempt < @max_retries ->
        delay = retry_delay(resp, attempt)
        Logger.warning("Anthropic API returned #{status}, retrying in #{delay}ms")
        Process.sleep(delay)
        do_stream(body, api_key, config, on_event, attempt + 1)

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, "Anthropic API error #{status}: #{error_message(resp)}"}

      {:error, exception} ->
        {:error, "Anthropic API request failed: #{Exception.message(exception)}"}
    end
  end

  defp retry_delay(resp, attempt) do
    with [value | _] <- Req.Response.get_header(resp, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      min(seconds, 60) * 1000
    else
      _ -> 1000 * Integer.pow(2, attempt)
    end
  end

  defp error_message(resp) do
    raw = Req.Response.get_private(resp, :error_body, "")

    case Jason.decode(raw) do
      {:ok, %{"error" => %{"message" => message}}} -> message
      _ -> raw
    end
  end

  ## Stream accumulation

  defp new_state do
    %{buffer: "", blocks: %{}, stop_reason: nil, model: nil, usage: %{}, error: nil}
  end

  defp handle_chunk(%Req.Response{status: 200} = resp, chunk, on_event) do
    state = Req.Response.get_private(resp, :stream, new_state())
    {events, buffer} = SSE.parse(state.buffer, chunk)
    state = Enum.reduce(events, %{state | buffer: buffer}, &handle_event(&1, &2, on_event))
    Req.Response.put_private(resp, :stream, state)
  end

  defp handle_chunk(resp, chunk, _on_event) do
    Req.Response.put_private(
      resp,
      :error_body,
      Req.Response.get_private(resp, :error_body, "") <> chunk
    )
  end

  defp handle_event(%{data: data}, state, on_event) do
    case Jason.decode(data) do
      {:ok, event} ->
        apply_event(event, state, on_event)

      {:error, _} ->
        Logger.warning("Skipping undecodable SSE data: #{inspect(data)}")
        state
    end
  end

  defp apply_event(%{"type" => "message_start", "message" => message}, state, _on_event) do
    %{state | model: message["model"], usage: message["usage"] || %{}}
  end

  defp apply_event(%{"type" => "content_block_start"} = event, state, on_event) do
    block = event["content_block"]

    block =
      case block["type"] do
        "tool_use" ->
          on_event.({:tool_call_started, %{id: block["id"], name: block["name"]}})
          Map.put(block, "_json", "")

        "fallback" ->
          on_event.({:notice, "Request was rerouted to a fallback model"})
          block

        _ ->
          block
      end

    put_in(state.blocks[event["index"]], block)
  end

  defp apply_event(%{"type" => "content_block_delta"} = event, state, on_event) do
    index = event["index"]
    delta = event["delta"]

    update = fn key, default, fun ->
      update_in(state.blocks[index], &Map.update(&1, key, default, fun))
    end

    case delta["type"] do
      "text_delta" ->
        on_event.({:text_delta, delta["text"]})
        update.("text", delta["text"], &(&1 <> delta["text"]))

      "thinking_delta" ->
        on_event.({:reasoning_delta, delta["thinking"]})
        update.("thinking", delta["thinking"], &(&1 <> delta["thinking"]))

      "signature_delta" ->
        update.("signature", delta["signature"], fn _ -> delta["signature"] end)

      "input_json_delta" ->
        update.("_json", delta["partial_json"], &(&1 <> delta["partial_json"]))

      "citations_delta" ->
        update.("citations", [delta["citation"]], &(&1 ++ [delta["citation"]]))

      _ ->
        state
    end
  end

  defp apply_event(%{"type" => "message_delta"} = event, state, _on_event) do
    %{
      state
      | stop_reason: get_in(event, ["delta", "stop_reason"]) || state.stop_reason,
        usage: Map.merge(state.usage, event["usage"] || %{})
    }
  end

  defp apply_event(%{"type" => "error", "error" => error}, state, _on_event) do
    %{state | error: error["message"] || inspect(error)}
  end

  defp apply_event(_event, state, _on_event), do: state

  defp finish(%{error: error}) when is_binary(error),
    do: {:error, "Anthropic stream error: #{error}"}

  defp finish(state) do
    content =
      state.blocks
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))
      |> drop_declined_partial()
      |> Enum.map(&to_neutral/1)

    {:ok,
     %{
       message: %Message{role: :assistant, content: content},
       stop_reason: stop_reason(state.stop_reason),
       model: state.model,
       usage: state.usage
     }}
  end

  # After a mid-output fallback, the declined model's thinking and tool calls
  # before the last `fallback` block must not be echoed back.
  defp drop_declined_partial(blocks) do
    case blocks |> Enum.with_index() |> Enum.filter(fn {b, _} -> b["type"] == "fallback" end) do
      [] ->
        blocks

      fallbacks ->
        {_, boundary} = List.last(fallbacks)
        result_ids = for b <- blocks, id = b["tool_use_id"], into: MapSet.new(), do: id

        blocks
        |> Enum.with_index()
        |> Enum.reject(fn {block, i} ->
          i < boundary and
            (block["type"] in ["thinking", "redacted_thinking", "tool_use"] or
               (block["type"] == "server_tool_use" and block["id"] not in result_ids))
        end)
        |> Enum.map(&elem(&1, 0))
    end
  end

  defp to_neutral(%{"type" => "text"} = raw) do
    %{type: :text, text: raw["text"] || "", raw: {__MODULE__, raw}}
  end

  defp to_neutral(%{"type" => "thinking"} = raw) do
    %{type: :reasoning, text: raw["thinking"] || "", raw: {__MODULE__, raw}}
  end

  defp to_neutral(%{"type" => "tool_use"} = raw) do
    {json, raw} = Map.pop(raw, "_json", "")

    {input, error} =
      case Jason.decode(if json == "", do: "{}", else: json) do
        {:ok, input} when is_map(input) -> {input, nil}
        _ -> {%{}, json}
      end

    %{
      type: :tool_call,
      id: raw["id"],
      name: raw["name"],
      input: input,
      invalid_input: error,
      raw: {__MODULE__, Map.put(raw, "input", input)}
    }
  end

  defp to_neutral(raw), do: %{type: :opaque, raw: {__MODULE__, raw}}

  defp stop_reason("end_turn"), do: :end_turn
  defp stop_reason("stop_sequence"), do: :end_turn
  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("model_context_window_exceeded"), do: :max_tokens
  defp stop_reason("refusal"), do: :refusal
  defp stop_reason(_), do: :other
end
