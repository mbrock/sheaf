defmodule Sheaf.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SheafWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:sheaf, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sheaf.PubSub},
      # Start a worker by calling: Sheaf.Worker.start_link(arg)
      # {Sheaf.Worker, arg},
      # Start to serve requests, typically the last entry
      SheafWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sheaf.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SheafWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
