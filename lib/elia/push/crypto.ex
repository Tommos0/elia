defmodule Elia.Push.Crypto do
  @moduledoc """
  The cryptography of Web Push, with no process, no state and no HTTP.

  Three things live here, all of them `:crypto`:

    * `keypair/0` — the VAPID key pair (RFC 8292) Elia signs its requests with,
      generated once and kept in the settings database (PUSH-1).
    * `authorization_header/3` — that signature, an ES256 JWT over
      `{aud, exp, sub}` (PUSH-15).
    * `encrypt/3` — the `aes128gcm` payload encryption of RFC 8291, so the push
      service that carries the message cannot read it (PUSH-15).

  Every value the two RFCs pin down is checked against their own test vectors
  in `test/elia/push_crypto_test.exs`: the intermediate derivations and the
  whole encrypted body of RFC 8291 section 5, and a VAPID JWT verified back
  through its signature.
  """

  # RFC 8292 allows up to 24 hours of validity; 12 leaves room for clock drift.
  @expires_in 12 * 3600
  @jwt_header ~s({"typ":"JWT","alg":"ES256"})

  @doc """
  PUSH-1: a fresh VAPID key pair (P-256), URL-safe base64 without padding.
  """
  @spec keypair() :: %{public: binary(), private: binary()}
  def keypair do
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public: b64(public), private: b64(private)}
  end

  @doc """
  PUSH-1: the public key that belongs to a private one, so that a pair read
  back from the settings database can be checked before it is used.
  """
  @spec public_key(binary()) :: binary()
  def public_key(private) do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1, unb64(private))
    b64(public)
  end

  @doc """
  PUSH-15: the `Authorization` header value for a request to `endpoint`, in the
  RFC 8292 form `vapid t=<jwt>, k=<public key>`.

  `keys` is a VAPID key pair, `subject` the contact of PUSH-18.
  """
  @spec authorization_header(binary(), map(), binary()) :: binary()
  def authorization_header(endpoint, keys, subject) do
    jwt = jwt(endpoint, keys, subject)

    "vapid t=#{jwt.signing_input <> "." <> b64(jwt.raw)}, k=#{keys.public}"
  end

  @doc """
  PUSH-15: the parts of the VAPID JWT for `endpoint`, so a test can verify the
  signature: the signing input, the raw `r || s` signature JWS carries, and the
  DER form `:crypto.sign/4` returned, plus the claims it was signed over.
  """
  @spec jwt(binary(), map(), binary(), keyword()) :: map()
  def jwt(endpoint, keys, subject, opts \\ []) do
    expires = System.system_time(:second) + Keyword.get(opts, :expires_in, @expires_in)
    aud = audience(endpoint)

    signing_input =
      b64(@jwt_header) <>
        "." <> b64(Jason.encode!(%{"aud" => aud, "exp" => expires, "sub" => subject}))

    der = :crypto.sign(:ecdsa, :sha256, signing_input, [unb64(keys.private), :secp256r1])

    %{
      signing_input: signing_input,
      der: der,
      raw: der_to_raw(der),
      aud: aud,
      exp: expires,
      sub: subject
    }
  end

  @doc """
  PUSH-15: the audience of a VAPID JWT (RFC 8292): the endpoint's origin, with
  a port only when it isn't the scheme's default.
  """
  @spec audience(binary()) :: binary()
  def audience(endpoint) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    default = if scheme == "https", do: 443, else: 80

    if port && port != default,
      do: "#{scheme}://#{host}:#{port}",
      else: "#{scheme}://#{host}"
  end

  @doc """
  PUSH-15: the body to POST, `plaintext` encrypted for a subscription (RFC 8291,
  `aes128gcm` content coding). A fresh application-server key pair and salt are
  made for every call.

  `opts` may pin `:keys` (a raw `{public, private}` pair) and `:salt`, which is
  how the RFC's test vector is reproduced; nothing else should.

  `{:error, :invalid_subscription}` for a subscription whose keys are not a
  P-256 point and a 16-octet authentication secret.
  """
  @spec encrypt(binary(), map(), keyword()) :: {:ok, binary()} | {:error, :invalid_subscription}
  def encrypt(plaintext, subscription, opts \\ []) when is_binary(plaintext) do
    %{p256dh: p256dh, auth: auth} = subscription

    with {:ok, ua_public} <- decode_key(p256dh, 65),
         {:ok, auth_secret} <- decode_key(auth, 16) do
      {as_public, as_private} =
        Keyword.get_lazy(opts, :keys, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

      salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

      # RFC 8291 section 3.3: the ECDH secret combined with the authentication
      # secret gives the input keying material of RFC 8188.
      shared = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
      prk_key = hmac(auth_secret, shared)
      ikm = expand(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)

      # RFC 8188: the content encryption key and nonce from the salt and the IKM.
      prk = hmac(salt, ikm)
      cek = expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
      nonce = expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

      # One record, so the padding delimiter is 0x02, the "last record" octet
      # (RFC 8188 section 2). A receiving agent rejects any other value.
      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, plaintext <> <<2>>, <<>>, true)

      # The aes128gcm header: salt, record size, keyid length, keyid (the
      # application server's public key), then the ciphertext and its tag.
      header = salt <> <<4096::32>> <> <<byte_size(as_public)>> <> as_public

      {:ok, header <> ciphertext <> tag}
    else
      :error -> {:error, :invalid_subscription}
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp decode_key(value, size) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, key} when byte_size(key) == size -> {:ok, key}
      _ -> :error
    end
  end

  defp decode_key(_value, _size), do: :error

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  # HKDF-Expand (RFC 5869) over a single block: every use here needs at most the
  # 32 octets a SHA-256 HMAC produces.
  defp expand(prk, info, length) when length <= 32 do
    prk |> hmac(info <> <<1>>) |> binary_part(0, length)
  end

  # JWS carries an ES256 signature as raw r || s; :crypto hands back a DER
  # SEQUENCE of two INTEGERs, which may each be shorter than 32 octets.
  defp der_to_raw(<<0x30, _length, 0x02, r_length, rest::binary>>) do
    <<r::binary-size(r_length), 0x02, s_length, s::binary-size(s_length)>> = rest
    pad(r) <> pad(s)
  end

  defp pad(integer) do
    integer = trim(integer)
    <<0::size((32 - byte_size(integer)) * 8), integer::binary>>
  end

  defp trim(<<0, rest::binary>>) when byte_size(rest) > 0, do: trim(rest)
  defp trim(integer), do: integer

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp unb64(str), do: Base.url_decode64!(str, padding: false)
end
