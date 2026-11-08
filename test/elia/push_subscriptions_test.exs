defmodule Elia.Push.SubscriptionsTest do
  use ExUnit.Case, async: false

  import Elia.LLMCase
  import Elia.PushCase

  alias Elia.Push.Subscriptions

  setup do
    reset_settings()
    on_exit(&reset_push/0)
    :ok
  end

  # PUSH-3
  test "a subscription is stored as the browser reported it" do
    receiver = receiver()
    assert :ok = Subscriptions.save(subscription(receiver))

    assert [stored] = Subscriptions.list()
    assert stored.endpoint == "https://push.example.net/sub/1"
    assert stored.p256dh == Base.url_encode64(receiver.public, padding: false)
    assert stored.auth == Base.url_encode64(receiver.auth, padding: false)
    assert Subscriptions.count() == 1
  end

  # PUSH-3
  test "subscribing one endpoint twice replaces its entry" do
    assert :ok = Subscriptions.save(subscription(receiver()))
    assert :ok = Subscriptions.save(subscription(receiver()))

    assert Subscriptions.count() == 1
  end

  # PUSH-3
  test "a subscription is keyed by endpoint, so two devices are two entries" do
    first = receiver()
    second = receiver()

    assert :ok = Subscriptions.save(subscription(first, "https://push.example.net/sub/1"))
    assert :ok = Subscriptions.save(subscription(second, "https://push.example.net/sub/2"))

    assert Subscriptions.count() == 2

    assert Enum.map(Subscriptions.list(), & &1.endpoint) == [
             "https://push.example.net/sub/1",
             "https://push.example.net/sub/2"
           ]
  end

  # PUSH-3
  test "a subscription Elia cannot use is refused" do
    good = subscription(receiver())
    %{"keys" => keys} = good

    bad = [
      # Not HTTPS: a push endpoint always is.
      %{good | "endpoint" => "http://push.example.net/sub/1"},
      %{good | "endpoint" => nil},
      %{good | "keys" => %{keys | "p256dh" => "AAAA"}},
      %{good | "keys" => %{keys | "auth" => "AAAA"}},
      %{good | "keys" => %{keys | "auth" => "not base64!"}},
      %{good | "keys" => %{}},
      %{"endpoint" => good["endpoint"]},
      %{}
    ]

    for params <- bad do
      assert Subscriptions.save(params) == {:error, :invalid_subscription}
    end

    assert Subscriptions.save("not a subscription") == {:error, :invalid_subscription}
    assert Subscriptions.count() == 0
  end

  # PUSH-4, PUSH-16
  test "removing an endpoint forgets just that one" do
    :ok = Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/1"))
    :ok = Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/2"))

    assert :ok = Subscriptions.remove("https://push.example.net/sub/1")
    assert [%{endpoint: "https://push.example.net/sub/2"}] = Subscriptions.list()

    # An endpoint that isn't stored is simply not there.
    assert :ok = Subscriptions.remove("https://push.example.net/sub/gone")
    assert Subscriptions.count() == 1
  end

  # PUSH-7
  test "clear/0 forgets them all" do
    :ok = Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/1"))
    :ok = Subscriptions.save(subscription(receiver(), "https://push.example.net/sub/2"))
    assert Subscriptions.count() == 2

    assert :ok = Subscriptions.clear()
    assert Subscriptions.list() == []
    assert Subscriptions.count() == 0
  end
end
