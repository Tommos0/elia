defmodule Elia.LLM.OpenRouter do
  @moduledoc """
  OpenRouter provider: OpenAI-compatible Chat Completions (raw HTTP + SSE
  streaming via Req), giving access to many vendors' models.

  Configuration (`config :elia, Elia.LLM.OpenRouter, ...`):

    * `:api_key` - defaults to `OPENROUTER_API_KEY`; a key saved in Settings wins
    * `:model` - used when a request names none
    * `:max_tokens` - sent only when set (models have different limits)
    * `:effort` - `reasoning.effort`, sent only when set
    * `:base_url`, `:req_options` - transport overrides (tests use `Req.Test`)
  """

  @behaviour Elia.LLM.Provider

  require Logger

  alias Elia.LLM.{Message, SSE}

  @retry_statuses [408, 429, 500, 502, 503, 504]
  @max_retries 2

  @defaults [
    base_url: "https://openrouter.ai/api/v1",
    model: "anthropic/claude-opus-5.5",
    max_tokens: nil,
    effort: nil,
    req_options: []
  ]

  @impl true
  def stream(request, on_event) do
    config = config()

    case Elia.LLM.api_key("openrouter") do
      {_source, key} ->
        do_stream(build_body(request, config), key, config, on_event, 0)

      nil ->
        {:error, "No OpenRouter API key: add one in Settings or set OPENROUTER_API_KEY"}
    end
  end

  @impl true
  def default_model, do: config()[:model]

  @impl true
  def check_key(api_key) do
    case Req.get(request_options("/key", api_key)) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, resp} ->
        {:error, "OpenRouter API error #{resp.status}: #{body_error(resp.body)}"}

      {:error, exception} ->
        {:error, "OpenRouter request failed: #{Exception.message(exception)}"}
    end
  end

  # `/credits` is the account balance but needs a management key; an ordinary
  # key falls back to its own usage and limit from `/key`.
  @impl true
  def balance(api_key) do
    case Req.get(request_options("/credits", api_key)) do
      {:ok, %Req.Response{status: 200, body: %{"data" => %{"total_credits" => total} = data}}}
      when is_number(total) ->
        used = data["total_usage"] || 0
        {:ok, %{scope: :account, used: used / 1, total: total / 1, remaining: (total - used) / 1}}

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        key_balance(api_key)

      {:ok, resp} ->
        {:error, "OpenRouter API error #{resp.status}: #{body_error(resp.body)}"}

      {:error, exception} ->
        {:error, "OpenRouter request failed: #{Exception.message(exception)}"}
    end
  end

  defp key_balance(api_key) do
    case Req.get(request_options("/key", api_key)) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_map(data) ->
        {:ok,
         %{
           scope: :key,
           used: (data["usage"] || 0) / 1,
           total: if(is_number(data["limit"]), do: data["limit"] / 1),
           remaining: if(is_number(data["limit_remaining"]), do: data["limit_remaining"] / 1)
         }}

      {:ok, resp} ->
        {:error, "OpenRouter API error #{resp.status}: #{body_error(resp.body)}"}

      {:error, exception} ->
        {:error, "OpenRouter request failed: #{Exception.message(exception)}"}
    end
  end

  # The catalog is public; only models that can call tools can run Elia's loop.
  @impl true
  def list_models(_api_key) do
    case Req.get(request_options("/models", nil)) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok,
         data
         |> Enum.filter(&("tools" in (&1["supported_parameters"] || [])))
         |> Enum.map(&to_model/1)
         |> Enum.sort_by(&String.downcase(&1.name))}

      {:ok, resp} ->
        {:error, "OpenRouter API error #{resp.status}: #{body_error(resp.body)}"}

      {:error, exception} ->
        {:error, "OpenRouter request failed: #{Exception.message(exception)}"}
    end
  end

  defp to_model(model) do
    %{
      id: model["id"],
      name: model["name"] || model["id"],
      context_length: model["context_length"],
      prompt_price: per_million(get_in(model, ["pricing", "prompt"])),
      completion_price: per_million(get_in(model, ["pricing", "completion"]))
    }
  end

  # Prices are USD per token as strings; "-1" means variable (e.g. routers).
  defp per_million(price) when is_binary(price) do
    case Float.parse(price) do
      {value, _} when value >= 0 -> value * 1_000_000
      _ -> nil
    end
  end

  defp per_million(_price), do: nil

  defp body_error(%{"error" => %{"message" => message}}), do: message
  defp body_error(body) when is_binary(body) and body != "", do: body
  defp body_error(_body), do: "unexpected response"

  defp request_options(path, api_key) do
    config = config()
    auth = if api_key, do: [{"authorization", "Bearer " <> api_key}], else: []

    Keyword.merge(
      [
        url: config[:base_url] <> path,
        headers: auth ++ [{"x-title", "Elia"}],
        retry: false,
        receive_timeout: :timer.seconds(15)
      ],
      config[:req_options]
    )
  end

  defp config, do: Keyword.merge(@defaults, Application.get_env(:elia, __MODULE__, []))

  ## Request

  @doc false
  def build_body(request, config) do
    effort = request[:effort] || config[:effort]

    %{
      "model" => request[:model] || config[:model],
      "stream" => true,
      "messages" => system_message(request[:system]) ++ encode_messages(request.messages)
    }
    |> put_unless_empty("tools", Enum.map(request[:tools] || [], &encode_tool/1))
    |> put_unless_empty("max_tokens", request[:max_tokens] || config[:max_tokens])
    |> put_unless_empty("reasoning", effort && %{"effort" => effort})
  end

  defp system_message(system) when system in [nil, ""], do: []
  defp system_message(system), do: [%{"role" => "system", "content" => system}]

  defp put_unless_empty(map, _key, value) when value in [nil, false, "", []], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp encode_tool(tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.input_schema
      }
    }
  end

  @doc false
  def encode_messages(messages), do: Enum.flat_map(messages, &encode_message/1)

  defp encode_message(%Message{role: :assistant, content: content}) do
    text = text_of(content)

    calls =
      for %{type: :tool_call} = call <- content do
        %{
          "id" => call.id,
          "type" => "function",
          "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.input)}
        }
      end

    # Only our own reasoning details mean anything to OpenRouter.
    details =
      for %{type: :reasoning, raw: {__MODULE__, %{"reasoning_details" => details}}} <- content,
          detail <- details,
          do: detail

    if text == "" and calls == [] do
      []
    else
      [
        %{"role" => "assistant", "content" => if(text == "", do: nil, else: text)}
        |> put_unless_empty("tool_calls", calls)
        |> put_unless_empty("reasoning_details", details)
      ]
    end
  end

  # User and tool messages: each tool result is its own `tool` message, and
  # any text after them becomes a user message.
  defp encode_message(%Message{content: content}) do
    results =
      for %{type: :tool_result} = result <- content do
        body = if result.is_error, do: "Error: " <> result.content, else: result.content
        %{"role" => "tool", "tool_call_id" => result.tool_call_id, "content" => body}
      end

    case text_of(content) do
      "" -> results
      text -> results ++ [%{"role" => "user", "content" => text}]
    end
  end

  defp text_of(content) do
    for(%{type: :text, text: text} <- content, do: text) |> Enum.join("")
  end

  ## Transport

  defp do_stream(body, api_key, config, on_event, attempt) do
    options =
      Keyword.merge(
        [
          url: config[:base_url] <> "/chat/completions",
          json: body,
          headers: [{"authorization", "Bearer " <> api_key}, {"x-title", "Elia"}],
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
        Logger.warning("OpenRouter API returned #{status}, retrying in #{delay}ms")
        Process.sleep(delay)
        do_stream(body, api_key, config, on_event, attempt + 1)

      {:ok, %Req.Response{status: status} = resp} ->
        {:error, "OpenRouter API error #{status}: #{error_message(resp)}"}

      {:error, exception} ->
        {:error, "OpenRouter API request failed: #{Exception.message(exception)}"}
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
      {:ok, body} -> body_error(body)
      _ -> body_error(raw)
    end
  end

  ## Stream accumulation

  defp new_state do
    %{
      buffer: "",
      text: "",
      reasoning: "",
      # index => reasoning detail / tool call, in arrival order of indexes
      details: %{},
      calls: %{},
      finish_reason: nil,
      model: nil,
      usage: %{},
      error: nil
    }
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

  defp handle_event(%{data: "[DONE]"}, state, _on_event), do: state

  defp handle_event(%{data: data}, state, on_event) do
    case Jason.decode(data) do
      {:ok, chunk} when is_map(chunk) ->
        apply_chunk(chunk, state, on_event)

      _ ->
        Logger.warning("Skipping undecodable SSE data: #{inspect(data)}")
        state
    end
  end

  defp apply_chunk(%{"error" => error}, state, _on_event) do
    message = if is_map(error), do: error["message"], else: nil
    %{state | error: message || inspect(error)}
  end

  defp apply_chunk(chunk, state, on_event) do
    state = %{
      state
      | model: chunk["model"] || state.model,
        usage: chunk["usage"] || state.usage
    }

    case chunk["choices"] do
      [choice | _] ->
        delta = choice["delta"] || %{}

        state
        |> append_text(:text, delta["content"], on_event)
        |> append_text(:reasoning, delta["reasoning"], on_event)
        |> merge_details(delta["reasoning_details"])
        |> merge_calls(delta["tool_calls"], on_event)
        |> Map.put(:finish_reason, choice["finish_reason"] || state.finish_reason)

      _ ->
        state
    end
  end

  defp append_text(state, key, text, on_event) when is_binary(text) and text != "" do
    on_event.({if(key == :text, do: :text_delta, else: :reasoning_delta), text})
    Map.update!(state, key, &(&1 <> text))
  end

  defp append_text(state, _key, _text, _on_event), do: state

  defp merge_details(state, details) when is_list(details) do
    Enum.reduce(details, state, fn detail, state ->
      index = detail["index"] || map_size(state.details)

      update_in(state.details, fn all ->
        Map.update(all, index, detail, &merge_detail(&1, detail))
      end)
    end)
  end

  defp merge_details(state, _details), do: state

  # Streamed fragments of one detail: text is split across chunks.
  defp merge_detail(acc, fragment) do
    Map.merge(acc, fragment, fn
      key, old, new when key in ["text", "summary"] and is_binary(old) and is_binary(new) ->
        old <> new

      _key, old, nil ->
        old

      _key, _old, new ->
        new
    end)
  end

  defp merge_calls(state, calls, on_event) when is_list(calls) do
    Enum.reduce(calls, state, fn fragment, state ->
      index = fragment["index"] || 0
      function = fragment["function"] || %{}

      call =
        Map.get(state.calls, index, %{id: nil, name: nil, arguments: "", started: false})

      call = %{
        call
        | id: fragment["id"] || call.id,
          name: call.name || function["name"],
          arguments: call.arguments <> (function["arguments"] || "")
      }

      call =
        if not call.started and call.name do
          id = call.id || generated_id(index)
          on_event.({:tool_call_started, %{id: id, name: call.name}})
          %{call | id: id, started: true}
        else
          call
        end

      put_in(state.calls[index], call)
    end)
  end

  defp merge_calls(state, _calls, _on_event), do: state

  defp generated_id(index), do: "call_#{System.unique_integer([:positive])}_#{index}"

  defp finish(%{error: error}) when is_binary(error),
    do: {:error, "OpenRouter stream error: #{error}"}

  defp finish(%{finish_reason: "error"}), do: {:error, "OpenRouter stream error"}

  defp finish(state) do
    details = state.details |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

    reasoning =
      if state.reasoning != "" or details != [],
        do: [
          %{
            type: :reasoning,
            text: state.reasoning,
            raw: {__MODULE__, %{"reasoning_details" => details}}
          }
        ],
        else: []

    text = if state.text != "", do: [Message.text(state.text)], else: []

    calls =
      state.calls
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {index, call} -> to_tool_call(call, index) end)

    {:ok,
     %{
       message: %Message{role: :assistant, content: reasoning ++ text ++ calls},
       stop_reason: stop_reason(state.finish_reason),
       model: state.model,
       usage: state.usage
     }}
  end

  defp to_tool_call(call, index) do
    json = call.arguments

    {input, error} =
      case Jason.decode(if json == "", do: "{}", else: json) do
        {:ok, input} when is_map(input) -> {input, nil}
        _ -> {%{}, json}
      end

    %{
      type: :tool_call,
      id: call.id || generated_id(index),
      name: call.name || "",
      input: input,
      invalid_input: error
    }
  end

  defp stop_reason("stop"), do: :end_turn
  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason("content_filter"), do: :refusal
  defp stop_reason(_), do: :other
end
