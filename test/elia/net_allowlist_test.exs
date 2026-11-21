defmodule Elia.Net.AllowlistTest do
  use ExUnit.Case, async: true

  alias Elia.Net.Allowlist

  # NET-7: an entry is a host name, a `*.` suffix, or either of those with a
  # port.
  test "an entry is a host, a *.suffix or either with a port" do
    assert Allowlist.valid?("api.example.com")
    assert Allowlist.valid?("*.example.com")
    assert Allowlist.valid?("api.example.com:443")
    assert Allowlist.valid?("*.example.com:8443")
    assert Allowlist.valid?("localhost")
    assert Allowlist.valid?("127.0.0.1")

    refute Allowlist.valid?("api.example.com:port")
    refute Allowlist.valid?("api example.com")
    refute Allowlist.valid?("http://api.example.com")
    refute Allowlist.valid?("")
    refute Allowlist.valid?(nil)
  end

  # NET-8: a `*.` suffix entry matches a host that ends with `.` and the
  # suffix, and not the bare suffix.
  test "a *.suffix entry matches a subdomain and not the bare suffix" do
    assert Allowlist.match?(["*.example.com"], "api.example.com", 443)
    assert Allowlist.match?(["*.example.com"], "a.b.example.com", 80)

    refute Allowlist.match?(["*.example.com"], "example.com", 443)
    refute Allowlist.match?(["*.example.com"], "notexample.com", 443)
  end

  # NET-9: the case is ignored, and an entry with no port matches any port
  # where one with a port matches that port only.
  test "the case is ignored and a port is what an entry says" do
    assert Allowlist.match?(["API.Example.COM"], "api.example.com", 443)
    assert Allowlist.match?(["api.example.com"], "api.example.com", 8080)
    assert Allowlist.match?(["api.example.com:443"], "api.example.com", 443)
    assert Allowlist.match?(["*.example.com:8443"], "api.example.com", 8443)

    refute Allowlist.match?(["api.example.com:443"], "api.example.com", 80)
    refute Allowlist.match?(["*.example.com:8443"], "api.example.com", 443)
  end

  # NET-10: an empty list names nothing.
  test "an empty list reaches nothing" do
    refute Allowlist.match?([], "api.example.com", 443)
    refute Allowlist.match?([], "127.0.0.1", 80)
    refute Allowlist.match?([], "localhost", 80)
  end

  # NET-11: a list is read one entry per line, and an entry that isn't one of
  # NET-7's forms is named.
  test "a list is read one entry per line and a bad entry is named" do
    assert {:ok, ["api.example.com", "*.example.org:443"]} =
             Allowlist.parse(" api.example.com\n\n*.example.org:443 \n")

    assert {:ok, ["api.example.com"]} = Allowlist.parse(["api.example.com", "", nil])
    assert {:error, "not a host"} = Allowlist.parse("api.example.com\nnot a host\n")
    assert {:ok, []} = Allowlist.parse("")
    assert {:ok, []} = Allowlist.parse([])
  end

  # STORE-54, NET-1: a list read out of a chat's file is read through — what
  # isn't an entry is dropped rather than refused.
  test "a stored list is read through, dropping what isn't an entry" do
    assert Allowlist.clean(["API.example.com", "http://x", "api.example.com", nil]) ==
             ["api.example.com"]

    assert Allowlist.clean("nope") == []
    assert Allowlist.clean(nil) == []
  end
end
