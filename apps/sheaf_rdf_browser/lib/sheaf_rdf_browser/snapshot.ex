defmodule SheafRDFBrowser.Snapshot do
  @moduledoc """
  Keeps a broad, dataset-shaped RDF browser snapshot in memory.

  The snapshot is intentionally generic: it reads the current RDF dataset and
  derives display indexes from simple graph walks. It is not meant to be the
  live source of truth.
  """

  use GenServer

  alias SheafRDFBrowser.Index

  defstruct status: :empty,
            dataset: nil,
            index: Index.empty(),
            loaded_at: nil,
            fingerprint: nil,
            error: nil,
            query_ms: nil,
            predicate_query_ms: nil,
            parse_ms: nil,
            index_ms: nil,
            bytes: 0,
            quads: 0,
            graphs: 0,
            class_property_cache: %{}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get do
    GenServer.call(__MODULE__, :get)
  end

  def refresh(timeout \\ 120_000) do
    GenServer.call(__MODULE__, :refresh, timeout)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(pubsub(), topic())
  end

  def class_properties(class_iri) when is_binary(class_iri) do
    GenServer.call(__MODULE__, {:class_properties, class_iri})
  end

  def cached_class_properties(class_iri) when is_binary(class_iri) do
    GenServer.call(__MODULE__, {:cached_class_properties, class_iri})
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
    state = refresh_and_publish(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  def handle_call(:refresh, _from, state) do
    state = %{state | status: :loading, error: nil}
    state = refresh_and_publish(state)
    {:reply, state, state}
  end

  def handle_call({:class_properties, class_iri}, _from, state) do
    rows = Map.get(state.class_property_cache, class_iri, [])
    {:reply, {:ok, rows, 0}, state}
  end

  def handle_call({:cached_class_properties, class_iri}, _from, state) do
    reply =
      case Map.fetch(state.class_property_cache, class_iri) do
        {:ok, rows} -> {:ok, rows, 0}
        :error -> :miss
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = refresh_and_publish(state)
    {:noreply, state}
  end

  defp refresh_and_publish(state) do
    state
    |> do_refresh()
    |> publish_if_changed(state.fingerprint)
  end

  defp do_refresh(state) do
    with {:ok, rows, query_ms, predicate_query_ms} <- fetch_rows() do
      {index, index_ms} = timed(fn -> Index.build_from_rows(rows) end)

      quads = rows.graph_counts |> Map.values() |> Enum.sum()
      fingerprint = fingerprint(index, quads, map_size(rows.graph_counts))

      %{
        state
        | status: :ready,
          dataset: nil,
          index: index,
          loaded_at: DateTime.utc_now(),
          fingerprint: fingerprint,
          error: nil,
          query_ms: query_ms,
          predicate_query_ms: predicate_query_ms,
          parse_ms: 0,
          index_ms: index_ms,
          bytes: 0,
          quads: quads,
          graphs: map_size(rows.graph_counts),
          class_property_cache: class_property_cache(Map.get(rows, :class_property_usage, []))
      }
    else
      {:error, reason} ->
        error = inspect(reason)
        %{state | status: :error, error: error, fingerprint: :erlang.phash2({:error, error})}
    end
  end

  defp publish_if_changed(%__MODULE__{} = state, old_fingerprint) do
    if state.fingerprint != old_fingerprint do
      Phoenix.PubSub.broadcast(pubsub(), topic(), {:snapshot_updated, state})
    end

    state
  end

  defp fingerprint(index, quads, graphs) do
    :erlang.phash2(
      {quads, graphs, index.labels, index.comments, index.ontologies, index.class_counts,
       index.predicate_counts, index.class_terms, index.property_terms, index.subclass_edges,
       index.subproperty_edges, index.domains, index.ranges}
    )
  end

  defp fetch_rows do
    {result, query_ms} =
      timed(fn ->
        with {:ok, dataset} <- fetch_dataset() do
          {:ok, rows_from_dataset(dataset)}
        end
      end)

    case result do
      {:ok, rows} -> {:ok, rows, query_ms, query_ms}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_dataset do
    try do
      case config()[:dataset] do
        {module, function, args} -> apply(module, function, args)
        fun when is_function(fun, 0) -> fun.()
        nil -> {:error, :missing_dataset_source}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp rows_from_dataset(dataset) do
    quads = quads(dataset)

    %{
      labels: simple_rows(quads, &label?/1),
      comments: simple_rows(quads, &comment?/1),
      class_counts: count_by(for({_g, _s, p, o} <- quads, p == rdf_type(), do: term(o))),
      predicate_counts: count_by(for({_g, _s, p, _o} <- quads, do: term(p))),
      graph_counts: count_by(for({g, _s, _p, _o} <- quads, do: g)),
      ontologies: ontology_rows(quads),
      ontology_types: ontology_type_rows(quads),
      subclass_edges: edge_rows(quads, rdfs("subClassOf"), :child, :parent),
      subproperty_edges: edge_rows(quads, rdfs("subPropertyOf"), :child, :parent),
      domains: subject_object_rows(quads, rdfs("domain")),
      ranges: subject_object_rows(quads, rdfs("range")),
      class_property_usage: class_property_usage_binding_rows(quads)
    }
  end

  defp quads(dataset) do
    dataset
    |> RDF.Dataset.graphs()
    |> Enum.flat_map(fn graph ->
      Enum.map(RDF.Graph.triples(graph), fn {s, p, o} -> {term(graph.name), s, p, o} end)
    end)
  end

  defp simple_rows(quads, predicate?) do
    for {g, s, p, o} <- quads, predicate?.(p), do: %{g: g, s: term(s), p: term(p), o: term(o)}
  end

  defp label?(predicate) do
    term(predicate) in [
      rdfs("label"),
      "http://www.w3.org/2004/02/skos/core#prefLabel",
      "http://purl.org/dc/elements/1.1/title",
      "http://purl.org/dc/terms/title"
    ]
  end

  defp comment?(predicate) do
    term(predicate) in [
      rdfs("comment"),
      "http://www.w3.org/2004/02/skos/core#definition",
      "http://www.w3.org/2004/02/skos/core#scopeNote",
      "http://www.w3.org/2004/02/skos/core#editorialNote",
      "http://purl.org/dc/elements/1.1/description",
      "http://purl.org/dc/terms/description",
      "http://www.w3.org/ns/prov#definition",
      "http://www.w3.org/ns/prov#editorsDefinition"
    ]
  end

  defp count_by(values) do
    values
    |> Enum.frequencies()
    |> Map.delete(nil)
  end

  defp ontology_rows(quads) do
    ontologies =
      for {_g, s, p, o} <- quads,
          p == rdf_type(),
          term(o) == "http://www.w3.org/2002/07/owl#Ontology",
          into: MapSet.new(),
          do: s

    for {_g, s, p, o} <- quads, MapSet.member?(ontologies, s) do
      %{ontology: term(s), p: term(p), o: term(o)}
    end
  end

  defp ontology_type_rows(quads) do
    classes =
      MapSet.new([
        rdfs("Class"),
        "http://www.w3.org/2002/07/owl#Class",
        rdf("Property"),
        "http://www.w3.org/2002/07/owl#ObjectProperty",
        "http://www.w3.org/2002/07/owl#DatatypeProperty",
        "http://www.w3.org/2002/07/owl#AnnotationProperty"
      ])

    for {_g, s, p, o} <- quads,
        p == rdf_type(),
        MapSet.member?(classes, term(o)),
        do: %{s: term(s), class: term(o)}
  end

  defp edge_rows(quads, predicate, child_key, parent_key) do
    for {_g, s, p, o} <- quads, term(p) == predicate do
      %{child_key => term(s), parent_key => term(o)}
    end
  end

  defp subject_object_rows(quads, predicate) do
    for {_g, s, p, o} <- quads, term(p) == predicate, do: %{s: term(s), o: term(o)}
  end

  defp class_property_usage_binding_rows(quads) do
    rdf_type = rdf_type()

    types =
      quads
      |> Enum.flat_map(fn
        {_g, resource, ^rdf_type, class} -> [{resource, term(class)}]
        _quad -> []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    subject_rows =
      for {_g, resource, p, _o} <- quads,
          class <- Map.get(types, resource, []),
          do: {class, term(p), "subject"}

    object_rows =
      for {_g, _s, p, resource} <- quads,
          class <- Map.get(types, resource, []),
          do: {class, term(p), "object"}

    (subject_rows ++ object_rows)
    |> Enum.frequencies()
    |> Enum.map(fn {{class, property, role}, count} ->
      %{class: class, property: property, role: role, count: Integer.to_string(count)}
    end)
  end

  defp rdf_type, do: RDF.type()
  defp rdf(local), do: "http://www.w3.org/1999/02/22-rdf-syntax-ns##{local}"
  defp rdfs(local), do: "http://www.w3.org/2000/01/rdf-schema##{local}"
  defp term(nil), do: nil
  defp term(value), do: RDF.Term.value(value) |> to_string()

  defp class_property_cache(rows) do
    rows
    |> Enum.group_by(& &1.class)
    |> Map.new(fn {class, rows} ->
      {class, class_property_usage_rows(rows)}
    end)
  end

  defp class_property_usage_rows(rows) do
    rows
    |> Enum.group_by(& &1.property)
    |> Enum.map(fn {property, rows} ->
      subject_count = role_count(rows, "subject")
      object_count = role_count(rows, "object")

      %{
        property: property,
        count: subject_count + object_count,
        subject_count: subject_count,
        object_count: object_count
      }
    end)
  end

  defp role_count(rows, role) do
    rows
    |> Enum.filter(&(&1.role == role))
    |> Enum.map(&String.to_integer(&1.count))
    |> Enum.sum()
  end

  defp timed(fun) do
    {micros, value} = :timer.tc(fun)
    {value, div(micros, 1_000)}
  end

  defp config do
    Application.get_env(:sheaf_rdf_browser, __MODULE__,
      query_endpoint: "http://localhost:3030/sheaf/sparql",
      sparql_auth: {:basic, "admin:admin"},
      load_on_start: true,
      refresh_max_concurrency: 2,
      pubsub: Sheaf.PubSub
    )
  end

  defp pubsub, do: Keyword.fetch!(config(), :pubsub)
  defp topic, do: "sheaf_rdf_browser:snapshot"
end
