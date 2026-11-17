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

  # PUSH-26
  test "subscriptions saved at the same time are all stored" do
    endpoints = for n <- 1..16, do: "https://push.example.net/sub/#{n}"
    receivers = for _ <- endpoints, do: receiver()

    suspend_settings()

    savers =
      for {receiver, endpoint} <- Enum.zip(receivers, endpoints) do
        Task.async(fn -> Subscriptions.save(subscription(receiver, endpoint)) end)
      end

    assert wait_queued(16) == :ok
    resume_settings()

    assert Enum.all?(savers, &(Task.await(&1) == :ok))
    assert Enum.sort(Enum.map(Subscriptions.list(), & &1.endpoint)) == Enum.sort(endpoints)
  end

  # PUSH-26
  test "changes carried out in an order leave what that order leaves" do
    first = receiver()
    second = receiver()
    one = "https://push.example.net/sub/1"
    two = "https://push.example.net/sub/2"

    changes = [
      fn -> Subscriptions.save(subscription(first, one)) end,
      fn -> Subscriptions.save(subscription(second, two)) end,
      fn -> Subscriptions.remove(one) end,
      fn -> Subscriptions.save(subscription(first, one)) end
    ]

    suspend_settings()

    # Each change is let go once the one before it is waiting in the settings
    # process, so this is the order they are carried out in: one saved, two
    # saved, one removed, one saved again.
    changers =
      changes
      |> Enum.map(fn change ->
        Task.async(fn ->
          receive do
            :go -> change.()
          end
        end)
      end)
      |> Enum.with_index(1)
      |> Enum.map(fn {changer, position} ->
        send(changer.pid, :go)
        assert wait_queued(position) == :ok
        changer
      end)

    resume_settings()

    assert Enum.all?(changers, &(Task.await(&1) == :ok))

    # A save that came after the removal stored it again, and the store is what
    # that order leaves rather than what any one racer read.
    assert Enum.map(Subscriptions.list(), & &1.endpoint) == [two, one]
  end
end
