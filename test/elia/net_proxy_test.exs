defmodule Elia.Net.ProxyTest do
  use ExUnit.Case, async: false

  alias Elia.Net.Proxy

  # A site on the host's loopback, standing in for one the chat allows: it
  # answers one request and tells this process what it got, so a test can tell a
  # request the proxy forwarded from one that never left it.
  defp site(reply \\ "hello") do
    {:ok, listener} = :socket.open(:inet, :stream, %{})
    :ok = :socket.setopt(listener, :socket, :reuseaddr, true)
    :ok = :socket.bind(listener, %{family: :inet, addr: {127, 0, 0, 1}, port: 0})
    :ok = :socket.listen(listener)
    {:ok, %{port: port}} = :socket.sockname(listener)
    test = self()

    spawn_link(fn ->
      {:ok, client} = :socket.accept(listener)
      send(test, {:reached, port})
      {:ok, request} = :socket.recv(client, 0)
      send(test, {:request, request})

      body =
        "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(reply)}\r\nConnection: close\r\n\r\n#{reply}"

      :socket.send(client, body)
      :socket.close(client)
    end)

    port
  end

  defp proxy(hosts, chat_id \\ nil) do
    {:ok, pid} = Proxy.start(mode: :allowlist, hosts: hosts, chat_id: chat_id, caller: self())
    pid
  end

  defp send_request(path, bytes) do
    {:ok, client} = :socket.open(:local, :stream, %{})
    :ok = :socket.connect(client, %{family: :local, path: path})
    :ok = :socket.send(client, bytes)
    client
  end

  defp read(client, buffer \\ "") do
    case :socket.recv(client, 0, 2_000) do
      {:ok, data} -> read(client, buffer <> data)
      {:error, _reason} -> buffer
    end
  end

  # NET-13, NET-14: an allowlisted host's request is forwarded — in origin form,
  # the proxy having resolved the host itself (NET-15) — and the answer comes
  # back.
  test "a request to an allowlisted host is forwarded and its answer comes back" do
    port = site()
    path = Proxy.net(proxy(["localhost:#{port}"])).socket

    answer =
      send_request(path, "GET http://localhost:#{port}/x HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> read()

    assert answer =~ "200 OK"
    assert answer =~ "hello"
    assert_receive {:reached, ^port}, 2_000
    assert_receive {:request, request}, 2_000
    # The request goes upstream in origin form, and it was the proxy that
    # resolved the name the client asked for — the namespace around a command
    # has no name resolution of its own (NET-15).
    assert request =~ "GET /x HTTP/1.1"
    refute request =~ "GET http://"
  end

  # NET-14: a request to a host the chat's allowlist doesn't name is refused
  # with a 403, and never reaches it.
  test "a request to a host that is not allowed is refused and never forwarded" do
    port = site()
    path = Proxy.net(proxy(["other.example.com"])).socket

    answer =
      send_request(path, "GET http://localhost:#{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> read()

    assert answer =~ "403 Forbidden"
    refute_receive {:reached, ^port}, 300
  end

  # NET-10: an empty allowlist reaches nothing.
  test "an empty allowlist refuses every request" do
    port = site()
    path = Proxy.net(proxy([])).socket

    answer =
      send_request(path, "GET http://localhost:#{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> read()

    assert answer =~ "403 Forbidden"
    refute_receive {:reached, ^port}, 300
  end

  # NET-9: an entry with a port matches that port only.
  test "an entry with a port matches that port only" do
    port = site()
    other = port + 1
    path = Proxy.net(proxy(["localhost:#{other}"])).socket

    answer =
      send_request(path, "GET http://localhost:#{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> read()

    assert answer =~ "403 Forbidden"
    refute_receive {:reached, ^port}, 300
  end

  # NET-14: a tunnel (what an https client asks for with CONNECT) is established
  # for an allowlisted host, and the bytes after the handshake are carried both
  # ways.
  test "a tunnel to an allowlisted host is established and its bytes are carried" do
    port = site()
    path = Proxy.net(proxy(["localhost:#{port}"])).socket

    client =
      send_request(path, "CONNECT localhost:#{port} HTTP/1.1\r\nHost: localhost:#{port}\r\n\r\n")

    assert read(client) =~ "200 Connection Established"

    :ok = :socket.send(client, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
    assert_receive {:request, request}, 2_000
    assert request =~ "GET / HTTP/1.1"
    assert read(client) =~ "hello"
  end

  # NET-6: the proxy reads the chat's list at the moment it decides, so a change
  # to it reaches a command that is already running.
  test "the list is read from the chat when the request arrives" do
    port = site()
    chat = Elia.Agent.new_id()
    {:ok, _pid} = Elia.Agent.ensure_started(chat, auto_approve: [])

    # The proxy was started with nothing allowed; the chat now allows the site.
    path = Proxy.net(proxy([], chat)).socket
    :ok = Elia.Agent.set_network(chat, %{mode: :allowlist, hosts: ["localhost:#{port}"]})

    answer =
      send_request(path, "GET http://localhost:#{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> read()

    assert answer =~ "200 OK"
    assert_receive {:reached, ^port}, 2_000

    # And a change that takes the host off the list takes it off a running
    # command's reach too.
    :ok = Elia.Agent.set_network(chat, %{mode: :allowlist, hosts: ["other.example.com"]})

    refused =
      send_request(path, "GET http://localhost:#{port}/ HTTP/1.1\r\nHost: localhost\r\n\r\n")
      |> read()

    assert refused =~ "403 Forbidden"
  end

  # NET-21: the proxy ends when the call it serves does, and takes its socket and
  # its directory with it.
  test "the proxy ends with its caller and leaves nothing behind" do
    {:ok, proxy} = Proxy.start(mode: :allowlist, hosts: [], chat_id: nil, caller: self())
    net = Proxy.net(proxy)

    assert File.exists?(net.socket)
    assert File.dir?(net.dir)

    # The caller here is this test process, so a proxy told to stop is what a
    # call's end looks like from inside the proxy (NET-21).
    :ok = Proxy.stop(proxy)

    refute Process.alive?(proxy)
    refute File.exists?(net.dir)
  end
end
