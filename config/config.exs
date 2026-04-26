# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sheaf,
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :sheaf, SheafWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SheafWeb.ErrorHTML, json: SheafWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sheaf.PubSub,
  live_view: [signing_salt: "Jcsjf8mK"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sheaf: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  sheaf: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# SPARQL.Client uses Tesla for HTTP requests. Keep it on Finch so it shares the
# same transport stack already running in the app.
config :tesla, :adapter, {Tesla.Adapter.Finch, name: Sheaf.Finch}

# OpenTelemetry is opt-in. The compile-time defaults are a no-op SDK (no
# exporter, no processors). Set `SHEAF_OTEL_REDIS_URL` in the environment to
# wire up the Redis Streams sink at runtime — see `config/runtime.exs`.
config :opentelemetry, traces_exporter: :none
config :opentelemetry, :processors, []

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
