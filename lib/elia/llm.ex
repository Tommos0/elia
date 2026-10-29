defmodule Elia.LLM do
  @moduledoc """
  Entry point for model calls. Dispatches to the configured provider:

      config :elia, Elia.LLM, provider: Elia.LLM.Anthropic
  """

  @spec stream(Elia.LLM.Provider.request(), (Elia.LLM.Provider.event() -> any())) ::
          {:ok, Elia.LLM.Provider.response()} | {:error, term()}
  def stream(request, on_event \\ fn _ -> :ok end) do
    {provider, request} = Map.pop(request, :provider, provider())
    provider.stream(request, on_event)
  end

  def provider, do: Application.get_env(:elia, __MODULE__, [])[:provider] || Elia.LLM.Anthropic
end
