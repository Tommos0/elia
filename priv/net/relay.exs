# NET-13: the in-jail half of a restricted chat's network.
#
# It listens on the restricted namespace's loopback — the one address a
# command's proxy environment names — and carries each connection to the proxy
# the harness serves, over a Unix socket bound into the jail. That socket is the
# only way out of a namespace with no route, so every byte a command sends the
# network passes the proxy's decision.
#
# `Elia.Shell` puts a wrapper in front of a command's script that runs this file
# with the port to listen on, the proxy's socket and a file to touch when it is
# ready:
#
#     elixir <this file> <port> <unix socket> <ready file>
#
defmodule Elia.Net.RelayScript do
  @moduledoc false

  def main([port, socket, ready]) do
    port = port |> to_string() |> String.to_integer()
    socket = to_string(socket)
    ready = to_string(ready)

    {:ok, listener} = :socket.open(:inet, :stream, %{})
    :ok = :socket.setopt(listener, :socket, :reuseaddr, true)
    :ok = :socket.bind(listener, %{family: :inet, addr: {127, 0, 0, 1}, port: port})
    :ok = :socket.listen(listener)

    # The wrapper waits for this before it starts the command, so a client's
    # first request finds something to reach.
    File.write!(ready, "ready\n")
    loop(listener, socket)
  end

  defp loop(listener, socket) do
    case :socket.accept(listener) do
      {:ok, client} ->
        spawn(fn -> carry(client, socket) end)
        loop(listener, socket)

      {:error, _reason} ->
        :ok
    end
  end

  defp carry(client, socket) do
    case :socket.open(:local, :stream, %{}) do
      {:ok, upstream} ->
        case :socket.connect(upstream, %{family: :local, path: socket}) do
          :ok ->
            parent = self()
            spawn(fn -> copy(client, upstream, parent) end)
            spawn(fn -> copy(upstream, client, parent) end)

            receive do
              :copied -> :ok
            end

          {:error, _reason} ->
            :ok
        end

      {:error, _reason} ->
        :ok
    end

    :socket.close(client)
  end

  defp copy(from, to, parent) do
    case :socket.recv(from, 0, :infinity) do
      {:ok, data} ->
        case :socket.send(to, data) do
          :ok -> copy(from, to, parent)
          {:error, _reason} -> send(parent, :copied)
        end

      {:error, _reason} ->
        send(parent, :copied)
    end
  end
end

Elia.Net.RelayScript.main(System.argv())
