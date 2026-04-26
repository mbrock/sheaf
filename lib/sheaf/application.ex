defmodule Sheaf.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    setup_opentelemetry()

    children = [
      SheafWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:sheaf, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Sheaf.PubSub},
      {Sheaf.Tracing.RedisSink, Application.get_env(:sheaf, Sheaf.Tracing.RedisSink, [])},
      {Finch, name: Sheaf.Finch},
      {Task.Supervisor, name: Sheaf.Assistant.TaskSupervisor},
      {Registry, keys: :unique, name: Sheaf.Assistant.ChatRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Sheaf.Assistant.ChatSupervisor},
      Sheaf.Assistant.Chats,
      SheafWeb.Endpoint,
      Sheaf.Readiness
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

  # Attach the OpenTelemetry span handlers for Phoenix and Bandit. Both packages
  # work by subscribing to `:telemetry` events, so this only needs to run once
  # per node at boot.
  defp setup_opentelemetry do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)
    OpentelemetryFinch.setup()
  rescue
    # If the OTel apps failed to start (e.g. exporter misconfigured) we don't
    # want the whole node to refuse to boot. Log and carry on without traces.
    error ->
      require Logger
      Logger.warning("OpenTelemetry setup failed: #{Exception.message(error)}")
      :ok
  end
end
