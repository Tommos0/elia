defmodule Elia.PushTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase
  import Elia.PushCase

  alias Elia.Push
  alias Elia.Push.Subscriptions

  setup do
    reset_settings()
    configure(Push)
    stub_push_service()
    on_exit(&reset_push/0)
    :ok
  end

  # PUSH-1
  test "the VAPID key pair is generated on first use and kept" do
    assert Elia.Settings.get("push_vapid_keys") == nil

    keys = Push.keys()
    assert Elia.Settings.get("push_vapid_keys") == keys
    assert Push.public_key() == keys.public

    # The same pair is handed out again, and it is a pair.
    assert Push.keys() == keys
    assert Elia.Push.Crypto.public_key(keys.private) == keys.public
  end

  # PUSH-18
  test "the VAPID contact defaults to a mailto: URL and is configurable" do
    assert Push.subject() == "mailto:elia@localhost"

    Application.put_env(:elia, Push,
      req_options: [plug: {Req.Test, Push}],
      subject: "mailto:me@example.com"
    )

    assert Push.subject() == "mailto:me@example.com"
  end

  # PUSH-9, PUSH-11, PUSH-12
  test "a chat's payload says which chat needs the user and why" do
    id = Elia.Agent.new_id()
    on_exit(fn -> Elia.Store.delete(id) end)

    approval = Push.chat_payload(id, :approval)
    assert approval.url == "/c/" <> id
    assert approval.tag == "chat-" <> id
    assert approval.icon == "/images/icon-192.png"
    assert approval.body == "Needs your approval."

    assert Push.chat_payload(id, :input).body == "Needs your answer."
    assert Push.chat_payload(id, :finished).body == "Finished."
    assert Push.chat_payload(id, :paused).body == "Paused at a limit."

    # The title is the chat's own (TITLE-1), and a chat that has one shows it.
    assert approval.title == "New chat"

    :ok = Elia.Store.save(id, [Elia.LLM.Message.user("hi")], title: "Deploy the thing")
    assert Push.chat_payload(id, :approval).title == "Deploy the thing"
  end

  # PUSH-9, PUSH-15
  test "a notification is encrypted for the subscription and signed with VAPID" do
    receiver = store()
    payload = Push.chat_payload(Elia.Agent.new_id(), :finished)

    # The headers Elia builds (PUSH-15). `content-encoding` is checked here and
    # not at the stub because Req.Test's plug adapter decompresses a request body
    # that carries it and drops the header (`Req.Plug.run/2`).
    built = Push.request_headers(hd(Subscriptions.list()), payload)
    assert {"content-encoding", "aes128gcm"} in built
    assert {"content-type", "application/octet-stream"} in built
    assert {"ttl", "86400"} in built
    assert {"topic", payload.tag} in built

    assert %{sent: 1, gone: 0, failed: 0} = Push.deliver(payload)
    assert_receive {:push_request, "/sub/1", header_list, body}

    headers = headers(header_list)
    assert headers["ttl"] == "86400"
    assert headers["topic"] == payload.tag

    # The authorization header is a VAPID JWT for this endpoint's origin, signed
    # with the app's key (PUSH-15).
    assert [_, token, public] =
             Regex.run(~r/\Avapid t=([^,]+), k=(.+)\z/, headers["authorization"])

    assert public == Push.public_key()

    assert [_, claims, _signature] = String.split(token, ".")
    assert Jason.decode!(decode64(claims))["aud"] == "https://push.example.net"

    # The body is one aes128gcm record, and it holds the payload (PUSH-9).
    assert byte_size(body) == 86 + byte_size(Jason.encode!(payload)) + 1 + 16

    sent = decoded_payload(body, receiver)
    assert sent["title"] == payload.title
    assert sent["body"] == "Finished."
    assert sent["url"] == payload.url
    assert sent["tag"] == payload.tag
    assert sent["icon"] == payload.icon
  end

  # PUSH-15
  test "each device gets its own encryption of the payload" do
    first = store("https://push.example.net/sub/1")
    second = store("https://push.example.net/sub/2")

    assert %{sent: 2} = Push.deliver(Push.chat_payload(Elia.Agent.new_id(), :finished))

    assert_receive {:push_request, "/sub/1", _, one}
    assert_receive {:push_request, "/sub/2", _, two}

    refute one == two
    # Both decrypt to the same payload, each with its own subscription's keys.
    assert decoded_payload(one, first)["body"] == "Finished."
    assert decoded_payload(two, second)["body"] == "Finished."
  end

  # PUSH-16
  test "a subscription the push service no longer has is removed" do
    for status <- [404, 410] do
      stub_push_service(status)
      store("https://push.example.net/sub/#{status}")

      assert %{sent: 0, gone: 1, failed: 0} =
               Push.deliver(Push.chat_payload(Elia.Agent.new_id(), :finished))

      assert Subscriptions.count() == 0
    end
  end

  # PUSH-17
  test "a push service that fails is logged and counted, and the subscription is kept" do
    stub_push_service(500)
    store()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %{sent: 0, gone: 0, failed: 1} =
                 Push.deliver(Push.chat_payload(Elia.Agent.new_id(), :finished))
      end)

    assert log =~ "push:"
    assert Subscriptions.count() == 1
  end

  # PUSH-17
  test "a transport failure does not reach the caller" do
    Req.Test.stub(Push, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
    store()

    assert %{sent: 0, gone: 0, failed: 1} =
             Push.deliver(Push.chat_payload(Elia.Agent.new_id(), :finished))
  end

  # PUSH-17
  test "notify/1 sends from another process and returns at once" do
    store()
    payload = Push.chat_payload(Elia.Agent.new_id(), :approval)

    assert Push.notify(payload) == :ok
    assert_receive {:push_request, "/sub/1", _headers, _body}, 2_000
  end

  # PUSH-8
  test "the test notification goes to every subscription, and says when there is none" do
    assert Push.test_notification() == {:error, :no_subscriptions}

    receiver = store()
    assert {:ok, %{sent: 1, gone: 0, failed: 0}} = Push.test_notification()
    assert_receive {:push_request, "/sub/1", _headers, body}

    sent = decoded_payload(body, receiver)
    assert sent["title"] == "Elia"
    assert sent["url"] == "/"
    assert sent["tag"] == "elia-test"
    assert sent["body"] == "Test notification: push works."
  end

  defp decode64(value), do: Base.url_decode64!(value, padding: false)
end
