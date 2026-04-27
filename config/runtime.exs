import Config

config :llm_db, load_dotenv: false

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/sheaf start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :sheaf, SheafWeb.Endpoint, server: true
end

http_ip =
  case System.get_env("SHEAF_HTTP_IP", "127.0.0.1")
       |> String.trim()
       |> String.split(".", trim: true)
       |> Enum.map(&Integer.parse/1) do
    [{a, ""}, {b, ""}, {c, ""}, {d, ""}] -> {a, b, c, d}
    _ -> {127, 0, 0, 1}
  end

http_port = String.to_integer(System.get_env("PORT", "4000"))

sparql_receive_timeout =
  String.to_integer(System.get_env("SHEAF_SPARQL_RECEIVE_TIMEOUT", "30000"))

ontology_base =
  System.get_env("SHEAF_ONTOLOGY_BASE", "https://less.rest/sheaf/")
  |> String.trim()
  |> then(fn value -> if String.ends_with?(value, "/"), do: value, else: value <> "/" end)

resource_base =
  System.get_env("SHEAF_RESOURCE_BASE") ||
    case System.get_env("PHX_HOST") do
      nil -> "https://example.com/sheaf/"
      "" -> "https://example.com/sheaf/"
      host -> "https://#{String.trim(host, "/")}/"
    end

resource_base =
  resource_base
  |> String.trim()
  |> then(fn value -> if String.ends_with?(value, "/"), do: value, else: value <> "/" end)

sparql_dataset =
  System.get_env("SHEAF_SPARQL_DATASET", "http://localhost:3030/sheaf")
  |> String.trim()
  |> String.trim_trailing("/")

sparql_username = System.get_env("SHEAF_SPARQL_USERNAME", "admin")
sparql_password = System.get_env("SHEAF_SPARQL_PASSWORD", "admin")

sparql_auth =
  if sparql_username != "" and sparql_password != "" do
    {:basic, "#{sparql_username}:#{sparql_password}"}
  end

gemini_api_key =
  ["GOOGLE_API_KEY", "GEMINI_API_KEY"]
  |> Enum.map(&System.get_env/1)
  |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

openai_api_key =
  ["OPENAI_API_KEY", "SHEAF_OPENAI_API_KEY"]
  |> Enum.map(&System.get_env/1)
  |> Enum.find(&(is_binary(&1) and String.trim(&1) != ""))

if gemini_api_key do
  config :req_llm, google_api_key: gemini_api_key
end

config :sheaf, Sheaf.Embedding,
  provider: System.get_env("SHEAF_EMBEDDING_PROVIDER", "openai"),
  api_key: gemini_api_key,
  openai_api_key: openai_api_key,
  base_url:
    System.get_env(
      "SHEAF_GEMINI_EMBEDDING_BASE_URL",
      "https://generativelanguage.googleapis.com/v1beta"
    ),
  openai_base_url: System.get_env("SHEAF_OPENAI_EMBEDDING_BASE_URL", "https://api.openai.com/v1"),
  model: System.get_env("SHEAF_GEMINI_EMBEDDING_MODEL", "gemini-embedding-2"),
  openai_model: System.get_env("SHEAF_OPENAI_EMBEDDING_MODEL", "text-embedding-3-large")

config :sheaf, Sheaf.Embedding.Store,
  path: System.get_env("SHEAF_EMBEDDINGS_DB", "var/sheaf-embeddings.sqlite3")

config :sheaf, Sheaf.TaskQueue.Store,
  path:
    System.get_env("SHEAF_TASK_QUEUE_DB") ||
      System.get_env("SHEAF_EMBEDDINGS_DB", "var/sheaf-embeddings.sqlite3")

config :sheaf, Sheaf.Repo, path: System.get_env("SHEAF_QUADLOG_DB", "var/sheaf-quadlog.sqlite3")

anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")

if anthropic_api_key && String.trim(anthropic_api_key) != "" do
  config :req_llm, anthropic_api_key: anthropic_api_key
end

config :sheaf, SheafWeb.Endpoint, http: [ip: http_ip, port: http_port]
config :sheaf, :resource_base, resource_base

config :sheaf, Sheaf,
  query_endpoint:
    System.get_env("SHEAF_SPARQL_QUERY_ENDPOINT", sparql_dataset <> "/sparql")
    |> String.trim(),
  update_endpoint:
    System.get_env("SHEAF_SPARQL_UPDATE_ENDPOINT", sparql_dataset <> "/update")
    |> String.trim(),
  data_endpoint:
    System.get_env("SHEAF_SPARQL_DATA_ENDPOINT", sparql_dataset <> "/data")
    |> String.trim(),
  sparql_auth: sparql_auth,
  data_auth: sparql_auth

config :sheaf_rdf_browser, SheafRDFBrowser.Snapshot,
  query_endpoint:
    (System.get_env("SHEAF_RDF_BROWSER_QUERY_ENDPOINT") ||
       System.get_env("SHEAF_SPARQL_QUERY_ENDPOINT", sparql_dataset <> "/sparql"))
    |> String.trim(),
  sparql_auth: sparql_auth,
  load_on_start:
    System.get_env("SHEAF_RDF_BROWSER_LOAD_ON_START", "true")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"]),
  refresh_max_concurrency:
    System.get_env("SHEAF_RDF_BROWSER_REFRESH_MAX_CONCURRENCY", "2")
    |> String.to_integer(),
  pubsub: Sheaf.PubSub

config :sheaf, Datalab,
  api_key: System.get_env("DATALAB_API_KEY"),
  pipeline_id: System.get_env("DATALAB_PIPELINE_ID", "pl_QWhrjJhpUUoo"),
  base_url: System.get_env("DATALAB_BASE_URL", "https://www.datalab.to/api/v1")

config :sparql_client,
  query_request_method: :post,
  update_request_method: :url_encoded,
  tesla_request_opts: [adapter: [receive_timeout: sparql_receive_timeout]]

# OpenTelemetry is opt-in: it only turns on when `SHEAF_OTEL_REDIS_URL` is set
# in the environment. When enabled, every ended span is shipped to a Redis
# Stream (`otel:spans` by default) via `Sheaf.Tracing.RedisSinkProcessor`; the
# Go CLI in `tools/otel-tail` consumes from there. Setting `OTEL_SDK_DISABLED`
# (or `SHEAF_OTEL_DISABLED`) is honoured as a manual override even when a
# Redis URL is configured.
otel_truthy = fn value ->
  case value do
    nil -> false
    "" -> false
    other -> String.downcase(String.trim(other)) in ["1", "true", "yes", "on"]
  end
end

otel_redis_url =
  case System.get_env("SHEAF_OTEL_REDIS_URL") do
    nil -> nil
    "" -> nil
    url -> String.trim(url)
  end

otel_force_disabled? =
  otel_truthy.(System.get_env("OTEL_SDK_DISABLED")) or
    otel_truthy.(System.get_env("SHEAF_OTEL_DISABLED"))

otel_enabled? = config_env() != :test and is_binary(otel_redis_url) and not otel_force_disabled?

if otel_enabled? do
  otel_service_name =
    System.get_env("OTEL_SERVICE_NAME") ||
      System.get_env("SHEAF_OTEL_SERVICE_NAME") ||
      "sheaf"

  otel_deployment_env =
    System.get_env("SHEAF_OTEL_ENVIRONMENT") ||
      case config_env() do
        :prod -> System.get_env("PHX_HOST", "production")
        env -> Atom.to_string(env)
      end

  otel_host_name =
    System.get_env("HOSTNAME") ||
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> nil
      end

  otel_resource_attributes =
    [
      {"service.name", otel_service_name},
      {"service.namespace", "sheaf"},
      {"deployment.environment", otel_deployment_env},
      {"host.name", otel_host_name}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

  config :opentelemetry, resource: otel_resource_attributes
  config :opentelemetry, :processors, [{Sheaf.Tracing.RedisSinkProcessor, %{}}]

  # Per-instance stream so a shared Redis on a single host (e.g. staging and
  # production both writing to localhost:6379) doesn't have one instance evict
  # the other's spans via MAXLEN. The default tracks SHEAF_NODE_BASENAME, which
  # already drives the systemd unit and BEAM sname; SHEAF_OTEL_STREAM is the
  # explicit override.
  otel_node_basename = System.get_env("SHEAF_NODE_BASENAME", "sheaf")
  otel_default_stream = "otel:spans:#{otel_node_basename}"

  config :sheaf, Sheaf.Tracing.RedisSink,
    redis_url: otel_redis_url,
    stream: System.get_env("SHEAF_OTEL_STREAM", otel_default_stream)
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :sheaf, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :sheaf, SheafWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: http_ip, port: http_port],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :sheaf, SheafWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :sheaf, SheafWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
