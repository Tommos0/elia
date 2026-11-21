defmodule Elia.Net.Request do
  @moduledoc """
  The head of the request a client sends a proxy (NET-14): the host and port it
  asks for, and the head as it goes upstream.

  A proxy is asked two ways: `CONNECT host:port`, which asks for a tunnel (what
  an https client sends), and an absolute URI (`GET http://host:port/path`). A
  request whose target is in origin form is read through its `Host` header as
  well, so a client that treats the proxy's address as the server's still
  reaches what its allowlist names.
  """

  defstruct [:host, :port, :head, tunnel: false]

  @type t :: %__MODULE__{
          host: binary(),
          port: :inet.port_number(),
          head: binary(),
          tunnel: boolean()
        }

  @doc """
  Reads a request head: `{:ok, request, rest}` — `rest` being the bytes that
  arrived after the head, which belong to the body — or `:error` for bytes that
  are not an HTTP request head.
  """
  @spec parse(binary()) :: {:ok, t(), binary()} | :error
  def parse(head) when is_binary(head) do
    case :binary.split(head, "\r\n") do
      [line, rest] ->
        with [method, target, version] <- String.split(line, " ", parts: 3),
             {:ok, host, port, target} <- target(method, target, rest) do
          request = %__MODULE__{
            host: host,
            port: port,
            tunnel: method == "CONNECT",
            head: "#{method} #{target} #{version}\r\n" <> rest
          }

          {:ok, request, rest_after(head)}
        else
          _other -> :error
        end

      _other ->
        :error
    end
  end

  def parse(_other), do: :error

  # What arrived after the head's blank line: the client's first body bytes, if
  # it sent any with the head.
  defp rest_after(head) do
    case :binary.split(head, "\r\n\r\n") do
      [_head, rest] -> rest
      _other -> ""
    end
  end

  # CONNECT asks for a tunnel to an authority, `host:port`.
  defp target("CONNECT", target, _rest) do
    case authority(target) do
      {host, port} -> {:ok, host, port || 443, target}
      nil -> :error
    end
  end

  # An absolute URI: the proxy resolves it itself, so the target goes upstream
  # in origin form (NET-14).
  defp target(_method, target, rest) do
    case URI.parse(target) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        port = uri.port || if(scheme == "https", do: 443, else: 80)
        {:ok, host, port, origin_form(uri)}

      _other ->
        # A target in origin form: the `Host` header names the server.
        case host_header(rest) do
          {host, port} -> {:ok, host, port || 80, target}
          nil -> :error
        end
    end
  end

  defp origin_form(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if query in [nil, ""], do: path, else: path <> "?" <> query
  end

  # `host:port`, `host`, or an IPv6 address in brackets.
  defp authority(target) do
    case target do
      "[" <> _rest ->
        case String.split(target, "]:", parts: 2) do
          [host, port] -> {host <> "]", to_integer(port)}
          [host] -> {host, nil}
        end

      _other ->
        case String.split(target, ":", parts: 2) do
          [host, port] -> if host == "", do: nil, else: {host, to_integer(port)}
          [host] -> {host, nil}
        end
    end
  end

  defp host_header(rest) do
    rest
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "host", do: authority(String.trim(value))

        _other ->
          nil
      end
    end)
  end

  defp to_integer(text) do
    case Integer.parse(text) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _other -> nil
    end
  end
end
