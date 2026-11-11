defmodule Elia.LLM.OpenAI do
  @moduledoc """
  The OpenAI-compatible Chat Completions encoding, shared by the providers that
  speak it (LLM-10, LOCAL-10): `Elia.LLM.OpenRouter` and `Elia.LLM.LlamaCpp`.

  Both send the same request (LLM-18, LOCAL-1) and read the same stream — text
  and reasoning deltas, tool calls joined by index, the same finish reasons and
  the same error objects (LLM-19 to LLM-24). What differs between them is an
  option: the module that owns the reasoning blocks it sends back (LLM-6), the
  name the service goes by in an error message, and whether a connection that
  was refused is worth retrying at once (LOCAL-8).
  """

  require Logger

  alias Elia.LLM.{Error, Message, Retry, SSE}

  @retry_statuses [408, 429, 500, 502, 503, 504]
  @max_retries 2

  # LOCAL-30-style process key: whether any response data has arrived, which is
  # what decides if a failed streaming attempt may be repeated (LLM-30).
  @received_key :elia_open_ai_received

  @doc "The statuses both providers retry themselves (LLM-23, LOCAL-8)."
  def retry_statuses, do: @retry_statuses

  ## Request

  @doc """
  The body of a chat-completions call (LLM-18, LOCAL-1).

  Options: `:reasoning_details` sends an assistant message's accumulated
  `reasoning_details` back, as OpenRouter does (LLM-21), and `:tag` is the
  module those raw blocks belong to (LLM-6).
  """
  def build_body(request, config, opts \\ []) do
    effort = request[:effort] || config[:effort]

    %{
      "model" => request[:model] || config[:model],
      "stream" => true,
      "messages" => system_message(request[:system]) ++ encode_messages(request.messages, opts)
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

  @doc "The OpenAI-compatible messages for `messages` (LLM-19, LOCAL-1)."
  def encode_messages(messages, opts \\ []),
    do: Enum.flat_map(messages, &encode_message(&1, opts))

  defp encode_message(%Message{role: :assistant, content: content}, opts) do
    text = text_of(content)

    calls =
      for %{type: :tool_call} = call <- content do
        %{
          "id" => call.id,
          "type" => "function",
          "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.input)}
        }
      end

    # Only our own reasoning details mean anything to this provider (LLM-6).
    details = if opts[:reasoning_details], do: own_details(content, opts[:tag]), else: []

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
  # any text after them becomes a user message (LLM-19).
  defp encode_message(%Message{content: content}, _opts) do
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

  defp own_details(content, tag) do
    for %{type: :reasoning, raw: {^tag, %{"reasoning_details" => details}}} <- content,
        detail <- details,
        do: detail
  end

  defp text_of(content) do
    for(%{type: :text, text: text} <- content, do: text) |> Enum.join("")
  end

  @doc "The message an API error body carries (LLM-23)."
  def body_error(%{"error" => %{"message" => message}}), do: message
  def body_error(body) when is_binary(body) and body != "", do: body
  def body_error(_body), do: "unexpected response"

  ## Transport

  @doc """
  POSTs `body` and streams the answer through `on_event` (LLM-1, LOCAL-1).

  Options: `:url` (the chat-completions endpoint), `:headers`, `:req_options`
  (transport overrides; tests use `Req.Test`), `:label` (how errors name the
  service), `:reasoning_details` and `:tag` (as `build_body/3`), and for a
  server Elia may have just started, `:retry_refused` and
  `:refused_message` (LOCAL-8).
  """
  @spec stream(map(), keyword(), (Elia.LLM.Provider.event() -> any())) ::
          {:ok, Elia.LLM.Provider.response()} | {:error, binary() | Error.t()}
  def stream(body, opts, on_event), do: do_stream(body, opts, on_event, 0)

  defp do_stream(body, opts, on_event, attempt) do
    Process.put(@received_key, false)

    options =
      Keyword.merge(
        [
          url: opts[:url],
          json: body,
          headers: opts[:headers] || [],
          retry: false,
          receive_timeout: Retry.stream_idle_timeout(),
          into: fn {:data, chunk}, {req, resp} ->
            Process.put(@received_key, true)
            {:cont, {req, handle_chunk(resp, chunk, on_event, opts)}}
          end
        ],
        opts[:req_options] || []
      )

    case Req.post(options) do
      {:ok, %Req.Response{status: 200} = resp} ->
        finish(Req.Response.get_private(resp, :stream, new_state()), opts)

      {:ok, %Req.Response{status: status} = resp}
      when status in @retry_statuses and attempt < @max_retries ->
        delay = retry_delay(resp, attempt)
        Logger.warning("#{label(opts)} API returned #{status}, retrying in #{delay}ms")
        Process.sleep(delay)
        do_stream(body, opts, on_event, attempt + 1)

      {:ok, %Req.Response{status: status} = resp} ->
        # LLM-36: a status the provider retries itself, outlasting its retries,
        # is a failure a turn's own retry may fix.
        message = "#{label(opts)} API error #{status}: #{error_message(resp)}"
        {:error, if(status in @retry_statuses, do: Error.transient(message), else: message)}

      # LLM-31, LLM-35, LOCAL-8: a pooled connection that went stale while the
      # app was idle, a stream that stalled before any data arrived, or the
      # refused connection of a server that isn't up yet — none has emitted an
      # event, so a fresh attempt can't repeat one.
      {:error, exception} ->
        if attempt < @max_retries and retryable?(exception, opts) do
          Logger.warning(
            "#{label(opts)} stream failed (#{Exception.message(exception)}), retrying on a fresh one"
          )

          do_stream(body, opts, on_event, attempt + 1)
        else
          # LLM-36: a transport failure — a stalled stream the idle timeout cut
          # off, a connection that closed or was refused — is what a turn retries.
          {:error, Error.transient(transport_message(exception, opts))}
        end
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

  # LLM-30, LLM-35: nothing received yet and a connection that closed, or a
  # stream that timed out; LOCAL-8 adds a connection that was refused, which is
  # what a server that is still coming up answers.
  defp retryable?(exception, opts) do
    not Process.get(@received_key, false) and
      (Retry.retryable?(exception, false) or
         (opts[:retry_refused] == true and refused?(exception)))
  end

  defp refused?(%Req.TransportError{reason: :econnrefused}), do: true
  defp refused?(_exception), do: false

  # LOCAL-8: a refused connection names the fix rather than the syscall.
  defp transport_message(exception, opts) do
    case {refused?(exception), opts[:refused_message]} do
      {true, message} when is_binary(message) -> message
      _ -> "#{label(opts)} API request failed: #{Exception.message(exception)}"
    end
  end

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
      error: nil,
      # LLM-36: the status an error chunk named, if it named one.
      error_code: nil
    }
  end

  defp handle_chunk(%Req.Response{status: 200} = resp, chunk, on_event, opts) do
    state = Req.Response.get_private(resp, :stream, new_state())
    {events, buffer} = SSE.parse(state.buffer, chunk)
    state = Enum.reduce(events, %{state | buffer: buffer}, &handle_event(&1, &2, on_event, opts))
    Req.Response.put_private(resp, :stream, state)
  end

  defp handle_chunk(resp, chunk, _on_event, _opts) do
    Req.Response.put_private(
      resp,
      :error_body,
      Req.Response.get_private(resp, :error_body, "") <> chunk
    )
  end

  defp handle_event(%{data: "[DONE]"}, state, _on_event, _opts), do: state

  defp handle_event(%{data: data}, state, on_event, opts) do
    case Jason.decode(data) do
      {:ok, chunk} when is_map(chunk) ->
        apply_chunk(chunk, state, on_event, opts)

      _ ->
        Logger.warning("Skipping undecodable SSE data: #{inspect(data)}")
        state
    end
  end

  defp apply_chunk(%{"error" => error}, state, _on_event, _opts) do
    message = if is_map(error), do: error["message"], else: nil
    # LLM-36: the code the error object carries says whether a retry may fix it.
    %{state | error: message || inspect(error), error_code: error_code(error)}
  end

  defp apply_chunk(chunk, state, on_event, _opts) do
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
        |> append_text(:reasoning, delta["reasoning"] || delta["reasoning_content"], on_event)
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

      call = Map.get(state.calls, index, %{id: nil, name: nil, arguments: "", started: false})

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

  # An error object's code is a status number, or the same number as a string.
  defp error_code(error) when is_map(error) do
    case error["code"] do
      code when is_integer(code) -> code
      code when is_binary(code) -> elem(Integer.parse(code), 0)
      _ -> nil
    end
  end

  defp error_code(_error), do: nil

  defp finish(%{error: error} = state, opts) when is_binary(error) do
    message = "#{label(opts)} stream error: #{error}"

    # LLM-22, LLM-36: the code the service named tells a failure a retry may fix
    # from one it says is the request's.
    if Map.get(state, :error_code) in @retry_statuses,
      do: {:error, Error.transient(message)},
      else: {:error, message}
  end

  defp finish(%{finish_reason: "error"}, opts),
    do: {:error, "#{label(opts)} stream error"}

  defp finish(state, opts) do
    details = state.details |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
    reasoning = reasoning_block(state.reasoning, details, opts)
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

  # LLM-21: OpenRouter wants its own reasoning details back, so the block keeps
  # them as its raw data; a provider that has no such thing (LOCAL-1) keeps the
  # reasoning text alone (LLM-6).
  defp reasoning_block("", [], _opts), do: []

  defp reasoning_block(text, details, opts) do
    block = %{type: :reasoning, text: text}

    if opts[:reasoning_details],
      do: [Map.put(block, :raw, {opts[:tag], %{"reasoning_details" => details}})],
      else: [block]
  end

  defp to_tool_call(call, index) do
    json = call.arguments

    {input, error} =
      case Jason.decode(if(json == "", do: "{}", else: json)) do
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

  # LLM-22, LOCAL-1: the finish reasons both providers use.
  defp stop_reason("stop"), do: :end_turn
  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason("content_filter"), do: :refusal
  defp stop_reason(_), do: :other

  defp label(opts), do: opts[:label] || "Provider"
end
