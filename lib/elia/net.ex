defmodule Elia.Net do
  @moduledoc """
  A chat's network setting (NET): what its commands and terminals may reach.

  Three modes (NET-1):

    * `:unrestricted` — the host's network, as every chat had before this
      setting existed, and what a chat whose file carries no value keeps.
    * `:allowlist` — the call's processes run in a network namespace of their
      own whose only interface is loopback, and reach the network through the
      harness's proxy, for the entries the chat's project names (NET-28). A
      chat that has never been saved starts here (NET-1).
    * `:none` — the same namespace with nothing to reach.

  A setting is `%{mode: mode}`: the entries are the chat's project's
  (`Elia.Projects.allowlist/1`, PROJ-49), each of them one of the forms
  `Elia.Net.Allowlist` accepts (NET-7). A setting read from a chat's file may
  still carry `hosts` — the entries the chat named before they moved to its
  project — and `hosts/1` reads them for the migration of NET-29.

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

  @doc """
  The setting a chat has until it sets one (NET-1), and what a chat whose file
  names no mode reads as (STORE-54): allowlisted, with nothing allowed yet — the
  entries its project names start empty (NET-28) — where a limit can be built
  (`available?/1`), and unrestricted where it can't, since a limit that isn't
  built leaves the chat reaching the network it means to deny (NET-20).
  """
  @spec default(keyword()) :: map()
  def default(opts \\ []) do
    if available?(opts), do: %{mode: :allowlist, hosts: []}, else: unrestricted()
  end

  @doc "The setting that limits nothing: the host's network (NET-1)."
  @spec unrestricted() :: map()
  def unrestricted, do: %{mode: :unrestricted, hosts: []}

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
  The setting a chat's commands are limited by as it stands (NET-6, NET-28): its
  mode, with the entries its project's allowlist names. A project that names
  none gives an empty list, which reaches nothing (NET-10).
  """
  @spec effective(term(), map() | nil) :: map()
  def effective(setting, project) do
    %{mode: mode(setting), hosts: Elia.Projects.allowlist(project)}
  end

  @doc """
  A setting as a chat holds it (NET-1, NET-28): its mode alone, since the
  entries are the chat's project's. A value that names no mode is the default.
  """
  @spec setting(term()) :: map()
  def setting(%{mode: mode}) when mode in @modes, do: %{mode: mode, hosts: []}
  def setting(_given), do: default()

  @doc """
  The setting as the chat's file stores it (STORE-53): its mode, for every mode
  a chat can be in — unrestricted included, so a chat that chooses the whole
  network keeps it across a restart (NET-1). A value that names no mode is not a
  setting and is not written: `nil`, so the file's entry stays off. The entries
  are the chat's project's and are not written (NET-28, NET-29).
  """
  @spec stored(term()) :: map() | nil
  def stored(%{mode: mode}) when mode in @modes, do: %{mode: mode}
  def stored(_setting), do: nil

  @doc """
  The setting a stored value holds (STORE-54): its mode, with the entries an
  older chat named of its own kept so its session can add them to its project's
  list (NET-29), and the default of NET-1 when there is none, when it isn't a
  setting, or when it names a mode that isn't one — so unrestricted is a mode a
  chat has by choosing it (NET-1). `opts` is what `available?/1` reads.
  """
  @spec load(term(), keyword()) :: map()
  def load(stored, opts \\ [])

  def load(%{mode: mode} = stored, _opts) when mode in @modes do
    case mode do
      :unrestricted -> unrestricted()
      :allowlist -> %{mode: :allowlist, hosts: hosts(stored)}
      :none -> %{mode: :none, hosts: []}
    end
  end

  def load(_stored, opts), do: default(opts)

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
    chat_id = Keyword.get(opts, :session_id)

    case Proxy.start(
           mode: :allowlist,
           hosts: current_hosts(chat_id, hosts(setting)),
           chat_id: chat_id,
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
