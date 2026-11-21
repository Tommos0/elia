defmodule Elia.Net.Allowlist do
  @moduledoc """
  A chat's allowlist of hosts (NET-7): what the proxy may forward a request to.

  An entry is a host name (`api.example.com`), a `*.` suffix
  (`*.example.com`), or either of those with a port (`api.example.com:443`).
  Matching ignores case; a `*.` suffix entry matches a host that ends with `.`
  and the suffix and not the bare suffix (NET-8), and an entry with no port
  matches any port (NET-9). An empty list names nothing, so every request is
  refused (NET-10).
  """

  # NET-7: a host name or a `*.` suffix of one, optionally with a port.
  @entry ~r/^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$/i

  @doc "Whether `entry` is one of NET-7's forms."
  @spec valid?(term()) :: boolean()
  def valid?(entry) when is_binary(entry), do: Regex.match?(@entry, String.trim(entry))
  def valid?(_entry), do: false

  @doc """
  The entries a form field or a list holds, as a chat's allowlist, or the first
  entry that is not one of NET-7's forms (NET-11).

  `text` may be the string a field holds — one entry per line — or a list of
  entries; blanks are dropped, and the entries come back lowercased.
  """
  @spec parse(term()) :: {:ok, [binary()]} | {:error, binary()}
  def parse(text) when is_binary(text), do: text |> String.split(~r/\r?\n/) |> parse()

  def parse(entries) when is_list(entries) do
    entries
    |> Enum.map(&trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      if valid?(entry),
        do: {:cont, {:ok, acc ++ [String.downcase(entry)]}},
        else: {:halt, {:error, entry}}
    end)
  end

  def parse(other), do: {:error, trim(other)}

  @doc """
  A list as the entries of a chat's allowlist (NET-7): trimmed, lowercased, and
  without the blanks, the duplicates and anything that is not an entry. This is
  what a stored list is read through (STORE-54), where a bad entry is dropped
  rather than refused.
  """
  @spec clean(term()) :: [binary()]
  def clean(entries) when is_list(entries) do
    entries
    |> Enum.map(&trim/1)
    |> Enum.filter(&valid?/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  def clean(_other), do: []

  @doc """
  Whether a request to `host` on `port` is one the entries name (NET-7 to
  NET-9). `host` is compared ignoring case, and a `*.` suffix entry does not
  match the bare suffix.
  """
  @spec match?([binary()], term(), term()) :: boolean()
  def match?(entries, host, port) when is_list(entries) do
    host = host |> to_string() |> String.downcase()
    Enum.any?(entries, &matches?(&1, host, port))
  end

  def match?(_entries, _host, _port), do: false

  defp matches?(entry, host, port) do
    {named_host, named_port} = entry |> String.downcase() |> split_port()
    (named_port == nil or named_port == port) and host_matches?(named_host, host)
  end

  # NET-9: an entry with no port matches any port.
  defp split_port(entry) do
    case String.split(entry, ":", parts: 2) do
      [host, port] -> {host, to_integer(port)}
      [host] -> {host, nil}
    end
  end

  defp to_integer(port) do
    case Integer.parse(port) do
      {port, ""} -> port
      _other -> nil
    end
  end

  # NET-8: `*.example.com` matches `api.example.com`, and not `example.com`.
  defp host_matches?("*." <> suffix, host), do: String.ends_with?(host, "." <> suffix)
  defp host_matches?(entry, host), do: entry == host

  defp trim(entry) when is_binary(entry), do: String.trim(entry)
  defp trim(_entry), do: ""
end
