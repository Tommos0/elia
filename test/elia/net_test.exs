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

    # NET-1: a chat starts allowlisted where a limit can be built here, and
    # unrestricted where it can't — the host's jail and this chat's decide.
    starts_allowlisted = %{mode: :allowlist, hosts: []}
    default = if Net.available?(), do: starts_allowlisted, else: Net.unrestricted()

    assert Net.default() == default
    assert Net.default(jail: false) == Net.unrestricted()
    assert Net.unrestricted() == %{mode: :unrestricted, hosts: []}

    refute Net.limited?(Net.unrestricted())
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

    # NET-28: the entries are the chat's project's, so a setting stores its mode
    # alone.
    assert Net.stored(%{mode: :allowlist, hosts: ["API.example.com"]}) == %{mode: :allowlist}

    # STORE-54, NET-1: a chat with no entry at all is unrestricted, and one
    # that names no mode is too; NET-29: the entries an older chat named are
    # read so its session can hand them to its project.
    assert Net.load(nil) == Net.unrestricted()
    assert Net.load(%{mode: :none}) == %{mode: :none, hosts: []}

    assert Net.load(%{mode: :allowlist, hosts: ["API.example.com"]}) ==
             %{mode: :allowlist, hosts: ["api.example.com"]}

    assert Net.load(%{mode: :everything}) == Net.unrestricted()
    assert Net.load(%{}) == Net.unrestricted()
    assert Net.load("none") == Net.unrestricted()
  end

  # NET-6, NET-28: what a chat's commands are limited by as it stands — its own
  # mode with the entries its project allows, and nothing where the project
  # allows nothing (NET-10).
  test "the effective setting is the chat's mode and its project's entries" do
    project = Elia.Projects.harness()
    on_exit(fn -> Elia.Projects.set_allowlist(project, []) end)

    assert Net.effective(%{mode: :allowlist}, project) == %{mode: :allowlist, hosts: []}
    assert Net.effective(%{mode: :none}, project) == %{mode: :none, hosts: []}

    assert Net.effective(%{mode: :unrestricted}, project) ==
             %{mode: :unrestricted, hosts: []}

    {:ok, _project} = Elia.Projects.set_allowlist(project, ["API.example.com"])

    assert Net.effective(%{mode: :allowlist}, project) ==
             %{mode: :allowlist, hosts: ["api.example.com"]}
  end
end
