defmodule Elia.LLM do
  @moduledoc """
  Entry point for model calls. Dispatches to the configured provider:

      config :elia, Elia.LLM, provider: Elia.LLM.Anthropic

  Also the registry of selectable providers, their API keys (stored in
  `Elia.Settings`, falling back to each provider's config) and the user's
  model selection.
  """

  alias Elia.LLM.Catalog
  alias Elia.Settings

  @providers [
    %{key: "anthropic", name: "Anthropic", module: Elia.LLM.Anthropic},
    %{key: "openrouter", name: "OpenRouter", module: Elia.LLM.OpenRouter}
  ]

  @selection_topic "llm:selection"

  @spec stream(Elia.LLM.Provider.request(), (Elia.LLM.Provider.event() -> any())) ::
          {:ok, Elia.LLM.Provider.response()} | {:error, term()}
  def stream(request, on_event \\ fn _ -> :ok end) do
    {provider, request} = Map.pop(request, :provider, provider())
    provider.stream(request, on_event)
  end

  def provider, do: Application.get_env(:elia, __MODULE__, [])[:provider] || Elia.LLM.Anthropic

  ## Registry

  def providers, do: @providers

  def provider_info(key), do: Enum.find(@providers, &(&1.key == key))

  ## API keys

  @doc "The key in use for a provider: a stored one, else the configured one."
  @spec api_key(binary()) :: {:stored | :env, binary()} | nil
  def api_key(key) do
    with %{module: module} <- provider_info(key) do
      configured = Application.get_env(:elia, module, [])[:api_key]

      case Settings.get({:api_key, key}) do
        stored when is_binary(stored) -> {:stored, stored}
        _ when is_binary(configured) and configured != "" -> {:env, configured}
        _ -> nil
      end
    end
  end

  @doc "Verifies `api_key` against the provider without storing it."
  @spec check_key(binary(), binary()) :: :ok | {:error, binary()}
  def check_key(key, api_key) do
    case {provider_info(key), String.trim(api_key || "")} do
      {nil, _} -> {:error, "Unknown provider"}
      {_, ""} -> {:error, "Enter an API key"}
      {%{module: module}, api_key} -> module.check_key(api_key)
    end
  end

  @doc "Checks `api_key` and stores it if the check passes."
  @spec save_key(binary(), binary()) :: :ok | {:error, binary()}
  def save_key(key, api_key) do
    api_key = String.trim(api_key || "")

    with :ok <- check_key(key, api_key),
         :ok <- Settings.put({:api_key, key}, api_key) do
      Catalog.clear(key)
    end
  end

  def delete_key(key) do
    with :ok <- Settings.delete({:api_key, key}), do: Catalog.clear(key)
  end

  ## Model selection

  def subscribe_selection, do: Phoenix.PubSub.subscribe(Elia.PubSub, @selection_topic)

  @doc """
  The selected `%{provider, model, name}`. Without a stored selection, the
  configured provider and its default model.
  """
  def selection do
    case Settings.get(:model) do
      %{provider: key, model: model} = selection when is_binary(model) ->
        if provider_info(key), do: selection, else: default_selection()

      _ ->
        default_selection()
    end
  end

  defp default_selection do
    info = Enum.find(@providers, &(&1.module == provider())) || hd(@providers)
    model = info.module.default_model()
    %{provider: info.key, model: model, name: model}
  end

  @spec select(binary(), binary(), binary() | nil) :: :ok | {:error, binary()}
  def select(key, model, name \\ nil) do
    cond do
      provider_info(key) == nil ->
        {:error, "Unknown provider"}

      not is_binary(model) or String.trim(model) == "" ->
        {:error, "Choose a model"}

      true ->
        selection = %{provider: key, model: model, name: name || model}

        with :ok <- Settings.put(:model, selection) do
          Phoenix.PubSub.broadcast(Elia.PubSub, @selection_topic, {:llm_selection, selection})
        end
    end
  end

  @doc """
  Request fields for the stored selection, or none so the configured provider
  and model apply.
  """
  def selection_request do
    case Settings.get(:model) do
      %{provider: key, model: model} when is_binary(model) ->
        case provider_info(key) do
          %{module: module} -> %{provider: module, model: model}
          nil -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc "Models offered for a provider (cached, see `Elia.LLM.Catalog`)."
  def models(key), do: Catalog.models(key)
end
