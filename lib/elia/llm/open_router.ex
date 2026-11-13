defmodule Elia.LLM.OpenRouter do
  @moduledoc """
  OpenRouter provider: OpenAI-compatible Chat Completions (raw HTTP + SSE
  streaming via Req), giving access to many vendors' models.

  The request and the stream are encoded by `Elia.LLM.OpenAI`, which this and
  the local llama.cpp server share (LOCAL-10). What lives here is OpenRouter's
  own: its key, its credits, its catalog, and the `reasoning_details` it wants
  sent back (LLM-21).

  Configuration (`config :elia, Elia.LLM.OpenRouter, ...`):

    * `:api_key` - defaults to `OPENROUTER_API_KEY`; a key saved in Settings wins
    * `:model` - used when a request names none
    * `:max_tokens` - sent only when set (models have different limits)
    * `:effort` - `reasoning.effort`, sent only when set
    * `:cache_control` - put an explicit prompt-cache breakpoint on the system
      message of an Anthropic-family model (LLM-37); `false` turns it off
    * `:base_url`, `:req_options` - transport overrides (tests use `Req.Test`)
  """

  @behaviour Elia.LLM.Provider

  alias Elia.LLM.OpenAI

  @defaults [
    base_url: "https://openrouter.ai/api/v1",
    model: "anthropic/claude-opus-5.5",
    max_tokens: nil,
    effort: nil,
    cache_control: true,
    req_options: []
  ]

  @impl true
  def stream(request, on_event) do
    config = config()
    model = request[:model] || config[:model]

    case Elia.LLM.api_key("openrouter") do
      {_source, key} ->
        OpenAI.stream(
          build_body(request, config),
          [
            url: config[:base_url] <> "/chat/completions",
            headers: [{"authorization", "Bearer " <> key}, {"x-title", "Elia"}],
            req_options: config[:req_options],
            label: "OpenRouter"
          ] ++ encoding_opts(config, model),
          on_event
        )

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
        {:error, "OpenRouter API error #{resp.status}: #{OpenAI.body_error(resp.body)}"}

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
        {:error, "OpenRouter API error #{resp.status}: #{OpenAI.body_error(resp.body)}"}

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
        {:error, "OpenRouter API error #{resp.status}: #{OpenAI.body_error(resp.body)}"}

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
        {:error, "OpenRouter API error #{resp.status}: #{OpenAI.body_error(resp.body)}"}

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

  defp request_options(path, api_key) do
    config = config()
    auth = if api_key, do: [{"authorization", "Bearer " <> api_key}], else: []

    Keyword.merge(
      [
        url: config[:base_url] <> path,
        headers: auth ++ [{"x-title", "Elia"}],
        receive_timeout: :timer.seconds(15)
      ] ++ Elia.LLM.Retry.get_options(),
      config[:req_options]
    )
  end

  defp config, do: Keyword.merge(@defaults, Application.get_env(:elia, __MODULE__, []))

  # LLM-37, LLM-38: the explicit cache breakpoint and the configured reasoning
  # effort are sent only to the model family that documents them. A field the
  # provider doesn't expect is at best ignored and at worst a 400, and a
  # rejected request would fail every step of a turn.
  defp encoding_opts(config, model) do
    [
      reasoning_details: true,
      tag: __MODULE__,
      cache_control: config[:cache_control] != false and anthropic_model?(model)
    ]
  end

  defp anthropic_model?(model),
    do: is_binary(model) and String.starts_with?(model, "anthropic/")

  # LLM-6, LLM-21: OpenRouter's own reasoning blocks are what it sends back.
  @doc false
  def build_body(request, config) do
    model = request[:model] || config[:model]

    OpenAI.build_body(request, config_for(model, config), encoding_opts(config, model))
  end

  # LLM-38: the configured effort is a default for the family that takes one; a
  # model of any other family is asked without it. An effort the request itself
  # names is the caller's own choice and is sent as it is (LLM-18).
  defp config_for(model, config) do
    if anthropic_model?(model), do: config, else: Keyword.put(config, :effort, nil)
  end

  @doc false
  def encode_messages(messages),
    do: OpenAI.encode_messages(messages, encoding_opts(config(), nil))
end
