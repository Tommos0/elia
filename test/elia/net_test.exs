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

  # NET-1, STORE-53: every mode a chat can be in is written, unrestricted
  # included, so a chat that chooses the whole network keeps it; a value that
  # names no mode is not a setting and writes no entry. NET-36: the entries a
  # chat names of its own are written with its mode, and one that names none
  # carries no entry of its own.
  test "a setting is stored as its mode, and a value that names none is not one" do
    assert Net.stored(%{mode: :unrestricted, hosts: ["api.example.com"]}) ==
             %{mode: :unrestricted}

    assert Net.stored(%{mode: :none}) == %{mode: :none}

    assert Net.stored(%{mode: :allowlist, hosts: ["API.example.com"]}) ==
             %{mode: :allowlist, hosts: ["api.example.com"]}

    assert Net.stored(%{mode: :allowlist}) == %{mode: :allowlist}

    assert Net.stored(nil) == nil
    assert Net.stored(%{mode: :everything}) == nil
    assert Net.stored("none") == nil

    # STORE-54, NET-1: a file that names a mode is read back as it is, with the
    # entries the chat names of its own (NET-36); a value that names no mode
    # reads as the default, which is allowlisted where a limit can be built and
    # unrestricted where it can't (NET-20, NET-25).
    assert Net.load(%{mode: :unrestricted}) == Net.unrestricted()
    assert Net.load(%{mode: :none}) == %{mode: :none, hosts: []}

    assert Net.load(%{mode: :allowlist, hosts: ["API.example.com"]}) ==
             %{mode: :allowlist, hosts: ["api.example.com"]}

    assert Net.load(nil) == Net.default()
    assert Net.load(nil, jail: false) == Net.unrestricted()
    assert Net.load(%{mode: :everything}) == Net.default()
    assert Net.load(%{}) == Net.default()
    assert Net.load("none") == Net.default()
  end

  # NET-33, NET-36: an entry the user allowed for the chat joins the entries the
  # chat names of its own, once, and nothing else about the setting changes.
  test "an entry is added to the entries a setting names of its own" do
    setting = %{mode: :allowlist, hosts: ["api.example.com"]}

    assert Net.add_host(setting, "OTHER.example.com") ==
             %{mode: :allowlist, hosts: ["api.example.com", "other.example.com"]}

    assert Net.add_host(setting, "api.example.com") == setting

    assert Net.add_host(%{mode: :none}, "api.example.com") ==
             %{mode: :none, hosts: ["api.example.com"]}
  end

  # NET-6, NET-28, NET-36: what a chat's commands are limited by as it stands —
  # its own mode with the entries it names of its own together with its
  # project's, and nothing where neither names one (NET-10).
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

    # NET-36: a chat's own entries come first, an entry both name is listed
    # once, and only the chat that names one reaches it.
    assert Net.effective(%{mode: :allowlist, hosts: ["localhost:3000"]}, project) ==
             %{mode: :allowlist, hosts: ["localhost:3000", "api.example.com"]}

    assert Net.effective(
             %{mode: :allowlist, hosts: ["API.example.com", "localhost:3000"]},
             project
           ) == %{mode: :allowlist, hosts: ["api.example.com", "localhost:3000"]}

    assert Net.effective(%{mode: :allowlist, hosts: ["localhost:3000"]}, nil) ==
             %{mode: :allowlist, hosts: ["localhost:3000"]}
  end
end
