defmodule Elia.Push.Subscriptions do
  @moduledoc """
  The push subscriptions Elia may send to (PUSH-3, PUSH-4, PUSH-7, PUSH-16).

  They are kept in the settings database (`Elia.Settings`), beside the API keys
  (CONF): outside the workspace, so they are never committed or rolled back, and
  they survive a restart. An entry is what the browser itself reports, its
  endpoint and the two keys a payload is encrypted for (RFC 8291).

  A stored subscription is keyed by endpoint, so a device that subscribes again
  replaces its own entry instead of leaving a stale one behind (PUSH-3), and one
  the push service no longer knows is dropped by endpoint (PUSH-16). Anything
  that is not a usable subscription — a key of the wrong size, an endpoint that
  is not HTTPS — is refused rather than stored.
  """

  alias Elia.Settings

  @key "push_subscriptions"
  @p256dh_size 65
  @auth_size 16

  @doc "PUSH-3: the stored subscriptions."
  @spec list() :: [map()]
  def list do
    case Settings.get(@key, []) do
      subscriptions when is_list(subscriptions) -> Enum.filter(subscriptions, &valid?/1)
      _other -> []
    end
  end

  @doc "PUSH-7: how many subscriptions are stored."
  @spec count() :: non_neg_integer()
  def count, do: length(list())

  @doc """
  PUSH-3: store a browser's subscription, as `PushSubscription.toJSON/0` gives
  it. An endpoint that is already stored is replaced.
  """
  @spec save(map()) :: :ok | {:error, :invalid_subscription}
  def save(params) do
    case subscription(params) do
      {:ok, subscription} ->
        put(Enum.reject(list(), &(&1.endpoint == subscription.endpoint)) ++ [subscription])

      :error ->
        {:error, :invalid_subscription}
    end
  end

  @doc "PUSH-4, PUSH-16: forget one endpoint. An endpoint that isn't stored is fine."
  @spec remove(binary()) :: :ok
  def remove(endpoint) when is_binary(endpoint) do
    put(Enum.reject(list(), &(&1.endpoint == endpoint)))
  end

  @doc "PUSH-7: forget every subscription."
  @spec clear() :: :ok
  def clear, do: put([])

  @doc """
  Whether this is a subscription Elia can send to: an HTTPS endpoint and keys of
  the sizes RFC 8291 expects.
  """
  @spec valid?(term()) :: boolean()
  def valid?(%{endpoint: endpoint, p256dh: p256dh, auth: auth}) do
    is_binary(endpoint) and String.starts_with?(endpoint, "https://") and
      key?(p256dh, @p256dh_size) and key?(auth, @auth_size)
  end

  def valid?(_other), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  defp put(subscriptions) do
    case Settings.put(@key, subscriptions) do
      :ok -> :ok
      error -> error
    end
  end

  # The browser reports a subscription as {"endpoint": ..., "keys": {...}}.
  defp subscription(%{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}}) do
    subscription = %{endpoint: endpoint, p256dh: p256dh, auth: auth}
    if valid?(subscription), do: {:ok, subscription}, else: :error
  end

  defp subscription(_params), do: :error

  defp key?(value, size) when is_binary(value) do
    match?({:ok, key} when byte_size(key) == size, Base.url_decode64(value, padding: false))
  end

  defp key?(_value, _size), do: false
end
