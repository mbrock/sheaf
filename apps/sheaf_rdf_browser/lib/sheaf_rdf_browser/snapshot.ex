defmodule SheafRDFBrowser.Snapshot do
  @moduledoc """
  Keeps a broad, dataset-shaped RDF browser snapshot in memory.

  The snapshot is intentionally generic: it fetches small SPARQL result tables
  for ontology/index predicates and derives display indexes from those rows. It
  is not meant to be the live source of truth.
  """

  use GenServer

  alias SheafRDFBrowser.Index

  @label_query """
  PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
  PREFIX dcterms: <http://purl.org/dc/terms/>

  SELECT ?g ?s ?p ?o
  WHERE {
    GRAPH ?g {
      ?s ?p ?o .
      VALUES ?p {
        rdfs:label skos:prefLabel dcterms:title
      }
    }
  }
  """

  @comment_query """
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
  PREFIX dcterms: <http://purl.org/dc/terms/>

  SELECT ?g ?s ?p ?o
  WHERE {
    GRAPH ?g {
      ?s ?p ?o .
      VALUES ?p {
        rdfs:comment skos:definition dcterms:description
      }
    }
  }
  """

  @class_counts_query """
  PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>

  SELECT ?class (COUNT(*) AS ?count)
  WHERE {
    GRAPH ?g { ?s rdf:type ?class }
  }
  GROUP BY ?class
  """

  @predicate_counts_query """
  SELECT ?p (COUNT(*) AS ?count)
  WHERE {
    GRAPH ?g { ?s ?p ?o }
  }
  GROUP BY ?p
  """

  @graph_counts_query """
  SELECT ?g (COUNT(*) AS ?count)
  WHERE {
    GRAPH ?g { ?s ?p ?o }
  }
  GROUP BY ?g
  """

  @ontology_types_query """
  PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  PREFIX owl: <http://www.w3.org/2002/07/owl#>

  SELECT ?s ?class
  WHERE {
    GRAPH ?g {
      ?s rdf:type ?class .
      VALUES ?class {
        rdfs:Class owl:Class
        rdf:Property owl:ObjectProperty owl:DatatypeProperty owl:AnnotationProperty
      }
    }
  }
  """

  @subclass_query """
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?child ?parent
  WHERE {
    GRAPH ?g { ?child rdfs:subClassOf ?parent }
  }
  """

  @subproperty_query """
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?child ?parent
  WHERE {
    GRAPH ?g { ?child rdfs:subPropertyOf ?parent }
  }
  """

  @domain_query """
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?s ?o
  WHERE {
    GRAPH ?g { ?s rdfs:domain ?o }
  }
  """

  @range_query """
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?s ?o
  WHERE {
    GRAPH ?g { ?s rdfs:range ?o }
  }
  """

  defstruct status: :empty,
            dataset: nil,
            index: Index.empty(),
            loaded_at: nil,
            error: nil,
            query_ms: nil,
            predicate_query_ms: nil,
            parse_ms: nil,
            index_ms: nil,
            bytes: 0,
            quads: 0,
            graphs: 0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  def refresh(timeout \\ 120_000) do
    GenServer.call(__MODULE__, :refresh, timeout)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{}

    if config()[:load_on_start] do
      {:ok, %{state | status: :loading}, {:continue, :refresh}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:refresh, _from, state) do
    state = %{state | status: :loading, error: nil}
    state = do_refresh(state)
    {:reply, state, state}
  end

  defp do_refresh(state) do
    with {:ok, rows, query_ms, predicate_query_ms} <- fetch_rows() do
      {index, index_ms} = timed(fn -> Index.build_from_rows(rows) end)

      quads = rows.graph_counts |> Map.values() |> Enum.sum()

      %{
        state
        | status: :ready,
          dataset: nil,
          index: index,
          loaded_at: DateTime.utc_now(),
          error: nil,
          query_ms: query_ms,
          predicate_query_ms: predicate_query_ms,
          parse_ms: 0,
          index_ms: index_ms,
          bytes: 0,
          quads: quads,
          graphs: map_size(rows.graph_counts)
      }
    else
      {:error, reason} ->
        %{state | status: :error, error: inspect(reason)}
    end
  end

  defp fetch_rows do
    with {:ok, results, query_ms} <- fetch_selects() do
      {:ok,
       %{
         labels: rows(bindings(results, :labels), [:g, :s, :p, :o]),
         comments: rows(bindings(results, :comments), [:g, :s, :p, :o]),
         class_counts: counts(bindings(results, :class_counts), "class"),
         predicate_counts: counts(bindings(results, :predicate_counts), "p"),
         graph_counts: counts(bindings(results, :graph_counts), "g"),
         ontology_types: rows(bindings(results, :ontology_types), [:s, {:class, "class"}]),
         subclass_edges:
           rows(bindings(results, :subclass_edges), child: "child", parent: "parent"),
         subproperty_edges:
           rows(bindings(results, :subproperty_edges), child: "child", parent: "parent"),
         domains: rows(bindings(results, :domains), [:s, :o]),
         ranges: rows(bindings(results, :ranges), [:s, :o])
       }, query_ms, query_ms(results, :predicate_counts)}
    end
  end

  defp fetch_selects do
    {result, query_ms} =
      timed(fn ->
        query_specs()
        |> Task.async_stream(&fetch_named_select/1,
          max_concurrency: System.schedulers_online(),
          ordered: false,
          timeout: 120_000
        )
        |> Enum.reduce({:ok, %{}}, fn
          {:ok, {:ok, name, bindings, query_ms}}, {:ok, acc} ->
            {:ok, Map.put(acc, name, %{bindings: bindings, query_ms: query_ms})}

          {:ok, {:error, reason}}, {:ok, _acc} ->
            {:error, reason}

          {:exit, reason}, {:ok, _acc} ->
            {:error, reason}

          _result, {:error, reason} ->
            {:error, reason}
        end)
      end)

    case result do
      {:ok, results} -> {:ok, results, query_ms}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_named_select({name, query}) do
    with {:ok, bindings, query_ms} <- fetch_select(query) do
      {:ok, name, bindings, query_ms}
    end
  end

  defp query_specs do
    [
      labels: @label_query,
      comments: @comment_query,
      class_counts: @class_counts_query,
      predicate_counts: @predicate_counts_query,
      graph_counts: @graph_counts_query,
      ontology_types: @ontology_types_query,
      subclass_edges: @subclass_query,
      subproperty_edges: @subproperty_query,
      domains: @domain_query,
      ranges: @range_query
    ]
  end

  defp bindings(results, name), do: get_in(results, [name, :bindings])
  defp query_ms(results, name), do: get_in(results, [name, :query_ms])

  defp fetch_select(query) do
    conf = config()

    request =
      Req.new(
        url: Keyword.fetch!(conf, :query_endpoint),
        auth: conf[:sparql_auth],
        headers: [accept: "application/sparql-results+json"],
        form: [query: query],
        http_errors: :raise
      )

    try do
      {response, ms} = timed(fn -> Req.post!(request) end)
      {:ok, decode_bindings(response.body), ms}
    rescue
      error -> {:error, error}
    end
  end

  defp decode_bindings(body) when is_binary(body) do
    body
    |> Jason.decode!()
    |> get_in(["results", "bindings"])
  end

  defp decode_bindings(%{"results" => %{"bindings" => bindings}}), do: bindings

  defp counts(bindings, key) do
    Map.new(bindings, fn binding ->
      {value(binding, key), value(binding, "count") |> String.to_integer()}
    end)
  end

  defp rows(bindings, fields) do
    Enum.map(bindings, fn binding ->
      Map.new(fields, fn
        field when is_atom(field) -> {field, value(binding, Atom.to_string(field))}
        {field, sparql_name} -> {field, value(binding, sparql_name)}
      end)
    end)
  end

  defp value(binding, name) do
    case Map.fetch!(binding, name) do
      %{"type" => "bnode", "value" => value} -> "_:" <> value
      %{"value" => value} -> value
    end
  end

  defp timed(fun) do
    {micros, value} = :timer.tc(fun)
    {value, div(micros, 1_000)}
  end

  defp config do
    Application.get_env(:sheaf_rdf_browser, __MODULE__,
      query_endpoint: "http://localhost:3030/sheaf/sparql",
      sparql_auth: {:basic, "admin:admin"},
      load_on_start: true
    )
  end
end
