defmodule Sheaf do
  @moduledoc """
  Core helpers for minting resource IRIs and working with the Graph Store.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.{Data, Dataset, Graph, Serialization}

  @dataset_media_type "application/n-quads"
  @graph_media_type "application/n-triples"
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

  The label is recorded in telemetry span metadata as `sheaf.query_label`.
  """
  def query(label, query, opts \\ []) when is_binary(label) and byte_size(label) > 0 do
    config = Application.fetch_env!(:sheaf, __MODULE__)
    opts = Keyword.put_new(opts, :protocol_version, "1.1")

    with_sparql_span("sheaf.query", label, "query", config[:query_endpoint], query, fn ->
      query_sparql(query, config[:query_endpoint], sparql_options(config, opts))
    end)
  end

  @doc """
  Runs a SPARQL SELECT query against the configured query endpoint.

  Hand-written query strings are executed in SPARQL.Client raw mode by default.
  The label is recorded in telemetry span metadata as `sheaf.query_label`.
  """
  def select(label, query, opts \\ []) when is_binary(label) and byte_size(label) > 0 do
    config = Application.fetch_env!(:sheaf, __MODULE__)

    opts =
      opts
      |> Keyword.put_new(:protocol_version, "1.1")
      |> Keyword.put_new(:raw_mode, true)

    with_sparql_span("sheaf.select", label, "select", config[:query_endpoint], query, fn ->
      result = query_sparql(:select, query, config[:query_endpoint], sparql_options(config, opts))

      with {:ok, %SPARQL.Query.Result{results: rows}} <- result do
        Tracer.set_attribute("sheaf.row_count", length(rows))
      end

      result
    end)
  end

  @doc """
  Runs a SPARQL update against the configured update endpoint.

  Hand-written update strings are executed in SPARQL.Client raw mode by default.
  The label is recorded in telemetry span metadata as `sheaf.query_label`.
  """
  def update(label, update, opts \\ []) when is_binary(label) and byte_size(label) > 0 do
    config = Application.fetch_env!(:sheaf, __MODULE__)
    endpoint = config[:update_endpoint] || config[:query_endpoint]
    opts = Keyword.put_new(opts, :raw_mode, true)

    with_sparql_span("sheaf.update", label, "update", endpoint, update, fn ->
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
  defp with_sparql_span(name, label, operation, endpoint, statement, fun) do
    Tracer.with_span name, %{
      kind: :client,
      attributes: [
        {"db.system", "fuseki"},
        {"db.operation", operation},
        {"db.statement", sparql_statement(statement)},
        {"sheaf.query_label", label},
        {"sheaf.statement_bytes", sparql_statement_bytes(statement)},
        {"server.address", endpoint}
      ]
    } do
      fun.()
    end
  end

  defp sparql_statement(statement) when is_binary(statement), do: statement
  defp sparql_statement(statement), do: inspect(statement, limit: :infinity)

  defp sparql_statement_bytes(statement) when is_binary(statement), do: byte_size(statement)
  defp sparql_statement_bytes(statement), do: statement |> sparql_statement() |> byte_size()

  defp query_sparql(%SPARQL.Query{} = query, endpoint, opts) do
    query_sparql(query.form, query.query_string, endpoint, opts)
  end

  defp query_sparql(query_string, endpoint, opts) when is_binary(query_string) do
    with %SPARQL.Query{} = query <- SPARQL.Query.new(query_string) do
      query_sparql(query, endpoint, opts)
    end
  end

  defp query_sparql(form, query_string, endpoint, opts) do
    with {:ok, request} <-
           SPARQL.Client.Request.build(SPARQL.Client.Query, form, query_string, endpoint, opts),
         {:ok, request} <- sparql_http_request(request, opts),
         {:ok, request} <- parse_sparql_response(request, opts) do
      {:ok, request.result}
    end
  end

  defp sparql_http_request(request, opts) do
    case SPARQL.Client.Tesla.call(request, opts) do
      {:ok, %SPARQL.Client.Request{http_status: status} = request} when status in 200..299 ->
        {:ok, request}

      {:ok, %SPARQL.Client.Request{} = request} ->
        {:error, %SPARQL.Client.HTTPError{request: request, status: request.http_status}}

      error ->
        error
    end
  end

  defp parse_sparql_response(request, opts) do
    Tracer.with_span "sheaf.sparql.parse", %{
      kind: :internal,
      attributes: [
        {"db.system", "fuseki"},
        {"db.operation", to_string(request.sparql_operation_form)},
        {"sheaf.response_bytes", byte_size(request.http_response_body || "")},
        {"sheaf.response_content_type", request.http_response_content_type || ""}
      ]
    } do
      result = SPARQL.Client.Query.evaluate_response(request, opts)

      with {:ok, %SPARQL.Client.Request{result: parsed}} <- result do
        set_sparql_parse_result_attributes(parsed)
      end

      result
    end
  end

  defp set_sparql_parse_result_attributes(%SPARQL.Query.Result{results: rows}) do
    Tracer.set_attribute("sheaf.row_count", length(rows))
  end

  defp set_sparql_parse_result_attributes(data) do
    if Data.impl_for(data) do
      Tracer.set_attribute("sheaf.statement_count", Data.statement_count(data))
    end
  rescue
    Protocol.UndefinedError -> :ok
  end

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
