defmodule Elia.NetworkAccessTest do
  # NET: a chat's network setting, from a command's own side — the namespace it
  # gets, the proxy its environment names, and what it can reach. Skipped where
  # the limit can't be built at all (NET-20).
  use ExUnit.Case, async: false

  alias Elia.Shell

  # The host's own jail setting is off for the suite (config/test.exs), so the
  # tag asks the two things a limit needs of the host: bubblewrap (ISOL-12) and
  # a runtime the jail holds to run the relay with (NET-20).
  @moduletag skip:
               if(Elia.Shell.available?() and Elia.Net.Proxy.relay_runtime() != nil,
                 do: false,
                 else: "a chat's network limit can't be built here (NET-20)"
               )

  setup do
    # The suite runs unjailed (config/test.exs). Here the host allows the jail
    # and each call turns it on, which is what a tool call does (ISOL-1, ISOL-16).
    previous = Application.get_env(:elia, Elia.Shell)
    Application.put_env(:elia, Elia.Shell, jail: true)
    on_exit(fn -> Application.put_env(:elia, Elia.Shell, previous) end)
    :ok
  end

  # A site on the host's loopback, standing in for one the chat allows, named as
  # the machine names itself: that is a name a restricted command cannot resolve
  # for itself and the proxy can (NET-15), and it is not one a client keeps off
  # the proxy. It answers one request and tells this process that it was
  # reached. A host whose own name doesn't resolve has nothing to stand in for a
  # site with, and the tests that need one assert nothing.
  defp site do
    test = self()
    {:ok, hostname} = :inet.gethostname()
    name = to_string(hostname)

    with {:ok, address} <- :inet.getaddr(hostname, :inet),
         {:ok, listener} <- :socket.open(:inet, :stream, %{}),
         :ok <- :socket.setopt(listener, :socket, :reuseaddr, true),
         :ok <- :socket.bind(listener, %{family: :inet, addr: address, port: 0}),
         :ok <- :socket.listen(listener),
         {:ok, %{port: port}} <- :socket.sockname(listener) do
      spawn_link(fn ->
        {:ok, client} = :socket.accept(listener)
        send(test, {:reached, port})
        {:ok, _request} = :socket.recv(client, 0)

        :socket.send(
          client,
          "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
        )

        :socket.close(client)
      end)

      {:ok, name, port}
    else
      _other -> :none
    end
  end

  defp run(command, network, opts \\ []) do
    Shell.run(command, [jail: true, shell: "sh", network: network, timeout: 60_000] ++ opts)
  end

  # NET-13, NET-14: an allowlisted host is reached through the proxy the
  # environment names, and the proxy resolves it (NET-15).
  test "an allowlisted host is reached through the proxy" do
    with {:ok, name, port} <- site() do
      assert {:ok, output, 0} =
               run("curl -s -m 30 http://#{name}:#{port}/; echo code=$?", %{
                 mode: :allowlist,
                 hosts: ["#{name}:#{port}"]
               })

      assert output =~ "hello"
      assert output =~ "code=0"
      assert_receive {:reached, ^port}, 2_000
    end
  end

  # NET-13: a restricted command's only address to the network is the proxy.
  test "an allowlisted chat's commands are given the proxy's address (ISOL-8)" do
    assert {:ok, output, 0} =
             run("echo $http_proxy $https_proxy $all_proxy", %{
               mode: :allowlist,
               hosts: ["api.example.com"]
             })

    assert output =~ ~r|http://127\.0\.0\.1:\d+ http://127\.0\.0\.1:\d+ http://127\.0\.0\.1:\d+|
  end

  # NET-14: a host the allowlist doesn't name is refused, the client reports it,
  # and it never reaches the host.
  test "a host that is not allowed is refused" do
    with {:ok, name, port} <- site() do
      assert {:ok, output, _status} =
               run("curl -s -m 30 -o /dev/null -w 'code=%{http_code}' http://#{name}:#{port}/", %{
                 mode: :allowlist,
                 hosts: ["other.example.com"]
               })

      assert output =~ "code=403"
      refute_receive {:reached, ^port}, 300
    end
  end

  # NET-16: none mode reaches nothing, and is given no proxy address.
  test "none mode reaches nothing and is given no proxy" do
    assert {:ok, output, _status} =
             run(
               "echo proxy=$http_proxy; curl -s -m 10 -o /dev/null -w 'code=%{http_code}' http://example.com/",
               %{mode: :none}
             )

    assert output =~ "proxy=\n"
    refute output =~ "code=200"
  end

  # NET-17: in both restricted modes loopback is up, so a command reaches a
  # server it starts itself.
  test "a restricted command reaches a server it starts itself (NET-17)" do
    for network <- [%{mode: :none}, %{mode: :allowlist, hosts: []}] do
      assert {:ok, output, 0} =
               run(
                 "python3 -m http.server 8234 >/dev/null 2>&1 & sleep 1; curl -s -m 10 -o /dev/null -w 'code=%{http_code}' http://127.0.0.1:8234/",
                 network
               )

      assert output =~ "code=200"
    end
  end

  # NET-17: the namespace is the command's own, so one command reaches nothing
  # another command listens to.
  test "one restricted command reaches nothing another command listens to (NET-17)" do
    assert {:ok, _output, 0} =
             run("python3 -m http.server 8235 >/dev/null 2>&1 & sleep 1; echo up", %{mode: :none})

    # The server above is in a namespace of its own; this command has another.
    assert {:ok, output, _status} =
             run("curl -s -m 5 -o /dev/null -w 'code=%{http_code}' http://127.0.0.1:8235/", %{
               mode: :none
             })

    refute output =~ "code=200"
  end

  # NET-12: unrestricted is what every chat had, and it is unchanged.
  test "unrestricted mode is the host's network and no proxy address (NET-12)" do
    assert {:ok, output, 0} = run("echo proxy=$http_proxy", %{mode: :unrestricted})

    assert output == "proxy=\n"
  end

  # NET-20: where the limit can't be built — here the chat's jail is off — the
  # command runs with the host's network and the result says the limit was
  # skipped, so it never looks like a chat that was limited.
  test "a chat whose jail is off runs unrestricted and says the limit was skipped" do
    assert {:ok, output, 0} =
             Shell.run("echo proxy=$http_proxy",
               jail: false,
               shell: "sh",
               network: %{mode: :none}
             )

    assert output =~ Elia.Net.skipped_notice()
    assert output =~ "proxy=\n"
  end

  # NET-19: a caller with no chat has no chat's setting, and runs as it did.
  test "a caller with no chat runs unrestricted" do
    assert {:ok, output, 0} = Shell.run("echo proxy=$http_proxy", shell: "sh")
    assert output == "proxy=\n"
  end

  # NET-21: a restricted command leaves no process, socket or directory behind.
  test "a restricted command leaves nothing behind" do
    assert {:ok, _output, 0} = run("echo hi", %{mode: :allowlist, hosts: []})

    assert Path.wildcard(Path.join(System.tmp_dir!(), "elia-net-*")) == []
  end

  # NET-21: a command that is killed leaves nothing behind either.
  test "a command that times out leaves nothing behind" do
    assert {:timeout, _output} =
             Shell.run("sleep 30",
               jail: true,
               shell: "sh",
               timeout: 1_000,
               network: %{mode: :none}
             )

    assert Path.wildcard(Path.join(System.tmp_dir!(), "elia-net-*")) == []
  end
end
