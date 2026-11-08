defmodule Elia.PushCase do
  @moduledoc """
  Helpers for the push tests (`specs/push-notifications.md`): a receiver, the
  subscription a browser would report for it, a stored subscription, the push
  service stub, and the decryption a browser does on the way in.

  `decrypt/2` is the receiving end of RFC 8291 — the same derivations as
  `Elia.Push.Crypto.encrypt/3`, run from the subscription's own private key and
  authentication secret — so a test can look at the payload the browser's
  service worker would hand to `push`. It is deliberately written out here
  rather than shared with the sending side: the RFC's test vector already
  pins that side down, and this one has to agree with it independently.

  Push subscriptions and the VAPID key pair live in the settings database, so
  these tests are not async (`Elia.LLMCase.reset_settings/0`).
  """

  alias Elia.Push.Subscriptions

  @endpoint "https://push.example.net/sub/1"

  @doc "The receiver side of a subscription: the keys a browser generates and keeps."
  def receiver do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public: public, private: private, auth: :crypto.strong_rand_bytes(16)}
  end

  @doc "PUSH-3: the subscription a browser reports for a receiver."
  def subscription(receiver, endpoint \\ @endpoint) do
    %{
      "endpoint" => endpoint,
      "expirationTime" => nil,
      "keys" => %{"p256dh" => b64(receiver.public), "auth" => b64(receiver.auth)}
    }
  end

  @doc "PUSH-3: store a subscription for a fresh receiver, and return the receiver."
  def store(endpoint \\ @endpoint) do
    receiver = receiver()
    :ok = Subscriptions.save(subscription(receiver, endpoint))
    receiver
  end

  @doc """
  A `Req.Test` stub standing in for a push service, which answers `status` to
  every request and reports each one to the test process as
  `{:push_request, path, header_list, body}`.
  """
  def stub_push_service(status \\ 201) do
    test = self()

    Req.Test.stub(Elia.Push, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:push_request, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  @doc """
  Forget the stored subscriptions and the VAPID key pair, so a test leaves
  nothing behind for another test file (they share the settings database).
  """
  def reset_push do
    Subscriptions.clear()
    Elia.Settings.delete("push_vapid_keys")
  end

  @doc "A request's headers as a map, for assertions."
  def headers(header_list), do: Map.new(header_list)

  @doc """
  PUSH-9, PUSH-15: what the browser makes of the body Elia sent, as the JSON
  object the service worker's `push` event carries.
  """
  def decoded_payload(body, receiver) do
    body
    |> decrypt(receiver)
    |> Jason.decode!()
  end

  @doc "PUSH-15: RFC 8291 decryption of a push body, as a receiving agent does it."
  def decrypt(body, receiver) do
    # The aes128gcm header: salt, record size, keyid length, keyid.
    <<salt::binary-size(16), _record_size::size(32), keyid_length::size(8), rest::binary>> = body
    <<as_public::binary-size(keyid_length), encrypted::binary>> = rest

    shared = :crypto.compute_key(:ecdh, as_public, receiver.private, :prime256v1)
    prk_key = hmac(receiver.auth, shared)
    key_info = "WebPush: info" <> <<0>> <> receiver.public <> as_public
    ikm = expand(prk_key, key_info, 32)

    prk = hmac(salt, ikm)
    cek = expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    ciphertext_size = byte_size(encrypted) - 16
    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(16)>> = encrypted

    plaintext =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)

    # One record, so the last octet is the 0x02 padding delimiter (RFC 8188).
    payload_size = byte_size(plaintext) - 1
    <<payload::binary-size(payload_size), 0x02>> = plaintext
    payload
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp expand(prk, info, length), do: binary_part(hmac(prk, info <> <<1>>), 0, length)

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
