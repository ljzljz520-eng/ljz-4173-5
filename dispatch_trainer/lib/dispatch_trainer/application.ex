defmodule DispatchTrainer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DispatchTrainerWeb.Telemetry,
      DispatchTrainer.Repo,
      {DNSCluster, query: Application.get_env(:dispatch_trainer, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DispatchTrainer.PubSub},
      {Registry, keys: :unique, name: DispatchTrainer.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: DispatchTrainer.SessionSupervisor},
      # Start to serve requests, typically the last entry
      DispatchTrainerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DispatchTrainer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DispatchTrainerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
