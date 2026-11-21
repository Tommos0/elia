defmodule Elia.NetTest do
  use ExUnit.Case, async: true

  alias Elia.Net

  # NET-1: three modes, and a setting that names none of them is unrestricted.
  test "a setting is one of three modes, and anything else is unrestricted" do
    assert Net.modes() == [:unrestricted, :allowlist, :none]

    assert Net.mode(%{mode: :allowlist}) == :allowlist
    assert Net.mode(%{mode: :none}) == :none
    assert Net.mode(%{mode: :unrestricted}) == :unrestricted
    assert Net.mode(%{mode: :something}) == :unrestricted
    assert Net.mode(nil) == :unrestricted
    assert Net.mode("none") == :unrestricted

    assert Net.default() == %{mode: :unrestricted, hosts: []}
    refute Net.limited?(Net.default())
    assert Net.limited?(%{mode: :none})
    assert Net.limited?(%{mode: :allowlist, hosts: []})
  end

  # NET-1: the hosts a setting names are the entries of NET-7, cleaned.
  test "the hosts of a setting are read through" do
    assert Net.hosts(%{mode: :allowlist, hosts: ["API.example.com", "not a host", nil]}) ==
             ["api.example.com"]

    assert Net.hosts(%{mode: :none}) == []
    assert Net.hosts(nil) == []
  end

  # STORE-53: unrestricted is what a chat that reaches the whole network has, so
  # it is what is not written; STORE-54: what is read back is a setting.
  test "a setting is stored only when it limits the network" do
    assert Net.stored(%{mode: :unrestricted, hosts: ["api.example.com"]}) == nil
    assert Net.stored(%{mode: :none}) == %{mode: :none}

    assert Net.stored(%{mode: :allowlist, hosts: ["API.example.com", "not a host"]}) ==
             %{mode: :allowlist, hosts: ["api.example.com"]}

    assert Net.load(nil) == Net.default()
    assert Net.load(%{mode: :none}) == %{mode: :none, hosts: []}

    assert Net.load(%{mode: :allowlist, hosts: ["api.example.com"]}) ==
             %{mode: :allowlist, hosts: ["api.example.com"]}

    # A stored value that names a mode that isn't one, or isn't a setting.
    assert Net.load(%{mode: :everything}) == Net.default()
    assert Net.load(%{}) == Net.default()
    assert Net.load("none") == Net.default()
  end

  # NET-11: a mode and a field's entries make a setting, and an entry that isn't
  # one of NET-7's forms is named.
  test "a mode and a host list make a setting, or name the entry that can't be" do
    assert {:ok, %{mode: :allowlist, hosts: ["api.example.com"]}} =
             Net.new(:allowlist, "api.example.com\n")

    assert {:ok, %{mode: :none, hosts: ["api.example.com"]}} = Net.new(:none, "api.example.com")
    assert {:error, "not a host"} = Net.new(:allowlist, "api.example.com\nnot a host")
    assert {:error, _message} = Net.new(:sometimes, "api.example.com")
  end
end
