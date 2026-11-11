defmodule Elia.LLM.LlamaCpp do
  @moduledoc """
  The local llama.cpp server as a provider (LOCAL): OpenAI-compatible Chat
  Completions against a `llama-server` running on this machine. It needs no
  API key, no account and no network (LOCAL-2), and `Elia.LLM.LlamaServer` can
  start the server from a `.gguf` for you (LOCAL-11).

  The request and the stream are encoded by `Elia.LLM.OpenAI`, shared with
  OpenRouter (LOCAL-10).

  Configuration (`config :elia, Elia.LLM.LlamaCpp, ...`):

    * `:base_url` - else `LLAMA_CPP_BASE_URL`, else `http://127.0.0.1:8080`;
      a base URL saved in Settings wins over both (LOCAL-3)
    * `:model` - used when a request names none
    * `:max_tokens` - sent only when set
    * `:api_key` - sent as a bearer token only when set, for a server started
      with its own `--api-key` (LOCAL-2)
    * `:req_options` - transport overrides (tests use `Req.Test`)
  """

  @behaviour Elia.LLM.Provider

  alias Elia.LLM.OpenAI
  alias Elia.Settings

  @label "llama.cpp server"
  @default_base_url "http://127.0.0.1:8080"
  @key "llamacpp"

  @defaults [base_url: nil, model: nil, max_tokens: nil, api_key: nil, req_options: []]

  @impl true
  def stream(request, on_event) do
    config = config()

    OpenAI.stream(
      OpenAI.build_body(request, config),
      [
        url: base_url() <> "/v1/chat/completions",
        headers: auth_headers(),
        req_options: config[:req_options],
        label: @label,
        # LOCAL-8: a server that is still coming up refuses the connection, and
        # says so in terms of the fix rather than of the syscall.
        retry_refused: true,
        refused_message: refused_message(base_url())
      ],
      on_event
    )
  end

  # LOCAL-6: the configured model, else the running server's only one, else a
  # name the server ignores (llama-server serves whatever it has loaded).
  @impl true
  def default_model do
    config()[:model] || first_model_id() || "local"
  end

  # LOCAL-4, LOCAL-5: the models the server lists, with the context length it
  # reports; a server that isn't up offers the configured model on its own.
  @impl true
  def list_models(_api_key) do
    case fetch_models() do
      {:ok, ids} ->
        props = props()
        single? = length(ids) == 1
        {:ok, Enum.map(ids, &model(&1, props, single?))}

      {:error, _message} ->
        {:ok, [model(fallback_model(), nil, false)]}
    end
  end

  # LOCAL-24: the card has no key to check, so its Check button asks the server.
  @impl true
  def check_key(_api_key), do: check_base_url(base_url())

  @doc """
  Whether a llama.cpp server answers at `url` (LOCAL-24): `GET /health`, as a
  `llama-server` answers 200 to when it is ready.
  """
  @impl true
  @spec check_base_url(binary() | nil) :: :ok | {:error, binary()}
  def check_base_url(url) do
    url = normalize(url) || base_url()

    case Req.get(request_options(url, "/health")) do
      {:ok, %Req.Response{status: 200}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{@label} at #{url} answered #{status} for /health"}

      {:error, exception} ->
        {:error, connection_message(url, exception)}
    end
  end

  @doc "LOCAL-3: the base URL in use — a saved one first, then the configuration."
  @spec base_url() :: binary()
  def base_url do
    case Settings.get({:base_url, @key}) do
      url when is_binary(url) -> normalize(url) || configured_base_url()
      _ -> configured_base_url()
    end
  end

  @doc "LOCAL-3: what a base URL in Settings would override."
  @spec configured_base_url() :: binary()
  def configured_base_url do
    normalize(config()[:base_url] || System.get_env("LLAMA_CPP_BASE_URL")) || @default_base_url
  end

  @doc """
  LOCAL-24: the health check without a saved URL — what the Check button uses,
  so a wrong URL can be tried before it is stored.
  """
  @spec check_candidate(binary() | nil) :: :ok | {:error, binary()}
  def check_candidate(url) do
    case normalize(url) do
      nil -> {:error, "Enter a base URL"}
      url -> check_base_url(url)
    end
  end

  ## Models

  defp fetch_models do
    case Req.get(request_options(base_url(), "/v1/models")) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, for(%{"id" => id} when is_binary(id) <- data, do: id)}

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{@label} at #{base_url()} answered #{status} for /v1/models"}

      {:error, exception} ->
        {:error, connection_message(base_url(), exception)}
    end
  end

  # LOCAL-4: `/props` says what the server loaded. It is not required — a
  # server that doesn't answer it still lists its models.
  defp props do
    case Req.get(request_options(base_url(), "/props")) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> body
      _ -> nil
    end
  end

  defp model(id, props, single?) do
    %{id: id, name: name_for(id, props, single?), context_length: context_length(props)}
  end

  defp name_for(id, props, true) do
    case props && props["model_path"] do
      path when is_binary(path) and path != "" -> Path.basename(path)
      _ -> id
    end
  end

  defp name_for(id, _props, false), do: id

  defp context_length(props),
    do: get_in(props || %{}, ["default_generation_settings", "n_ctx"])

  defp fallback_model, do: config()[:model] || "local"

  defp first_model_id do
    case fetch_models() do
      {:ok, [id | _]} -> id
      _ -> nil
    end
  end

  ## Transport

  defp auth_headers do
    case Elia.LLM.api_key(@key) do
      {_source, key} -> [{"authorization", "Bearer " <> key}]
      nil -> []
    end
  end

  defp request_options(url, path) do
    config = config()

    Keyword.merge(
      [
        url: url <> path,
        headers: auth_headers(),
        receive_timeout: :timer.seconds(15)
      ] ++ Elia.LLM.Retry.get_options(),
      config[:req_options]
    )
  end

  defp connection_message(url, exception) do
    case exception do
      %Req.TransportError{reason: :econnrefused} -> refused_message(url)
      _ -> "#{@label} request failed: #{Exception.message(exception)}"
    end
  end

  # LOCAL-8: the message names the fix.
  defp refused_message(url), do: "No llama.cpp server at #{url}: start one in Settings"

  defp normalize(url) when is_binary(url) do
    case String.trim_trailing(String.trim(url), "/") do
      "" -> nil
      url -> url
    end
  end

  defp normalize(_url), do: nil

  defp config, do: Keyword.merge(@defaults, Application.get_env(:elia, __MODULE__, []))

  # LOCAL-10: the same encoder OpenRouter uses, without its reasoning details
  # (LOCAL-9). Exposed for the tests that hold the two to one shape.
  @doc false
  def build_body(request), do: OpenAI.build_body(request, config())

  @doc false
  def encode_messages(messages), do: OpenAI.encode_messages(messages, [])
end
