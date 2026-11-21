defmodule Elia.Net do
  @moduledoc """
  A chat's network setting (NET): what its commands and terminals may reach.

  Three modes (NET-1):

    * `:unrestricted` — the host's network, as every chat had before this
      setting existed, and what a chat that sets nothing keeps.
    * `:allowlist` — the call's processes run in a network namespace of their
      own whose only interface is loopback, and reach the network through the
      harness's proxy, for the hosts the chat names.
    * `:none` — the same namespace with nothing to reach.

  A setting is `%{mode: mode, hosts: [entry]}`; `hosts` is read in `:allowlist`
  mode only, and each entry is one of the forms `Elia.Net.Allowlist` accepts
  (NET-7).

  The limit is built where the jail is: the namespace goes into the jail's argv
  (`Elia.Shell`), the proxy and the relay that carries a command's loopback to
  it come from here, and a caller that has both prepares them before it spawns
  (`prepare/1`) and ends them when its processes are done (`release/1`).
  """
  alias Elia.Net.{Allowlist, Proxy}

  @modes [:unrestricted, :allowlist, :none]

  # NET-20: a run that wanted a limited network and kept the host's says so, so
  # it never looks like one that was limited.
  @skipped_notice "[net: skipped, the chat's network limit could not be built]"

  @relay_notice "[net: the relay that carries commands to the proxy did not start]"

  @doc "Every mode a chat's network setting can be (NET-1)."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "The setting a chat has until it sets one: the whole network (NET-1)."
  @spec default() :: map()
  def default, do: %{mode: :unrestricted, hosts: []}

  @doc "The mode of a setting (NET-1); one that isn't a mode is unrestricted."
  @spec mode(term()) :: atom()
  def mode(%{mode: mode}) when mode in @modes, do: mode
  def mode(_setting), do: :unrestricted

  @doc "Whether a setting limits the network at all (NET-1)."
  @spec limited?(term()) :: boolean()
  def limited?(setting), do: mode(setting) != :unrestricted

  @doc "The entries a setting names, as an allowlist (NET-7)."
  @spec hosts(term()) :: [binary()]
  def hosts(%{hosts: hosts}), do: Allowlist.clean(hosts)
  def hosts(_setting), do: []

  @doc """
  A setting as it is held (NET-1): its mode and the entries of NET-7 it names,
  cleaned, so whatever form a caller gave them in — a list, or the lines of a
  form field — the chat's own setting is the same.
  """
  @spec setting(term()) :: map()
  def setting(%{mode: mode} = given) when mode in @modes, do: %{mode: mode, hosts: hosts(given)}
  def setting(_given), do: default()

  @doc """
  The setting as the chat's file stores it (STORE-53): `nil` in unrestricted
  mode, so a chat that reaches the whole network as every chat did carries no
  entry and setting it back takes the key off the file.
  """
  @spec stored(term()) :: map() | nil
  def stored(setting) do
    case mode(setting) do
      :unrestricted -> nil
      :allowlist -> %{mode: :allowlist, hosts: hosts(setting)}
      :none -> %{mode: :none}
    end
  end

  @doc """
  The setting a stored value holds (STORE-54): unrestricted when there is none,
  when it isn't a setting, or when it names a mode that isn't one (NET-1).
  """
  @spec load(term()) :: map()
  def load(%{mode: mode} = stored) when mode in @modes do
    case mode do
      :unrestricted -> default()
      :allowlist -> %{mode: :allowlist, hosts: hosts(stored)}
      :none -> %{mode: :none, hosts: []}
    end
  end

  def load(_stored), do: default()

  @doc """
  The setting a mode and the entries of a form field make, or the first entry
  that is not one of NET-7's forms (NET-11). The entries are kept in every
  mode, so switching to another one and back doesn't lose the list.
  """
  @spec new(atom(), term()) :: {:ok, map()} | {:error, binary()}
  def new(mode, entries) when mode in @modes do
    case Allowlist.parse(entries) do
      {:ok, hosts} -> {:ok, %{mode: mode, hosts: hosts}}
      {:error, entry} -> {:error, entry}
    end
  end

  def new(mode, _entries), do: {:error, "network mode: #{inspect(mode)}"}

  @doc """
  Whether a chat's network limit can be built here at all (NET-20, NET-25): the
  host has a jail (ISOL-12), the chat asks for it (ISOL-16), and the jail holds
  a runtime for the relay a restricted namespace reaches the proxy through
  (NET-13).
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts \\ []), do: Elia.Shell.jailed?(opts) and Proxy.available?(:allowlist)

  @doc """
  Prepares the network a call's processes get, from `opts[:network]` (the
  chat's setting, NET-1) and `opts[:session_id]` (the chat, whose allowlist the
  proxy reads at each request, NET-6).

  Returns `{opts, notice}`. `opts` carries `:net` — what the jail's argv builds
  the namespace and the relay from (NET-13) — and the proxy's address in `:env`
  (ISOL-8). `notice` is what the run says when the limit could not be built
  (NET-20): the chat's jail is off or the host has no jail (ISOL-12, ISOL-16),
  or there is no runtime the jail holds to run the relay (NET-20).
  """
  @spec prepare(keyword()) :: {keyword(), binary() | nil}
  def prepare(opts) do
    setting = Keyword.get(opts, :network)

    cond do
      not limited?(setting) -> {opts, nil}
      not Elia.Shell.jailed?(opts) -> {opts, @skipped_notice}
      true -> start(opts, setting)
    end
  end

  defp start(opts, setting) do
    if Proxy.available?(mode(setting)) do
      case proxy(mode(setting), opts, setting) do
        {:ok, net} -> {opts |> Keyword.put(:net, net) |> add_env(net), nil}
        {:error, _reason} -> {opts, @skipped_notice}
      end
    else
      {opts, @skipped_notice}
    end
  end

  # NET-16: none mode needs no proxy and no relay. The namespace has nothing to
  # reach, so it is the namespace alone.
  defp proxy(:none, _opts, _setting), do: {:ok, %{mode: :none}}

  defp proxy(:allowlist, opts, setting) do
    case Proxy.start(
           mode: :allowlist,
           hosts: hosts(setting),
           chat_id: Keyword.get(opts, :session_id),
           caller: self()
         ) do
      {:ok, pid} -> {:ok, Proxy.net(pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  # NET-13: the only address a restricted command has to the network is the
  # proxy on its own loopback. `no_proxy` keeps a command's own local servers
  # off it, which has no route to them in any case.
  defp add_env(opts, %{mode: :allowlist, port: port}) do
    Keyword.update(opts, :env, env(port), &(&1 ++ env(port)))
  end

  defp add_env(opts, _net), do: opts

  defp env(port) do
    url = "http://127.0.0.1:#{port}"

    [
      {"http_proxy", url},
      {"https_proxy", url},
      {"all_proxy", url},
      {"no_proxy", "127.0.0.1,localhost,::1"}
    ]
  end

  @doc """
  Ends the network a call prepared (NET-21): its proxy, its socket and its
  directory go with the call's processes.
  """
  @spec release(keyword()) :: :ok
  def release(opts) do
    case Keyword.get(opts, :net) do
      %{proxy: pid} -> Proxy.stop(pid)
      _net -> :ok
    end
  end

  @doc """
  The hosts a chat's allowlist names right now (NET-6): what its running
  session holds, so a change to the list reaches a command that is already
  running. `fallback` is the list for a chat whose session is gone — the one
  the proxy was started with.
  """
  @spec current_hosts(binary() | nil, [binary()]) :: [binary()]
  def current_hosts(nil, fallback), do: fallback

  def current_hosts(chat_id, fallback) do
    case Elia.Agent.network(chat_id) do
      %{hosts: hosts} -> hosts
      _other -> fallback
    end
  end

  @doc """
  What a run says when the chat's network limit could not be built (NET-20). It
  is prepended to the command's own output, like the jail's notice (ISOL-12).
  """
  @spec skipped_notice() :: binary()
  def skipped_notice, do: @skipped_notice

  @doc """
  What a restricted run says when its relay never began to listen (NET-20): the
  namespace is the command's own, so nothing left it, but the proxy it should
  have reached isn't there — the command reaches the network it has, which is
  none.
  """
  @spec relay_notice() :: binary()
  def relay_notice, do: @relay_notice
end
