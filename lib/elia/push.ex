defmodule Elia.Push do
  @moduledoc """
  Web Push: telling the user's device that a chat needs them
  (`specs/push-notifications.md`).

  `keys/0` is the VAPID key pair Elia signs its requests with (PUSH-1),
  `Subscriptions` the devices it may send to, and `deliver/1` the send itself:
  the payload is encrypted for each subscription (RFC 8291) and POSTed to that
  subscription's push service endpoint with a VAPID signature (RFC 8292).
  `notify/1` is the same off the caller's process, which is what
  `Elia.Push.Notifier` uses (PUSH-17).

  Sending is best-effort: a push service that is unhappy is logged, one that
  answers 404 or 410 means that subscription is gone (PUSH-16), and neither
  reaches the caller as a failure — a turn that ends notifies, or doesn't, in
  the same way.

  Everything the browser needs is in the payload (PUSH-9). Configuration, in
  `config/runtime.exs` or the test env:

      config :elia, Elia.Push, subject: "mailto:me@example.com", req_options: []
  """

  require Logger

  alias Elia.Push.{Crypto, Subscriptions}

  @vapid_key "push_vapid_keys"
  @default_subject "mailto:elia@localhost"
  @icon "/images/icon-192.png"
  @ttl 86_400
  @receive_timeout 15_000
  @defaults [subject: nil, req_options: []]
  # RFC 8030: a Topic header is at most 32 characters of the URL-safe base64
  # alphabet, which is what lets the push service drop the pending notification
  # it replaces (PUSH-9).
  @topic_format ~r/\A[A-Za-z0-9_-]{1,32}\z/

  @doc """
  PUSH-1: the VAPID key pair, generated on first use and kept in the settings
  database so that subscriptions made before a restart keep working.
  """
  @spec keys() :: %{public: binary(), private: binary()}
  def keys do
    case Elia.Settings.get(@vapid_key) do
      %{public: public, private: private} = keys when is_binary(public) and is_binary(private) ->
        keys

      _other ->
        generate_keys()
    end
  end

  @doc "PUSH-2: the public key a browser subscribes with."
  @spec public_key() :: binary()
  def public_key, do: keys().public

  @doc "PUSH-18: the contact put in the VAPID JWT."
  @spec subject() :: binary()
  def subject, do: config()[:subject] || @default_subject

  @doc """
  PUSH-9, PUSH-11, PUSH-12: the payload for a chat that needs the user, for the
  reason `Elia.Push.Notifier.reason/2` decided.
  """
  @spec chat_payload(binary(), atom()) :: map()
  def chat_payload(chat_id, reason) do
    %{
      title: title(chat_id),
      body: body(reason),
      url: "/c/" <> chat_id,
      tag: "chat-" <> chat_id,
      icon: @icon
    }
  end

  @doc """
  PUSH-8: send the test notification, so the user can see that push works from
  end to end. `{:error, :no_subscriptions}` when there is nowhere to send it;
  otherwise the tally of `deliver/1`.
  """
  @spec test_notification() :: {:ok, map()} | {:error, :no_subscriptions}
  def test_notification do
    case Subscriptions.count() do
      0 ->
        {:error, :no_subscriptions}

      _count ->
        {:ok,
         deliver(%{
           title: "Elia",
           body: "Test notification: push works.",
           url: "/",
           tag: "elia-test",
           icon: @icon
         })}
    end
  end

  @doc """
  PUSH-17: send `payload` to every subscription, off the caller's process, so
  that a slow push service never holds up a turn or a page.
  """
  @spec notify(map()) :: :ok
  def notify(payload) do
    Task.Supervisor.start_child(Elia.Agent.TaskSupervisor, fn -> deliver(payload) end)
    :ok
  end

  @doc """
  PUSH-16, PUSH-17: send `payload` to every subscription and count what
  happened: `sent`, `gone` (a subscription the push service no longer has, which
  is removed here) and `failed`.
  """
  @spec deliver(map()) :: %{
          sent: non_neg_integer(),
          gone: non_neg_integer(),
          failed: non_neg_integer()
        }
  def deliver(payload) do
    Enum.reduce(Subscriptions.list(), %{sent: 0, gone: 0, failed: 0}, fn subscription, tally ->
      case send_to(subscription, payload) do
        :ok ->
          %{tally | sent: tally.sent + 1}

        {:error, :gone} ->
          Subscriptions.remove(subscription.endpoint)
          %{tally | gone: tally.gone + 1}

        {:error, reason} ->
          Logger.warning("push: #{inspect(reason)} sending to #{subscription.endpoint}")
          %{tally | failed: tally.failed + 1}
      end
    end)
  end

  @doc """
  PUSH-15, PUSH-16: send one payload to one subscription: encrypted for it, with
  a VAPID authorization header. `:ok`, `{:error, :gone}` when the push service
  no longer knows it, or `{:error, reason}` for anything else.
  """
  @spec send_to(map(), map()) :: :ok | {:error, :gone} | {:error, term()}
  def send_to(subscription, payload) do
    case Crypto.encrypt(Jason.encode!(payload), subscription) do
      {:ok, body} ->
        classify(post(subscription.endpoint, body, request_headers(subscription, payload)))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp generate_keys do
    keys = Crypto.keypair()
    :ok = Elia.Settings.put(@vapid_key, keys)
    keys
  end

  defp config, do: Keyword.merge(@defaults, Application.get_env(:elia, __MODULE__, []))

  defp req_options, do: config()[:req_options] || []

  defp post(endpoint, body, headers) do
    Req.post(
      [
        url: endpoint,
        body: body,
        headers: headers,
        receive_timeout: @receive_timeout
      ] ++ req_options()
    )
  end

  @doc """
  PUSH-15: the headers the request to `subscription`'s endpoint carries. Public
  because a test has to look at them: Req's `Req.Test` plug adapter decompresses
  a request body that has a `content-encoding` header and drops that header
  (`Req.Plug.run/2`), and it is the one header a push service insists on.
  """
  @spec request_headers(map(), map()) :: [{binary(), binary()}]
  def request_headers(subscription, payload) do
    [
      {"authorization", Crypto.authorization_header(subscription.endpoint, keys(), subject())},
      {"content-encoding", "aes128gcm"},
      {"content-type", "application/octet-stream"},
      {"ttl", Integer.to_string(@ttl)}
    ] ++ topic_headers(payload)
  end

  defp topic_headers(%{tag: tag}) when is_binary(tag) do
    if Regex.match?(@topic_format, tag), do: [{"topic", tag}], else: []
  end

  defp topic_headers(_payload), do: []

  defp classify({:ok, %{status: status}}) when status in [200, 201, 202, 204], do: :ok
  defp classify({:ok, %{status: status}}) when status in [404, 410], do: {:error, :gone}
  defp classify({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp classify({:error, reason}), do: {:error, reason}

  defp title(chat_id), do: Elia.Store.chat_title(chat_id) || "Elia"

  defp body(:approval), do: "Needs your approval."
  defp body(:input), do: "Needs your answer."
  defp body(:finished), do: "Finished."
  defp body(:paused), do: "Paused at a limit."
  defp body(_reason), do: "Needs you."
end
