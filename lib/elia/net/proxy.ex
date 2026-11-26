defmodule Elia.Net.Proxy do
  @moduledoc """
  The harness's half of a restricted chat's network (NET-13, NET-14): an HTTP
  proxy served on a Unix socket, which a restricted command reaches through the
  relay inside its own namespace.

  It decides one thing — whether the host and port a request names is one the
  chat's allowlist holds (NET-14) — and forwards the bytes when it is, holding
  the two directions open until either side closes. A request it refuses gets a
  `403` and never reaches the host. The list is read from the chat's session at
  the moment a request arrives (NET-6), so a change to it reaches a command that
  is already running; a chat with no session falls back to the list the proxy
  was started with.

  The proxy resolves the host itself (NET-15), because a restricted command has
  no name resolution of its own, and it is the only place a request can leave
  from — the namespace around the command has no route out.
  """
  use GenServer

  alias Elia.Net.{Allowlist, Request}

  # The port the relay listens on inside a restricted namespace, and the port
  # the proxy's address names (NET-13). Every namespace has one of its own, so
  # the same number is free in each.
  @port 34_128

  # The most of a request head to read, and how long to wait for it; then how
  # long one connection's two directions are held before it is given up.
  @head_limit 16_384
  @head_timeout 15_000
  @pair_timeout 600_000

  @established "HTTP/1.1 200 Connection Established\r\n\r\n"
  @refused "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  @bad_request "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  @bad_gateway "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

  @doc """
  Starts the proxy for one call's network: `:hosts` is the chat's allowlist as
  it stands now, `:chat_id` the chat whose session the list is read from
  (NET-6), and `:caller` the process the proxy ends with (NET-21).
  """
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start_link(__MODULE__, Keyword.put(opts, :caller, self()))
  end

  @doc "Ends a proxy and the directory it serves from (NET-21)."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  @doc """
  What `Elia.Shell.argv/3` builds the namespace and the relay from (NET-13): the
  directory bound into the jail, the port the relay listens on, and the runtime
  that runs it.
  """
  @spec net(pid()) :: map()
  def net(pid) when is_pid(pid), do: GenServer.call(pid, :net)

  @doc """
  Whether the relay of a restricted namespace can be run at all (NET-20): none
  mode needs nothing beyond the jail, and allowlist mode needs an `elixir` the
  jail holds (ISOL-4).
  """
  @spec available?(atom()) :: boolean()
  def available?(:none), do: true
  def available?(_allowlist), do: relay_runtime() != nil

  @doc """
  The `elixir` that runs the relay, or `nil` when there is none the jail holds
  (NET-20). It has to be inside the toolchain the jail binds (ISOL-4): one
  installed elsewhere — a version manager's, under the home directory — is one
  a restricted command cannot run.
  """
  @spec relay_runtime() :: binary() | nil
  def relay_runtime do
    case System.find_executable("elixir") do
      nil -> nil
      path -> if inside_toolchain?(path), do: path
    end
  end

  defp inside_toolchain?(path) do
    Enum.any?(Elia.Shell.toolchain(), fn dir ->
      path == dir or String.starts_with?(path, dir <> "/")
    end)
  end

  ## The proxy

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    dir = make_dir()

    state = %{
      dir: dir,
      socket: Path.join([dir, "run", "proxy.sock"]),
      hosts: Allowlist.clean(Keyword.get(opts, :hosts, [])),
      chat_id: Keyword.get(opts, :chat_id),
      caller: Keyword.get(opts, :caller),
      listener: nil
    }

    case listen(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  # NET-21: the proxy ends with the call it serves — the run's own process, a
  # terminal session — and takes its directory and its socket with it.
  @impl true
  def handle_info({:EXIT, pid, reason}, %{caller: pid} = state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:net, _from, state) do
    net = %{
      mode: :allowlist,
      dir: state.dir,
      port: @port,
      socket: state.socket,
      proxy: self(),
      elixir: relay_runtime()
    }

    {:reply, net, state}
  end

  # NET-6: the chat's list as it stands now, not the one this proxy started with.
  def handle_call(:hosts, _from, state) do
    {:reply, Elia.Net.current_hosts(state.chat_id, state.hosts), state}
  end

  @impl true
  def terminate(_reason, state) do
    close(state.listener)
    File.rm_rf(state.dir)
    :ok
  end

  defp make_dir do
    name = "elia-net-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    dir = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(Path.join(dir, "run"))
    # NET-13: the relay runs inside the jail, which holds nothing of the app, so
    # the script is served from the directory the jail binds.
    File.cp!(relay_script(), Path.join(dir, "relay.exs"))
    dir
  end

  defp relay_script, do: Application.app_dir(:elia, "priv/net/relay.exs")

  defp listen(state) do
    File.rm(state.socket)
    proxy = self()

    with {:ok, listener} <- :socket.open(:local, :stream, %{}),
         :ok <- :socket.bind(listener, %{family: :local, path: state.socket}),
         :ok <- :socket.listen(listener) do
      spawn(fn -> accept(listener, proxy) end)
      {:ok, %{state | listener: listener}}
    end
  end

  defp close(nil), do: :ok
  defp close(socket), do: :socket.close(socket)

  ## One connection

  defp accept(listener, proxy) do
    case :socket.accept(listener) do
      {:ok, client} ->
        spawn(fn -> serve(client, proxy) end)
        accept(listener, proxy)

      # The listener is closed when the call ends.
      {:error, _reason} ->
        :ok
    end
  end

  defp serve(client, proxy) do
    case read_head(client, "") do
      {:ok, head, rest} -> serve_request(client, proxy, head, rest)
      :error -> refuse(client, @bad_request)
    end
  end

  # A head that parses as a request and names a host the chat's allowlist holds
  # is forwarded; anything else is refused.
  defp serve_request(client, proxy, head, rest) do
    case Request.parse(head) do
      {:ok, request, _body} ->
        hosts = GenServer.call(proxy, :hosts)

        if Allowlist.match?(hosts, request.host, request.port) do
          forward(client, request, rest)
        else
          refuse(client, @refused)
        end

      :error ->
        refuse(client, @bad_request)
    end
  end

  # The head ends at its blank line; anything after it is the client's first
  # body bytes, which belong upstream.
  defp read_head(client, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head <> "\r\n\r\n", rest}

      [_incomplete] ->
        read_more(client, buffer)
    end
  end

  # A head that is not all here yet: unless it is already longer than one may
  # be, read what comes next.
  defp read_more(client, buffer) do
    if byte_size(buffer) > @head_limit do
      :error
    else
      case :socket.recv(client, 0, @head_timeout) do
        {:ok, data} -> read_head(client, buffer <> data)
        {:error, _reason} -> :error
      end
    end
  end

  defp forward(client, request, rest) do
    case upstream(request.host, request.port) do
      {:ok, server} ->
        # A tunnel's request line is the proxy's own — it asks for the tunnel,
        # and the bytes after the handshake are the client's. A plain request
        # goes upstream as it is, in origin form (NET-14).
        if request.tunnel do
          :ok = :socket.send(client, @established)
          pair(client, server)
        else
          :ok = :socket.send(server, request.head <> rest)
          pair(client, server)
        end

      {:error, _reason} ->
        refuse(client, @bad_gateway)
    end
  end

  defp refuse(client, response) do
    :socket.send(client, response)
    :socket.close(client)
  end

  defp upstream(host, port) do
    with {:ok, address} <- resolve(host),
         {:ok, server} <- :socket.open(:inet, :stream, %{}),
         :ok <- :socket.connect(server, %{family: :inet, addr: address, port: port}) do
      {:ok, server}
    end
  end

  # NET-15: the proxy resolves the host, since a restricted command has no name
  # resolution of its own.
  defp resolve(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, address} -> {:ok, address}
      {:error, reason} -> {:error, reason}
    end
  end

  # Both directions are carried until one of them closes; whichever ends first
  # ends the connection, and the sockets are closed under the other.
  defp pair(client, server) do
    proxy = self()
    spawn(fn -> copy(client, server, proxy) end)
    spawn(fn -> copy(server, client, proxy) end)

    receive do
      {:copied, _pid} -> :ok
    after
      @pair_timeout -> :ok
    end

    :socket.close(client)
    :socket.close(server)
  end

  defp copy(from, to, proxy) do
    case :socket.recv(from, 0, :infinity) do
      {:ok, data} ->
        case :socket.send(to, data) do
          :ok -> copy(from, to, proxy)
          {:error, _reason} -> send(proxy, {:copied, self()})
        end

      {:error, _reason} ->
        send(proxy, {:copied, self()})
    end
  end
end
