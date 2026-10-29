defmodule Elia.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # The code loaded now matches the guarded files on disk.
    Elia.Guarded.mark_loaded()

    children = [
      EliaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:elia, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Elia.PubSub},
      EliaWeb.Presence,
      {Registry, keys: :unique, name: Elia.Agent.Registry},
      {DynamicSupervisor, name: Elia.Agent.Supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Elia.Agent.TaskSupervisor},
      Elia.Skills,
      Elia.Checkpoint,
      # Start to serve requests, typically the last entry
      EliaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Elia.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EliaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
