defmodule Elia.Push.CryptoTest do
  use ExUnit.Case, async: true

  alias Elia.Push.Crypto

  # The example of RFC 8291 section 5, whose intermediate values are listed in
  # its Appendix A.
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIg" <>
               "Dll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx" <>
               "aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @plaintext "When I grow up, I want to be a watermelon"

  @body "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" <>
          "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" <>
          "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  # PUSH-1
  test "a key pair's public key is the one its private key derives" do
    %{public: public, private: private} = Crypto.keypair()

    assert Crypto.public_key(private) == public
    assert byte_size(decode(public)) == 65
    assert byte_size(decode(private)) == 32

    # A second pair is a different pair.
    refute Crypto.keypair().public == public
  end

  # PUSH-15
  test "the encrypted body is the one RFC 8291 section 5 gives" do
    subscription = %{p256dh: @ua_public, auth: @auth}
    keys = {decode(@as_public), decode(@as_private)}

    # The RFC's own private key is the one belonging to its public key.
    assert Crypto.public_key(@as_private) == @as_public

    assert {:ok, body} = Crypto.encrypt(@plaintext, subscription, keys: keys, salt: decode(@salt))
    assert body == decode(@body)

    # 86 octets of header (salt, record size, keyid length, keyid), the
    # ciphertext, and the 16-octet authentication tag.
    assert byte_size(body) == 86 + byte_size(@plaintext) + 1 + 16
    assert binary_part(body, 0, 16) == decode(@salt)
    assert binary_part(body, 16, 4) == <<4096::32>>
    assert binary_part(body, 20, 1) == <<65>>
    assert binary_part(body, 21, 65) == decode(@as_public)
  end

  # PUSH-15
  test "every call encrypts with a fresh key pair and salt" do
    subscription = %{p256dh: @ua_public, auth: @auth}

    assert {:ok, one} = Crypto.encrypt("hello", subscription)
    assert {:ok, two} = Crypto.encrypt("hello", subscription)

    refute one == two
    refute binary_part(one, 0, 16) == binary_part(two, 0, 16)
    refute binary_part(one, 21, 65) == binary_part(two, 21, 65)
  end

  # PUSH-15
  test "a subscription that is not a P-256 point and a 16-octet secret is refused" do
    good = %{p256dh: @ua_public, auth: @auth}

    assert {:error, :invalid_subscription} = Crypto.encrypt("hello", %{good | p256dh: "AAAA"})
    assert {:error, :invalid_subscription} = Crypto.encrypt("hello", %{good | auth: "AAAA"})

    assert {:error, :invalid_subscription} =
             Crypto.encrypt("hello", %{good | auth: "not base64!"})

    assert {:error, :invalid_subscription} = Crypto.encrypt("hello", %{p256dh: nil, auth: @auth})
  end

  # PUSH-15
  test "the authorization header is a VAPID JWT over the endpoint's audience" do
    keys = Crypto.keypair()
    endpoint = "https://fcm.googleapis.com/fcm/send/abc123"

    header = Crypto.authorization_header(endpoint, keys, "mailto:me@example.com")

    assert [_, token, public] = Regex.run(~r/\Avapid t=([^,]+), k=(.+)\z/, header)
    assert public == keys.public

    assert [header_b64, claims_b64, signature_b64] = String.split(token, ".")
    assert decode(header_b64) == ~s({"typ":"JWT","alg":"ES256"})

    claims = Jason.decode!(decode(claims_b64))
    assert claims["aud"] == "https://fcm.googleapis.com"
    assert claims["sub"] == "mailto:me@example.com"

    now = System.system_time(:second)
    assert claims["exp"] > now
    assert claims["exp"] <= now + 24 * 3600

    # The signature is a real ES256 one over the signing input, which the
    # public key in `k=` verifies.
    assert :crypto.verify(
             :ecdsa,
             :sha256,
             header_b64 <> "." <> claims_b64,
             der_signature(decode(signature_b64)),
             [decode(keys.public), :secp256r1]
           )
  end

  # PUSH-15
  test "the audience keeps a non-default port and drops a default one" do
    assert Crypto.audience("https://fcm.googleapis.com/fcm/send/abc") ==
             "https://fcm.googleapis.com"

    assert Crypto.audience("https://push.example.net:8443/sub/1") ==
             "https://push.example.net:8443"

    assert Crypto.audience("http://localhost:7000/push") == "http://localhost:7000"
  end

  defp decode(value), do: Base.url_decode64!(value, padding: false)

  # JWS carries an ES256 signature as raw r || s, while :crypto.verify/5 wants
  # the DER SEQUENCE :crypto.sign/4 returned: this undoes what the module does.
  defp der_signature(raw) do
    <<r::binary-size(32), s::binary-size(32)>> = raw
    r = der_integer(r)
    s = der_integer(s)
    body = <<0x02, byte_size(r)>> <> r <> <<0x02, byte_size(s)>> <> s
    <<0x30, byte_size(body)>> <> body
  end

  defp der_integer(integer) do
    integer = trim(integer)
    if :binary.first(integer) > 127, do: <<0>> <> integer, else: integer
  end

  defp trim(<<0, rest::binary>>) when byte_size(rest) > 0, do: trim(rest)
  defp trim(integer), do: integer
end
