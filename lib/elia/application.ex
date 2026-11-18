defmodule Elia.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Elia.Supervisor]
    Supervisor.start_link(children(), opts)
  end

  @doc """
  The processes Elia runs (HOT-10): what `start/2` starts, and what a hot reload
  compares with the running supervisor, since a reload loads modules but cannot
  add a child to a tree built at boot (DEPLOY-6). One function, so the two
  cannot drift apart.
  """
  def children do
    [
      EliaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:elia, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Elia.PubSub},
      EliaWeb.Presence,
      Elia.Logs,
      # STORE-45: before anything that reads saved chats — the sessions, the
      # pages.
      Elia.Store.Cache,
      {Registry, keys: :unique, name: Elia.Agent.Registry},
      {DynamicSupervisor, name: Elia.Agent.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Elia.Agent.TaskSupervisor},
      # TERM-1: a chat's terminal session is registered by chat id, so a chat
      # has one, and it runs under its own supervisor — a session that dies
      # takes its process tree with it (TERM-3) and leaves the rest alone.
      {Registry, keys: :unique, name: Elia.Terminal.Registry},
      {DynamicSupervisor, name: Elia.Terminal.Supervisor, strategy: :one_for_one},
      Elia.Settings,
      # CITE-4: the spec corpus the transcript cites from, kept while the files
      # it was made from are unchanged. After the store's cache, which is the
      # same idea for a saved chat (STORE-45).
      Elia.Specs.Cache,
      # PUSH-13, PUSH-14: which chats have a visible page, and PUSH-11, PUSH-12:
      # the notifications sent when one needs the user.
      Elia.Push.Viewers,
      Elia.Push.Notifier,
      Elia.LLM.Catalog,
      # LOCAL-11, LOCAL-19: the local llama-server Elia can start, one at most,
      # owned by the app so it goes down with it.
      Elia.LLM.LlamaServer,
      Elia.Skills,
      # DEPLOY-15, DEPLOY-16: a deploy runs here, not in the Settings page that
      # started it.
      Elia.Deploy.Runner,
      # Start to serve requests, typically the last entry
      EliaWeb.Endpoint,
      # RESUME-1: the turns a restart cut short are carried on from here, after
      # everything they need is up. Its scan runs in its own process, so it
      # never holds up the application's own start.
      Elia.Agent.Resumer
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EliaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
