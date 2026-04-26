defmodule Sheaf do
  @moduledoc """
  Core helpers for minting resource IRIs and working with the Graph Store.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.{Data, Dataset, Graph, Serialization}

  @dataset_media_type "application/n-quads"
  @graph_media_type "application/n-triples"
  # Cap how much of a SPARQL statement we attach as a span attribute. Most
  # tracing backends throttle very large strings, and the operation name plus a
  # generous prefix is enough to identify the query in practice.
  @sparql_statement_attr_limit 4096

  @doc """
  Generates a new unique IRI for a resource.
  """
  def mint do
    Sheaf.Id.iri(Sheaf.Id.generate())
  end

  @doc """
  Fetches the default graph through the Graph Store endpoint.
  """
  def fetch_graph do
    with {:ok, dataset} <- fetch_dataset() do
      {:ok, Dataset.default_graph(dataset)}
    end
  end

  @doc """
  Fetches a named graph through the Graph Store endpoint.
  """
  def fetch_graph(graph_name) do
    Tracer.with_span "sheaf.fetch_graph", %{
      kind: :client,
      attributes: [
        {"db.system", "fuseki"},
        {"db.operation", "fetch_graph"},
        {"sheaf.graph", to_string(graph_name)}
      ]
    } do
      response =
        data_client()
        |> Req.get!(
          span_name: "GET /sheaf/data",
          headers: [accept: @graph_media_type],
          params: [graph: to_string(graph_name)]
        )

      graph = read_graph(response)
      Tracer.set_attribute("sheaf.statement_count", Data.statement_count(graph))

      {:ok, graph}
    end
  end

  @doc """
  Replaces a named graph through the Graph Store endpoint.
  """
  def put_graph(graph_name, %Graph{} = graph) do
    Tracer.with_span "sheaf.put_graph", %{
      kind: :client,
      attributes: [
        {"db.system", "fuseki"},
        {"db.operation", "put_graph"},
        {"sheaf.graph", to_string(graph_name)},
        {"sheaf.statement_count", Data.statement_count(graph)}
      ]
    } do
      Req.put!(
        data_client(),
        span_name: "PUT /sheaf/data",
        headers: [content_type: @graph_media_type],
        params: [graph: to_string(graph_name)],
        body: write_graph(graph)
      )

      :ok
    end
  end

  @doc """
  Runs a SPARQL query against the configured query endpoint.
  """
  def query(query, opts \\ []) do
    config = Application.fetch_env!(:sheaf, __MODULE__)
    opts = Keyword.put_new(opts, :protocol_version, "1.1")

    with_sparql_span("sheaf.query", "query", config[:query_endpoint], query, fn ->
      SPARQL.Client.query(query, config[:query_endpoint], sparql_options(config, opts))
    end)
  end

  @doc """
  Runs a SPARQL SELECT query against the configured query endpoint.

  Hand-written query strings are executed in SPARQL.Client raw mode by default.
  """
  def select(query, opts \\ []) do
    config = Application.fetch_env!(:sheaf, __MODULE__)

    opts =
      opts
      |> Keyword.put_new(:protocol_version, "1.1")
      |> Keyword.put_new(:raw_mode, true)

    with_sparql_span("sheaf.select", "select", config[:query_endpoint], query, fn ->
      result = SPARQL.Client.select(query, config[:query_endpoint], sparql_options(config, opts))

      with {:ok, %SPARQL.Query.Result{results: rows}} <- result do
        Tracer.set_attribute("sheaf.row_count", length(rows))
      end

      result
    end)
  end

  @doc """
  Runs a SPARQL update against the configured update endpoint.

  Hand-written update strings are executed in SPARQL.Client raw mode by default.
  """
  def update(update, opts \\ []) do
    config = Application.fetch_env!(:sheaf, __MODULE__)
    endpoint = config[:update_endpoint] || config[:query_endpoint]
    opts = Keyword.put_new(opts, :raw_mode, true)

    with_sparql_span("sheaf.update", "update", endpoint, update, fn ->
      SPARQL.Client.update(update, endpoint, sparql_options(config, opts))
    end)
  end

  def data_client do
    config = Application.fetch_env!(:sheaf, __MODULE__)

    Req.new(
      url: config[:data_endpoint],
      auth: config[:data_auth],
      http_errors: :raise
    )
    |> OpentelemetryReq.attach(propagate_trace_headers: true)
  end

  @doc false
  def rpc_eval(gl, code) when is_pid(gl) and is_binary(code) do
    Process.group_leader(self(), gl)
    {result, _bindings} = Code.eval_string(code)
    result
  end

  @doc """
  Loads the whole dataset through the Graph Store endpoint, applies `fun`, and
  replaces the dataset with the result.
  """
  def migrate(fun) when is_function(fun, 1) do
    Tracer.with_span "sheaf.migrate", %{kind: :internal} do
      with {:ok, dataset} <- fetch_dataset(),
           migrated_dataset = fun.(dataset),
           :ok <- put_dataset(migrated_dataset) do
        Tracer.set_attribute("sheaf.statement_count", Data.statement_count(migrated_dataset))
        {:ok, migrated_dataset}
      end
    end
  end

  @doc """
  Fetches the whole dataset through the Graph Store endpoint.
  """
  def fetch_dataset do
    Tracer.with_span "sheaf.fetch_dataset", %{
      kind: :client,
      attributes: [{"db.system", "fuseki"}, {"db.operation", "fetch_dataset"}]
    } do
      dataset =
        data_client()
        |> Req.get!(
          span_name: "GET /sheaf/data",
          headers: [accept: @dataset_media_type]
        )
        |> read_dataset()

      Tracer.set_attribute("sheaf.statement_count", Data.statement_count(dataset))

      {:ok, dataset}
    end
  end

  defp put_dataset(%Dataset{} = dataset) do
    Tracer.with_span "sheaf.put_dataset", %{
      kind: :client,
      attributes: [
        {"db.system", "fuseki"},
        {"db.operation", "put_dataset"},
        {"sheaf.statement_count", Data.statement_count(dataset)}
      ]
    } do
      Req.put!(
        data_client(),
        span_name: "PUT /sheaf/data",
        headers: [content_type: @dataset_media_type],
        body: write_dataset(dataset)
      )

      :ok
    end
  end

  defp read_dataset(response), do: read_body(response, @dataset_media_type)
  defp read_graph(response), do: read_body(response, @graph_media_type)

  defp read_body(response, media_type) do
    body = Map.fetch!(response, :body)

    Tracer.with_span "sheaf.serialization.read", %{
      attributes: [
        {"sheaf.media_type", media_type},
        {"sheaf.body_bytes", byte_size(body)}
      ]
    } do
      Serialization.read_string!(body, media_type: media_type)
    end
  end

  defp write_dataset(dataset), do: write(dataset, @dataset_media_type)
  defp write_graph(graph), do: write(graph, @graph_media_type)

  defp write(data, media_type) do
    Tracer.with_span "sheaf.serialization.write", %{
      attributes: [
        {"sheaf.media_type", media_type},
        {"sheaf.statement_count", Data.statement_count(data)}
      ]
    } do
      body = Serialization.write_string!(data, media_type: media_type)
      Tracer.set_attribute("sheaf.body_bytes", byte_size(body))
      body
    end
  end

  # SPARQL spans share enough boilerplate that it's worth a tiny helper. We
  # follow the OpenTelemetry semantic conventions for database client spans
  # (`db.system`, `db.operation`, `db.statement`) so any future tooling that
  # understands those tags works without further mapping.
  defp with_sparql_span(name, operation, endpoint, statement, fun) do
    Tracer.with_span name, %{
      kind: :client,
      attributes: [
        {"db.system", "fuseki"},
        {"db.operation", operation},
        {"db.statement", truncate_statement(statement)},
        {"server.address", endpoint}
      ]
    } do
      fun.()
    end
  end

  defp truncate_statement(statement) when is_binary(statement) do
    String.slice(statement, 0, @sparql_statement_attr_limit)
  end

  defp truncate_statement(statement), do: inspect(statement, limit: 64)

  defp sparql_options(config, opts) do
    case sparql_auth_headers(config) do
      headers when map_size(headers) == 0 ->
        opts

      headers ->
        Keyword.update(opts, :headers, headers, &merge_headers(headers, &1))
    end
  end

  defp sparql_auth_headers(config) do
    case config[:sparql_auth] || config[:data_auth] do
      {:basic, credentials} when is_binary(credentials) ->
        %{"Authorization" => "Basic " <> Base.encode64(credentials)}

      nil ->
        %{}
    end
  end

  defp merge_headers(default_headers, headers) when is_map(headers) do
    Map.merge(default_headers, headers)
  end

  defp merge_headers(default_headers, fun) when is_function(fun, 2) do
    fn request, headers -> Map.merge(default_headers, fun.(request, headers)) end
  end
end
