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
      {Registry, keys: :unique, name: Elia.Agent.Registry},
      {DynamicSupervisor, name: Elia.Agent.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Elia.Agent.TaskSupervisor},
      Elia.Settings,
      # PUSH-13, PUSH-14: which chats have a visible page, and PUSH-11, PUSH-12:
      # the notifications sent when one needs the user.
      Elia.Push.Viewers,
      Elia.Push.Notifier,
      Elia.LLM.Catalog,
      Elia.Skills,
      # DEPLOY-15, DEPLOY-16: a deploy runs here, not in the Settings page that
      # started it.
      Elia.Deploy.Runner,
      # Start to serve requests, typically the last entry
      EliaWeb.Endpoint
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
