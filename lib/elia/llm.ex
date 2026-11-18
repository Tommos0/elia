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
    %{
      key: "anthropic",
      name: "Anthropic",
      module: Elia.LLM.Anthropic,
      billing_url: "https://console.anthropic.com/settings/billing",
      keyless: false
    },
    %{
      key: "openrouter",
      name: "OpenRouter",
      module: Elia.LLM.OpenRouter,
      billing_url: "https://openrouter.ai/settings/credits",
      keyless: false
    },
    # LOCAL: a llama-server on this machine. No key, no credits (LOCAL-2,
    # LOCAL-7), and nothing to bill, so no `billing_url` (LLM-27).
    %{
      key: "llamacpp",
      name: "llama.cpp (local)",
      module: Elia.LLM.LlamaCpp,
      billing_url: nil,
      keyless: true
    }
  ]

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

  @doc """
  Whether a provider needs no API key (LOCAL-2, LLM-15).

  A keyless provider is used as easily with none as any other is with one: the
  model picker offers its models (MODEL-13), and the Settings page gives it the
  card of LOCAL-24 instead of a key field (CONF-9).
  """
  @spec keyless?(binary()) :: boolean()
  def keyless?(key), do: provider_info(key)[:keyless] == true

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

  ## Base URLs (a keyless provider's version of a key)

  @doc """
  The base URL a keyless provider talks to (LOCAL-3): the saved one, else the
  configured one. `nil` for a provider that has no such thing.
  """
  @spec base_url(binary()) :: binary() | nil
  def base_url(key) do
    with %{keyless: true, module: module} <- provider_info(key),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :base_url, 0) do
      module.base_url()
    else
      _ -> nil
    end
  end

  @doc "Verifies `url` against a keyless provider without storing it (LOCAL-24)."
  @spec check_base_url(binary(), binary()) :: :ok | {:error, binary()}
  def check_base_url(key, url) do
    case {provider_info(key), String.trim(url || "")} do
      {nil, _} -> {:error, "Unknown provider"}
      {_, ""} -> {:error, "Enter a base URL"}
      {%{module: module}, url} -> module.check_base_url(url)
    end
  end

  @doc "Checks `url` and stores it if the check passes (LOCAL-24)."
  @spec save_base_url(binary(), binary()) :: :ok | {:error, binary()}
  def save_base_url(key, url) do
    url = String.trim(url || "")

    with :ok <- check_base_url(key, url),
         :ok <- Settings.put({:base_url, key}, url) do
      Catalog.clear(key)
    end
  end

  def delete_base_url(key) do
    with :ok <- Settings.delete({:base_url, key}), do: Catalog.clear(key)
  end

  ## Credits

  @doc "Whether the provider can report a credit balance."
  @spec balance_supported?(binary()) :: boolean()
  def balance_supported?(key) do
    case provider_info(key) do
      %{module: module} -> Code.ensure_loaded?(module) and function_exported?(module, :balance, 1)
      nil -> false
    end
  end

  @doc "The credit balance for a provider's active key."
  @spec balance(binary()) ::
          {:ok, Elia.LLM.Provider.balance()} | {:error, binary()} | :unsupported
  def balance(key) do
    cond do
      not balance_supported?(key) ->
        :unsupported

      api_key = api_key(key) ->
        provider_info(key).module.balance(elem(api_key, 1))

      true ->
        {:error, "No API key"}
    end
  end

  ## Model selection

  @doc """
  The effective `%{provider, model, name}` for a chat, plus `context_length`
  when it was known at selection time.

  `chat_selection` is the chat's own selection (MODEL-1); when it is `nil` or
  names an unregistered provider, the stored default (the last choice made
  anywhere, MODEL-15) applies, and without one the configured provider and its
  default model (MODEL-2).
  """
  def selection(chat_selection \\ nil) do
    valid_selection(chat_selection) || valid_selection(Settings.get(:model)) ||
      default_selection()
  end

  @doc """
  The selection a chat without its own should pin when its first turn starts
  (MODEL-16): the stored default, else the configured default when its
  provider is registered, else `nil` (the configured provider applies as is).
  """
  def pinnable_selection do
    valid_selection(Settings.get(:model)) ||
      if Enum.any?(@providers, &(&1.module == provider())), do: default_selection()
  end

  defp valid_selection(%{provider: key, model: model} = selection) when is_binary(model) do
    if provider_info(key), do: selection
  end

  defp valid_selection(_), do: nil

  defp default_selection do
    info = Enum.find(@providers, &(&1.module == provider())) || hd(@providers)
    model = info.module.default_model()
    %{provider: info.key, model: model, name: model}
  end

  @doc """
  Builds a selection and remembers it as the default for chats without one
  (MODEL-15). The caller stores it on the chat (`Elia.Agent.select_model/4`).

  The selection records what the provider's catalog says about the model — its
  context length (CTX-7) and whether it accepts images (VISION-7) — asking the
  provider for its catalog when the cache doesn't hold one, so a picker's stale
  list can't leave them out. A catalog that can't be read leaves both unknown and
  the choice is made anyway (VISION-11).
  """
  @spec select(binary(), binary(), binary() | nil) :: {:ok, map()} | {:error, binary()}
  def select(key, model, name \\ nil) do
    cond do
      provider_info(key) == nil ->
        {:error, "Unknown provider"}

      not is_binary(model) or String.trim(model) == "" ->
        {:error, "Choose a model"}

      true ->
        entry = catalog_entry(key, model)

        selection =
          %{provider: key, model: model, name: name || model}
          |> put_context_length(entry[:context_length])
          |> put_vision(entry[:vision])

        with :ok <- Settings.put(:model, selection), do: {:ok, selection}
    end
  end

  @doc """
  Request fields for the chat's selection (else the stored default), or none
  so the configured provider and model apply.
  """
  def selection_request(chat_selection \\ nil) do
    case valid_selection(chat_selection) || valid_selection(Settings.get(:model)) do
      %{provider: key, model: model} -> %{provider: provider_info(key).module, model: model}
      nil -> %{}
    end
  end

  @doc "Models offered for a provider (cached, see `Elia.LLM.Catalog`)."
  def models(key), do: Catalog.models(key)

  ## Context window

  # Known context windows for Anthropic models when the catalog hasn't loaded
  # yet (the Models API reports them; this is only a local fallback so the
  # indicator works before the first picker fetch).
  @anthropic_context_window 200_000

  @doc """
  The selected model's context window in tokens, when known.

  Uses the catalog when its cache already holds the provider's models (never
  fetching), then the length stored with the selection, then a built-in
  default for Anthropic models, and returns `nil` when the window is genuinely
  unknown. A cached length the stored selection lacks is saved with it, so the
  window outlives the catalog cache (CTX-7).
  """
  @spec context_window(map() | nil) :: %{
          provider: binary(),
          model: binary(),
          context_length: pos_integer() | nil
        }
  def context_window(chat_selection \\ nil) do
    %{provider: provider, model: model} = selection = selection(chat_selection)
    cached = cached_context_length(provider, model)

    # Only a stored selection is updated; the configured default stays unstored.
    # The length goes with the selection the store holds as one update (CONF-29),
    # so a model chosen at the same moment is not overwritten with an older one.
    with length when is_integer(length) <- cached,
         true <- length != selection[:context_length] do
      Settings.update(:model, nil, fn
        %{provider: ^provider, model: ^model} -> put_context_length(selection, length)
        other -> other
      end)
    end

    context_length =
      cached || selection[:context_length] || fallback_context_length(selection.provider)

    Map.put(selection, :context_length, context_length)
  end

  defp cached_context_length(key, model) do
    with {:ok, models} <- Catalog.peek(key),
         %{context_length: length} when is_integer(length) and length > 0 <-
           Enum.find(models, &(&1.id == model)) do
      length
    else
      _ -> nil
    end
  end

  ## Images (VISION-7)

  @doc """
  Whether a chat's model accepts images (VISION-7), so a request knows to send
  the pictures a message carries (VISION-4).

  The answer is the cached catalog's for the model, else what the selection
  recorded when it was chosen, else the provider's own — never a catalog fetch,
  so asking costs nothing at every step of a turn.
  """
  @spec vision?(map() | nil) :: boolean()
  def vision?(chat_selection \\ nil) do
    %{provider: provider, model: model} = selection = selection(chat_selection)

    case cached_vision(provider, model) do
      nil ->
        case selection[:vision] do
          vision when is_boolean(vision) -> vision
          _unknown -> module_vision(provider_info(provider).module, model)
        end

      cached ->
        cached
    end
  end

  @doc """
  Whether the provider `module` accepts images for `model` (VISION-7), for a
  request that names its provider rather than a chat's selection (MODEL-3).

  A module that exports no `vision?/1` accepts none.
  """
  @spec module_vision(module(), binary() | nil) :: boolean()
  def module_vision(module, model) do
    if Code.ensure_loaded?(module) and function_exported?(module, :vision?, 1),
      do: module.vision?(model),
      else: false
  end

  defp cached_vision(key, model) do
    with {:ok, models} <- Catalog.peek(key),
         %{vision: vision} when is_boolean(vision) <- Enum.find(models, &(&1.id == model)) do
      vision
    else
      _ -> nil
    end
  end

  # VISION-7, CTX-7: what a choice records comes from the provider's catalog
  # whatever the age of the cache — its cached answer, else one fetched for the
  # choice (MODEL-8) — so a picker list that went stale can't leave the length or
  # the capability unrecorded. A catalog that can't be read, or doesn't list the
  # model, leaves the entry unknown and the choice stands (VISION-11).
  defp catalog_entry(key, model) do
    with {:ok, models} <- Catalog.models(key),
         %{} = entry <- Enum.find(models, &(&1.id == model)) do
      entry
    else
      _unknown -> %{}
    end
  end

  defp put_context_length(selection, nil), do: selection
  defp put_context_length(selection, length), do: Map.put(selection, :context_length, length)

  # VISION-7: the capability is recorded with the selection as the context window
  # is (CTX-7), so the chat's answer outlives the catalog cache. A model whose
  # catalog entry is unknown keeps no answer, and the provider's own applies.
  defp put_vision(selection, nil), do: selection
  defp put_vision(selection, vision), do: Map.put(selection, :vision, vision)

  defp fallback_context_length("anthropic"), do: @anthropic_context_window
  defp fallback_context_length(_provider), do: nil
end
