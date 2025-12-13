defmodule Sheaf.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    stop_optional_dev_watchers()
    if tracing_enabled?(), do: setup_opentelemetry()

    children =
      tracing_children() ++
        [
          SheafWeb.Telemetry,
          {DNSCluster, query: Application.get_env(:sheaf, :dns_cluster_query) || :ignore},
          {Phoenix.PubSub, name: Sheaf.PubSub},
          {Finch, name: Sheaf.Finch}
        ] ++
        repo_children() ++
        [
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

  # Tracing is opt-in: it only runs when `SHEAF_OTEL_REDIS_URL` was set in the
  # environment, which causes `config/runtime.exs` to populate
  # `:sheaf, Sheaf.Tracing.RedisSink` with a `:redis_url`. With no URL we skip
  # the sink and the instrumentation handlers entirely, so no spans are even
  # created.
  defp tracing_enabled? do
    case Application.get_env(:sheaf, Sheaf.Tracing.RedisSink) do
      nil -> false
      opts -> is_binary(Keyword.get(opts, :redis_url))
    end
  end

  defp tracing_children do
    if tracing_enabled?() do
      [{Sheaf.Tracing.RedisSink, Application.get_env(:sheaf, Sheaf.Tracing.RedisSink, [])}]
    else
      []
    end
  end

  defp repo_children do
    if Application.get_env(:sheaf, Sheaf.Repo, []) |> Keyword.get(:start?, true) do
      [Sheaf.Repo]
    else
      []
    end
  end

  defp stop_optional_dev_watchers do
    if System.get_env("SHEAF_PHOENIX_DEV_MODE") in ~w(steady plain stable no_reload no-reload) do
      Application.stop(:phoenix_live_reload)
    end

    :ok
  end

  # Attach the OpenTelemetry span handlers for Phoenix, Bandit, and Finch. All
  # three packages work by subscribing to `:telemetry` events, so this only
  # needs to run once per node at boot.
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
