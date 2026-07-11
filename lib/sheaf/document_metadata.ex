defmodule Sheaf.DocumentMetadata do
  @moduledoc """
  Applies verified bibliographic metadata to an existing Sheaf document.
  """

  use RDF

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.NS.{DCTERMS, FABIO, FOAF}

  @replaceable_predicates [
    RDF.type(),
    DCTERMS.title(),
    DCTERMS.creator(),
    DCTERMS.isPartOf(),
    DCTERMS.identifier(),
    FABIO.hasDOI(),
    FABIO.hasPublicationYear()
  ]

  @type result :: %{
          document_id: String.t(),
          expression: RDF.IRI.t(),
          fields: [atom()],
          statement_count: non_neg_integer()
        }

  @spec update(String.t(), map()) :: {:ok, result()} | {:error, term()}
  def update(document_id, attrs)
      when is_binary(document_id) and is_map(attrs) do
    document_id = String.trim_leading(String.trim(document_id), "#")
    document = Sheaf.Id.iri(document_id)
    graph_name = Sheaf.MetadataResolver.metadata_graph()

    Tracer.with_span "sheaf.document_metadata.update", %{
      kind: :internal,
      attributes: [
        {"sheaf.document.id", document_id},
        {"sheaf.metadata.fields",
         attrs |> Map.keys() |> Enum.map_join(",", &to_string/1)}
      ]
    } do
      with {:ok, %{kind: :document}} <-
             Sheaf.ResourceResolver.resolve(document_id),
           {:ok, graph} <- Sheaf.fetch_graph(graph_name),
           {updated, expression, fields} <-
             apply_metadata(graph, document, attrs),
           :ok <- Sheaf.put_graph(graph_name, updated) do
        Sheaf.Documents.clear_cache()

        {:ok,
         %{
           document_id: document_id,
           expression: expression,
           fields: fields,
           statement_count: RDF.Data.statement_count(updated)
         }}
      else
        {:error, :not_found} ->
          {:error, "document ##{document_id} was not found"}

        error ->
          error
      end
    end
  end

  @doc false
  def apply_metadata(%Graph{} = graph, document, attrs) do
    expression = existing_expression(graph, document) || Sheaf.mint()
    supplied = supplied_fields(attrs)

    graph =
      graph
      |> remove_expression_fields(expression, supplied)
      |> ensure_expression_link(document, expression)
      |> add_expression_metadata(expression, attrs)

    {graph, expression, supplied}
  end

  defp existing_expression(graph, document) do
    representation = FABIO.isRepresentationOf()

    graph
    |> Graph.triples()
    |> Enum.find_value(fn
      {^document, ^representation, expression} -> expression
      _ -> nil
    end)
  end

  defp remove_expression_fields(graph, expression, fields) do
    predicates =
      fields
      |> Enum.flat_map(&field_predicates/1)
      |> MapSet.new()

    graph
    |> Graph.triples()
    |> Enum.reject(fn {subject, predicate, _object} ->
      subject == expression and MapSet.member?(predicates, predicate)
    end)
    |> Graph.new(name: Graph.name(graph))
  end

  defp ensure_expression_link(graph, document, expression) do
    Graph.add(graph, {document, FABIO.isRepresentationOf(), expression})
  end

  defp add_expression_metadata(graph, expression, attrs) do
    graph
    |> maybe_add(expression, RDF.type(), metadata_type(value(attrs, :kind)))
    |> maybe_add(expression, DCTERMS.title(), literal(value(attrs, :title)))
    |> maybe_add(expression, RDFS.label(), literal(value(attrs, :title)))
    |> maybe_add(
      expression,
      FABIO.hasPublicationYear(),
      literal(value(attrs, :year))
    )
    |> maybe_add(expression, FABIO.hasDOI(), literal(value(attrs, :doi)))
    |> maybe_add(
      expression,
      DCTERMS.identifier(),
      literal(value(attrs, :doi))
    )
    |> add_agents(expression, value(attrs, :authors), FOAF.Person)
    |> add_agents(
      expression,
      value(attrs, :corporate_authors),
      FOAF.Organization
    )
    |> add_venue(expression, value(attrs, :venue))
  end

  defp add_agents(graph, _expression, names, _type) when names in [nil, []],
    do: graph

  defp add_agents(graph, expression, names, type) do
    Enum.reduce(names, graph, fn name, graph ->
      agent = Sheaf.mint()

      graph
      |> Graph.add({agent, RDF.type(), type})
      |> Graph.add({agent, FOAF.name(), RDF.literal(name)})
      |> Graph.add({expression, DCTERMS.creator(), agent})
    end)
  end

  defp add_venue(graph, _expression, venue) when venue in [nil, ""], do: graph

  defp add_venue(graph, expression, venue) do
    resource = Sheaf.mint()

    graph
    |> Graph.add({resource, DCTERMS.title(), RDF.literal(venue)})
    |> Graph.add({resource, RDFS.label(), RDF.literal(venue)})
    |> Graph.add({expression, DCTERMS.isPartOf(), resource})
  end

  defp maybe_add(graph, _subject, _predicate, nil), do: graph

  defp maybe_add(graph, subject, predicate, object),
    do: Graph.add(graph, {subject, predicate, object})

  defp literal(nil), do: nil
  defp literal(""), do: nil
  defp literal(value), do: RDF.literal(to_string(value))

  defp metadata_type("journal_article"), do: FABIO.JournalArticle
  defp metadata_type("book_chapter"), do: FABIO.BookChapter
  defp metadata_type("book"), do: FABIO.Book
  defp metadata_type("report"), do: FABIO.ReportDocument
  defp metadata_type("research_paper"), do: FABIO.ResearchPaper
  defp metadata_type(_), do: nil

  defp supplied_fields(attrs) do
    [:kind, :title, :authors, :corporate_authors, :year, :venue, :doi]
    |> Enum.filter(&present_key?(attrs, &1))
  end

  defp present_key?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))

  defp value(attrs, key),
    do: Map.get(attrs, key, Map.get(attrs, to_string(key)))

  defp field_predicates(:kind), do: [RDF.type()]
  defp field_predicates(:title), do: [DCTERMS.title(), RDFS.label()]

  defp field_predicates(field) when field in [:authors, :corporate_authors],
    do: [DCTERMS.creator()]

  defp field_predicates(:year), do: [FABIO.hasPublicationYear()]
  defp field_predicates(:venue), do: [DCTERMS.isPartOf()]
  defp field_predicates(:doi), do: [FABIO.hasDOI(), DCTERMS.identifier()]
  defp field_predicates(_), do: @replaceable_predicates
end
