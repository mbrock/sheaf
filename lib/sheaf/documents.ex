defmodule Sheaf.Documents do
  use RDF

  @moduledoc """
  Lists document resources stored in the dataset.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias Sheaf.Id
  alias Sheaf.NS.{BIBO, CITO, DCTERMS, FABIO, FOAF, FRBR, DOC}
  alias RDF.{Description, Graph, Literal}
  alias RDF.NS.RDFS

  @query """
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX cito: <http://purl.org/spar/cito/>
  PREFIX dcterms: <http://purl.org/dc/terms/>
  PREFIX fabio: <http://purl.org/spar/fabio/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  PREFIX frbr: <http://purl.org/vocab/frbr/core#>
  PREFIX bibo: <http://purl.org/ontology/bibo/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?doc ?title ?kind ?metadataTitle ?metadataKind ?authorName ?year ?venueTitle ?publisherTitle ?doi ?volume ?issue ?pages ?pageCount ?metadataPageCount ?status ?statusLabel ?excluded ?workspaceOwnerAuthored ?workspaceOwnerName ?cited ?metadataOnly WHERE {
    {
      GRAPH ?graph {
        {
          ?doc a ?kind .
          FILTER(?kind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
        } UNION {
          ?doc a sheaf:Document .
          FILTER NOT EXISTS {
            ?doc a ?specificKind .
            FILTER(?specificKind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
          }
          BIND(sheaf:Document AS ?kind)
        }
        OPTIONAL { ?doc rdfs:label ?title }
      }
      OPTIONAL {
        SELECT ?doc ((MAX(?sp) - MIN(?sp) + 1) AS ?pageCount) WHERE {
          GRAPH ?doc { ?node sheaf:sourcePage ?sp }
        }
        GROUP BY ?doc
      }
      OPTIONAL {
        GRAPH <https://less.rest/sheaf/metadata> {
          ?doc fabio:isRepresentationOf ?expression .

          OPTIONAL { ?expression dcterms:title ?metadataTitle }
          OPTIONAL { ?expression a ?metadataKind }
          OPTIONAL {
            ?expression dcterms:creator ?author .
            OPTIONAL { ?author foaf:name ?authorResourceName }
            BIND(
              IF(
                isLiteral(?author),
                STR(?author),
                IF(BOUND(?authorResourceName), STR(?authorResourceName), "")
              ) AS ?authorName
            )
            FILTER(?authorName != "")
          }
          OPTIONAL { ?expression fabio:hasPublicationYear ?year }
          OPTIONAL {
            ?expression dcterms:isPartOf ?venue .
            OPTIONAL { ?venue dcterms:title ?venueTitle }
          }
          OPTIONAL {
            ?expression dcterms:publisher ?publisher .
            OPTIONAL { ?publisher dcterms:title ?publisherResourceTitle }
            BIND(
              IF(
                BOUND(?publisherResourceTitle),
                STR(?publisherResourceTitle),
                IF(isLiteral(?publisher), STR(?publisher), "")
              ) AS ?publisherTitle
            )
            FILTER(?publisherTitle != "")
          }
          OPTIONAL { ?expression fabio:hasDOI ?doi }
          OPTIONAL { ?expression fabio:hasVolumeIdentifier ?volume }
          OPTIONAL { ?expression fabio:hasIssueIdentifier ?issue }
          OPTIONAL { ?expression fabio:hasPageRange ?pages }
          OPTIONAL { ?expression bibo:numPages ?metadataPageCount }
          OPTIONAL {
            ?expression bibo:status ?status .
            OPTIONAL { ?status rdfs:label ?statusLabel }
          }
        }
      }
      OPTIONAL {
        GRAPH <https://less.rest/sheaf/workspace> {
          ?workspace a sheaf:Workspace ;
            sheaf:excludesDocument ?doc .
          BIND("true" AS ?excluded)
        }
      }
      OPTIONAL {
        GRAPH <https://less.rest/sheaf/workspace> {
          ?workspace a sheaf:Workspace ;
            sheaf:hasWorkspaceOwner ?workspaceOwner .
        }
        GRAPH <https://less.rest/sheaf/metadata> {
          ?doc fabio:isRepresentationOf ?workspaceOwnerWork .
          ?workspaceOwnerWork dcterms:creator ?workspaceOwner .
          OPTIONAL { ?workspaceOwner foaf:name ?workspaceOwnerName }
        }
        BIND("true" AS ?workspaceOwnerAuthored)
      }
      OPTIONAL {
        GRAPH ?citationGraph {
          ?thesis a sheaf:Thesis ;
            cito:cites ?doc .
          BIND("true" AS ?cited)
        }
      }
    } UNION {
      GRAPH ?citationGraph {
        ?thesis a sheaf:Thesis ;
          cito:cites ?doc .
        BIND("true" AS ?cited)
        BIND("true" AS ?metadataOnly)
        BIND(fabio:ScholarlyWork AS ?kind)
      }
      FILTER NOT EXISTS { GRAPH ?documentGraph { ?doc a sheaf:Document } }
      GRAPH <https://less.rest/sheaf/metadata> {
        OPTIONAL { ?doc rdfs:label ?resourceTitle }
        OPTIONAL { ?doc dcterms:title ?workTitle }
        OPTIONAL {
          ?expression frbr:realizationOf ?doc .
          OPTIONAL { ?expression dcterms:title ?metadataTitle }
          OPTIONAL { ?expression a ?metadataKind }
          OPTIONAL {
            ?expression dcterms:creator ?author .
            OPTIONAL { ?author foaf:name ?authorResourceName }
            BIND(
              IF(
                isLiteral(?author),
                STR(?author),
                IF(BOUND(?authorResourceName), STR(?authorResourceName), "")
              ) AS ?authorName
            )
            FILTER(?authorName != "")
          }
          OPTIONAL { ?expression fabio:hasPublicationYear ?year }
          OPTIONAL {
            ?expression dcterms:isPartOf ?venue .
            OPTIONAL { ?venue dcterms:title ?venueTitle }
          }
          OPTIONAL {
            ?expression dcterms:publisher ?publisher .
            OPTIONAL { ?publisher dcterms:title ?publisherResourceTitle }
            BIND(
              IF(
                BOUND(?publisherResourceTitle),
                STR(?publisherResourceTitle),
                IF(isLiteral(?publisher), STR(?publisher), "")
              ) AS ?publisherTitle
            )
            FILTER(?publisherTitle != "")
          }
          OPTIONAL { ?expression fabio:hasDOI ?doi }
          OPTIONAL { ?expression fabio:hasVolumeIdentifier ?volume }
          OPTIONAL { ?expression fabio:hasIssueIdentifier ?issue }
          OPTIONAL { ?expression fabio:hasPageRange ?pages }
          OPTIONAL { ?expression bibo:numPages ?metadataPageCount }
          OPTIONAL {
            ?expression bibo:status ?expressionStatus .
            OPTIONAL { ?expressionStatus rdfs:label ?expressionStatusLabel }
          }
        }
        OPTIONAL {
          ?doc bibo:status ?workStatus .
          OPTIONAL { ?workStatus rdfs:label ?workStatusLabel }
        }
        BIND(COALESCE(?expressionStatus, ?workStatus) AS ?status)
        BIND(COALESCE(?expressionStatusLabel, ?workStatusLabel) AS ?statusLabel)
        BIND(COALESCE(?resourceTitle, ?workTitle, ?metadataTitle) AS ?title)
      }
      OPTIONAL {
        GRAPH <https://less.rest/sheaf/workspace> {
          ?workspace a sheaf:Workspace ;
            sheaf:hasWorkspaceOwner ?workspaceOwner .
        }
        GRAPH <https://less.rest/sheaf/metadata> {
          ?doc dcterms:creator ?workspaceOwner .
          OPTIONAL { ?workspaceOwner foaf:name ?workspaceOwnerName }
        }
        BIND("true" AS ?workspaceOwnerAuthored)
      }
    }
  }
  """

  @reference_query """
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX biro: <http://purl.org/spar/biro/>
  PREFIX cito: <http://purl.org/spar/cito/>
  PREFIX dcterms: <http://purl.org/dc/terms/>
  PREFIX fabio: <http://purl.org/spar/fabio/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  PREFIX frbr: <http://purl.org/vocab/frbr/core#>
  PREFIX bibo: <http://purl.org/ontology/bibo/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?block ?doc ?title ?kind ?metadataTitle ?metadataKind ?authorName ?year ?venueTitle ?publisherTitle ?doi ?volume ?issue ?pages ?pageCount ?metadataPageCount ?status ?statusLabel ?cited ?metadataOnly WHERE {
    GRAPH <__DOCUMENT_IRI__> {
      ?block biro:references ?doc .
      BIND("true" AS ?cited)
    }

    {
      GRAPH ?doc {
        {
          ?doc a ?kind .
          FILTER(?kind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
        } UNION {
          ?doc a sheaf:Document .
          FILTER NOT EXISTS {
            ?doc a ?specificKind .
            FILTER(?specificKind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript, sheaf:Spreadsheet))
          }
          BIND(sheaf:Document AS ?kind)
        }
        OPTIONAL { ?doc rdfs:label ?title }
      }
      OPTIONAL {
        SELECT ?doc ((MAX(?sp) - MIN(?sp) + 1) AS ?pageCount) WHERE {
          GRAPH ?doc { ?node sheaf:sourcePage ?sp }
        }
        GROUP BY ?doc
      }
      OPTIONAL {
        GRAPH <https://less.rest/sheaf/metadata> {
          ?doc fabio:isRepresentationOf ?expression .

          OPTIONAL { ?expression dcterms:title ?metadataTitle }
          OPTIONAL { ?expression a ?metadataKind }
          OPTIONAL {
            ?expression dcterms:creator ?author .
            OPTIONAL { ?author foaf:name ?authorResourceName }
            BIND(
              IF(
                isLiteral(?author),
                STR(?author),
                IF(BOUND(?authorResourceName), STR(?authorResourceName), "")
              ) AS ?authorName
            )
            FILTER(?authorName != "")
          }
          OPTIONAL { ?expression fabio:hasPublicationYear ?year }
          OPTIONAL {
            ?expression dcterms:isPartOf ?venue .
            OPTIONAL { ?venue dcterms:title ?venueTitle }
          }
          OPTIONAL {
            ?expression dcterms:publisher ?publisher .
            OPTIONAL { ?publisher dcterms:title ?publisherResourceTitle }
            BIND(
              IF(
                BOUND(?publisherResourceTitle),
                STR(?publisherResourceTitle),
                IF(isLiteral(?publisher), STR(?publisher), "")
              ) AS ?publisherTitle
            )
            FILTER(?publisherTitle != "")
          }
          OPTIONAL { ?expression fabio:hasDOI ?doi }
          OPTIONAL { ?expression fabio:hasVolumeIdentifier ?volume }
          OPTIONAL { ?expression fabio:hasIssueIdentifier ?issue }
          OPTIONAL { ?expression fabio:hasPageRange ?pages }
          OPTIONAL { ?expression bibo:numPages ?metadataPageCount }
          OPTIONAL {
            ?expression bibo:status ?status .
            OPTIONAL { ?status rdfs:label ?statusLabel }
          }
        }
      }
    } UNION {
      FILTER NOT EXISTS { GRAPH ?documentGraph { ?doc a sheaf:Document } }
      BIND("true" AS ?metadataOnly)
      BIND(fabio:ScholarlyWork AS ?kind)
      GRAPH <https://less.rest/sheaf/metadata> {
        OPTIONAL { ?doc rdfs:label ?resourceTitle }
        OPTIONAL { ?doc dcterms:title ?workTitle }
        OPTIONAL {
          ?expression frbr:realizationOf ?doc .
          OPTIONAL { ?expression dcterms:title ?metadataTitle }
          OPTIONAL { ?expression a ?metadataKind }
          OPTIONAL {
            ?expression dcterms:creator ?author .
            OPTIONAL { ?author foaf:name ?authorResourceName }
            BIND(
              IF(
                isLiteral(?author),
                STR(?author),
                IF(BOUND(?authorResourceName), STR(?authorResourceName), "")
              ) AS ?authorName
            )
            FILTER(?authorName != "")
          }
          OPTIONAL { ?expression fabio:hasPublicationYear ?year }
          OPTIONAL {
            ?expression dcterms:isPartOf ?venue .
            OPTIONAL { ?venue dcterms:title ?venueTitle }
          }
          OPTIONAL {
            ?expression dcterms:publisher ?publisher .
            OPTIONAL { ?publisher dcterms:title ?publisherResourceTitle }
            BIND(
              IF(
                BOUND(?publisherResourceTitle),
                STR(?publisherResourceTitle),
                IF(isLiteral(?publisher), STR(?publisher), "")
              ) AS ?publisherTitle
            )
            FILTER(?publisherTitle != "")
          }
          OPTIONAL { ?expression fabio:hasDOI ?doi }
          OPTIONAL { ?expression fabio:hasVolumeIdentifier ?volume }
          OPTIONAL { ?expression fabio:hasIssueIdentifier ?issue }
          OPTIONAL { ?expression fabio:hasPageRange ?pages }
          OPTIONAL { ?expression bibo:numPages ?metadataPageCount }
          OPTIONAL {
            ?expression bibo:status ?expressionStatus .
            OPTIONAL { ?expressionStatus rdfs:label ?expressionStatusLabel }
          }
        }
        OPTIONAL {
          ?doc bibo:status ?workStatus .
          OPTIONAL { ?workStatus rdfs:label ?workStatusLabel }
        }
        BIND(COALESCE(?expressionStatus, ?workStatus) AS ?status)
        BIND(COALESCE(?expressionStatusLabel, ?workStatusLabel) AS ?statusLabel)
        BIND(COALESCE(?resourceTitle, ?workTitle, ?metadataTitle) AS ?title)
      }
    }
  }
  """

  @doc false
  def legacy_document_index_sparql, do: @query

  def list(opts \\ []) do
    Tracer.with_span "Sheaf.Documents.list", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"sheaf.include_excluded", Keyword.get(opts, :include_excluded, true)}
      ]
    } do
      with :ok <- load_document_index_cache() do
        documents = Sheaf.Repo.ask(&from_dataset(&1, opts))
        Tracer.set_attribute("sheaf.document_count", length(documents))
        {:ok, documents}
      end
    end
  end

  def references_for_document(document_iri) do
    document_iri = RDF.iri(document_iri)
    query = String.replace(@reference_query, "__DOCUMENT_IRI__", to_string(document_iri))

    with {:ok, result} <- Sheaf.select("document references select", query) do
      {:ok, references_from_rows(result.results)}
    end
  end

  @doc false
  def from_rows(rows, opts \\ []) do
    Tracer.with_span "Sheaf.Documents.from_rows", %{
      kind: :internal,
      attributes: [{"sheaf.row_count", length(rows)}]
    } do
      grouped =
        Tracer.with_span "Sheaf.Documents.from_rows.group", %{kind: :internal} do
          grouped = Enum.group_by(rows, &row_iri/1)
          Tracer.set_attribute("sheaf.document_group_count", map_size(grouped))
          grouped
        end

      documents =
        Tracer.with_span "Sheaf.Documents.from_rows.build", %{kind: :internal} do
          documents = Enum.map(grouped, fn {_iri, rows} -> from_document_rows(rows) end)
          Tracer.set_attribute("sheaf.document_count", length(documents))
          documents
        end

      documents =
        Tracer.with_span "Sheaf.Documents.from_rows.filter_sort", %{kind: :internal} do
          documents =
            documents
            |> maybe_reject_excluded(opts)
            |> Enum.sort_by(&document_sort_key/1)

          Tracer.set_attribute("sheaf.document_count", length(documents))
          documents
        end

      documents
    end
  end

  @doc false
  def from_dataset(dataset, opts \\ []) do
    Tracer.with_span "Sheaf.Documents.from_dataset", %{
      kind: :internal,
      attributes: [{"sheaf.statement_count", RDF.Data.statement_count(dataset)}]
    } do
      rows = dataset_rows(dataset)
      Tracer.set_attribute("sheaf.row_count", length(rows))
      from_rows(rows, opts)
    end
  end

  defp load_document_index_cache do
    patterns =
      [
        {nil, nil, nil, RDF.iri(Sheaf.Repo.workspace_graph())},
        {nil, nil, nil, RDF.iri(Sheaf.Repo.metadata_graph())},
        {nil, RDF.type(), RDF.iri(DOC.Document), nil},
        {nil, RDF.type(), RDF.iri(DOC.Paper), nil},
        {nil, RDF.type(), RDF.iri(DOC.Thesis), nil},
        {nil, RDF.type(), RDF.iri(DOC.Transcript), nil},
        {nil, RDF.type(), RDF.iri(DOC.Spreadsheet), nil},
        {nil, RDFS.label(), nil, nil},
        {nil, DOC.sourcePage(), nil, nil},
        {nil, CITO.cites(), nil, nil}
      ]

    Enum.reduce_while(patterns, :ok, fn pattern, :ok ->
      case Sheaf.Repo.load_once(pattern) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp dataset_rows(dataset) do
    Tracer.with_span "Sheaf.Documents.dataset_rows", %{
      kind: :internal,
      attributes: [
        {"sheaf.statement_count", RDF.Data.statement_count(dataset)},
        {"sheaf.graph_count", RDF.Dataset.graph_count(dataset)}
      ]
    } do
      {metadata, workspace} =
        Tracer.with_span "Sheaf.Documents.dataset_rows.index_graphs", %{kind: :internal} do
          metadata = dataset |> RDF.Dataset.graph(Sheaf.Repo.metadata_graph()) |> graph_index()
          workspace = dataset |> RDF.Dataset.graph(Sheaf.Repo.workspace_graph()) |> graph_index()

          Tracer.set_attribute("sheaf.metadata_statement_count", metadata.statement_count)
          Tracer.set_attribute("sheaf.workspace_statement_count", workspace.statement_count)

          {metadata, workspace}
        end

      descriptions = document_descriptions(dataset)
      document_iris = descriptions |> Enum.map(fn {doc, _description} -> doc end) |> MapSet.new()
      cited_docs = cited_documents(dataset)

      document_rows =
        Tracer.with_span "Sheaf.Documents.dataset_rows.document_rows", %{kind: :internal} do
          rows =
            descriptions
            |> Enum.flat_map(fn {doc, description} ->
              rows_for_document(dataset, metadata, workspace, cited_docs, doc, description)
            end)

          Tracer.set_attribute("sheaf.document_description_count", length(descriptions))
          Tracer.set_attribute("sheaf.row_count", length(rows))
          rows
        end

      metadata_only_rows =
        Tracer.with_span "Sheaf.Documents.dataset_rows.metadata_only_rows", %{kind: :internal} do
          rows =
            cited_docs
            |> Enum.reject(&MapSet.member?(document_iris, &1))
            |> Enum.flat_map(&rows_for_metadata_only_document(metadata, workspace, &1))

          Tracer.set_attribute("sheaf.cited_document_count", MapSet.size(cited_docs))
          Tracer.set_attribute("sheaf.row_count", length(rows))
          rows
        end

      rows = document_rows ++ metadata_only_rows
      Tracer.set_attribute("sheaf.row_count", length(rows))
      rows
    end
  end

  defp document_descriptions(dataset) do
    Tracer.with_span "Sheaf.Documents.document_descriptions", %{kind: :internal} do
      descriptions =
        dataset
        |> RDF.Dataset.graphs()
        |> Enum.flat_map(fn graph ->
          graph
          |> Graph.descriptions()
          |> Enum.filter(&document_description?/1)
          |> Enum.map(&{Description.subject(&1), &1})
        end)

      Tracer.set_attribute("sheaf.document_description_count", length(descriptions))
      descriptions
    end
  end

  defp document_description?(description) do
    Enum.any?(document_kinds(), &Description.include?(description, {RDF.type(), &1}))
  end

  defp rows_for_document(dataset, metadata, workspace, cited_docs, doc, description) do
    kinds = document_row_kinds(description)
    page_count = page_count(dataset, doc)
    metadata_values = document_metadata(metadata, doc)
    workspace_owner = workspace_owner(workspace)

    workspace_owner_authored? =
      workspace_owner_authored?(metadata, doc, workspace_owner, :document)

    kinds
    |> Enum.flat_map(fn kind ->
      row =
        %{"doc" => doc, "kind" => kind}
        |> put_optional("title", Description.first(description, RDFS.label()))
        |> put_optional("pageCount", literal_integer(page_count))
        |> put_flag("excluded", excluded?(workspace, doc))
        |> put_flag("cited", MapSet.member?(cited_docs, doc))
        |> put_flag("workspaceOwnerAuthored", workspace_owner_authored?)
        |> put_optional("workspaceOwnerName", resource_name(metadata, workspace_owner))
        |> Map.merge(metadata_values)

      expand_author_rows(row, metadata_values)
    end)
  end

  defp rows_for_metadata_only_document(metadata, workspace, doc) do
    workspace_owner = workspace_owner(workspace)

    workspace_owner_authored? =
      workspace_owner_authored?(metadata, doc, workspace_owner, :metadata_only)

    metadata_values = metadata_only_document_metadata(metadata, doc)

    row =
      %{"doc" => doc, "kind" => RDF.iri(FABIO.ScholarlyWork)}
      |> put_optional("title", metadata_only_title(metadata, doc, metadata_values))
      |> put_flag("cited", true)
      |> put_flag("metadataOnly", true)
      |> put_flag("workspaceOwnerAuthored", workspace_owner_authored?)
      |> put_optional("workspaceOwnerName", resource_name(metadata, workspace_owner))
      |> Map.merge(metadata_values)

    expand_author_rows(row, metadata_values)
  end

  defp document_row_kinds(description) do
    specific =
      Enum.filter(specific_document_kinds(), &Description.include?(description, {RDF.type(), &1}))

    cond do
      specific != [] ->
        specific

      Description.include?(description, {RDF.type(), RDF.iri(DOC.Document)}) ->
        [RDF.iri(DOC.Document)]

      true ->
        []
    end
  end

  defp document_metadata(metadata, doc) do
    case first_object(metadata, doc, FABIO.isRepresentationOf()) do
      nil -> %{}
      expression -> expression_metadata(metadata, expression)
    end
  end

  defp metadata_only_document_metadata(metadata, doc) do
    expression =
      metadata
      |> subjects_with(FRBR.realizationOf(), doc)
      |> List.first()

    expression_values = if expression, do: expression_metadata(metadata, expression), else: %{}
    status = first_object(metadata, doc, bibo_status())
    status_label = if status, do: first_object(metadata, status, RDFS.label())

    expression_values
    |> put_optional("status", expression_values["status"] || status)
    |> put_optional("statusLabel", expression_values["statusLabel"] || status_label)
  end

  defp expression_metadata(metadata, expression) do
    venue = first_object(metadata, expression, DCTERMS.isPartOf())
    publisher = first_object(metadata, expression, DCTERMS.publisher())
    status = first_object(metadata, expression, bibo_status())

    %{}
    |> put_optional("metadataTitle", first_object(metadata, expression, DCTERMS.title()))
    |> put_optional("metadataKind", first_object(metadata, expression, RDF.type()))
    |> put_optional("year", first_object(metadata, expression, FABIO.hasPublicationYear()))
    |> put_optional("venueTitle", first_object(metadata, venue, DCTERMS.title()))
    |> put_optional("publisherTitle", publisher_title(metadata, publisher))
    |> put_optional("doi", first_object(metadata, expression, FABIO.hasDOI()))
    |> put_optional("volume", first_object(metadata, expression, FABIO.hasVolumeIdentifier()))
    |> put_optional("issue", first_object(metadata, expression, FABIO.hasIssueIdentifier()))
    |> put_optional("pages", first_object(metadata, expression, FABIO.hasPageRange()))
    |> put_optional("metadataPageCount", first_object(metadata, expression, BIBO.numPages()))
    |> put_optional("status", status)
    |> put_optional("statusLabel", first_object(metadata, status, RDFS.label()))
    |> Map.put(:author_names, author_names(metadata, expression))
  end

  defp metadata_only_title(metadata, doc, metadata_values) do
    first_object(metadata, doc, RDFS.label()) ||
      first_object(metadata, doc, DCTERMS.title()) ||
      metadata_values["metadataTitle"]
  end

  defp expand_author_rows(row, %{author_names: []}), do: [Map.delete(row, :author_names)]

  defp expand_author_rows(row, %{author_names: author_names}) do
    row = Map.delete(row, :author_names)
    Enum.map(author_names, &Map.put(row, "authorName", RDF.literal(&1)))
  end

  defp expand_author_rows(row, _metadata_values), do: [row]

  defp author_names(metadata, expression) do
    metadata
    |> objects_for(expression, DCTERMS.creator())
    |> Enum.flat_map(fn
      %Literal{} = literal -> [Literal.lexical(literal)]
      resource -> resource_name(metadata, resource) |> List.wrap()
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp publisher_title(_metadata, nil), do: nil
  defp publisher_title(_metadata, %Literal{} = literal), do: literal

  defp publisher_title(metadata, publisher),
    do: first_object(metadata, publisher, DCTERMS.title())

  defp resource_name(_metadata, nil), do: nil
  defp resource_name(metadata, resource), do: first_object(metadata, resource, FOAF.name())

  defp workspace_owner(workspace) do
    workspace
    |> subjects_with(RDF.type(), RDF.iri(DOC.Workspace))
    |> Enum.find_value(&first_object(workspace, &1, DOC.hasWorkspaceOwner()))
  end

  defp workspace_owner_authored?(_metadata, _doc, nil, _mode), do: false

  defp workspace_owner_authored?(metadata, doc, owner, :document) do
    metadata
    |> objects_for(doc, FABIO.isRepresentationOf())
    |> Enum.any?(&(owner in objects_for(metadata, &1, DCTERMS.creator())))
  end

  defp workspace_owner_authored?(metadata, doc, owner, :metadata_only) do
    owner in objects_for(metadata, doc, DCTERMS.creator())
  end

  defp excluded?(workspace, doc) do
    workspace
    |> subjects_with(RDF.type(), RDF.iri(DOC.Workspace))
    |> Enum.any?(&(doc in objects_for(workspace, &1, DOC.excludesDocument())))
  end

  defp cited_documents(dataset) do
    Tracer.with_span "Sheaf.Documents.cited_documents", %{kind: :internal} do
      cited_documents =
        dataset
        |> RDF.Dataset.graphs()
        |> Enum.flat_map(fn graph ->
          theses =
            graph
            |> Graph.descriptions()
            |> Enum.filter(&Description.include?(&1, {RDF.type(), RDF.iri(DOC.Thesis)}))
            |> Enum.map(&Description.subject/1)
            |> MapSet.new()

          graph
          |> Graph.triples()
          |> Enum.flat_map(fn
            {thesis, predicate, doc} ->
              if MapSet.member?(theses, thesis) and predicate == CITO.cites(), do: [doc], else: []

            _triple ->
              []
          end)
        end)
        |> MapSet.new()

      Tracer.set_attribute("sheaf.cited_document_count", MapSet.size(cited_documents))
      cited_documents
    end
  end

  defp page_count(dataset, doc) do
    case RDF.Dataset.graph(dataset, doc) do
      nil ->
        nil

      graph ->
        pages =
          graph
          |> Graph.triples()
          |> Enum.flat_map(fn
            {_subject, predicate, object} ->
              if predicate == DOC.sourcePage() do
                object
                |> term_value()
                |> Integer.parse()
                |> case do
                  {page, _rest} -> [page]
                  :error -> []
                end
              else
                []
              end

            _triple ->
              []
          end)

        case pages do
          [] -> nil
          pages -> Enum.max(pages) - Enum.min(pages) + 1
        end
    end
  end

  defp first_object(nil, _subject, _predicate), do: nil
  defp first_object(_graph, nil, _predicate), do: nil

  defp first_object(graph, subject, predicate),
    do: graph |> objects_for(subject, predicate) |> List.first()

  defp objects_for(nil, _subject, _predicate), do: []

  defp objects_for(%{by_sp: by_sp}, subject, predicate),
    do: Map.get(by_sp, {subject, predicate}, [])

  defp objects_for(graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {^subject, ^predicate, object} -> [object]
      _triple -> []
    end)
  end

  defp subjects_with(nil, _predicate, _object), do: []

  defp subjects_with(%{by_po: by_po}, predicate, object),
    do: Map.get(by_po, {predicate, object}, [])

  defp subjects_with(graph, predicate, object) do
    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {subject, ^predicate, ^object} -> [subject]
      _triple -> []
    end)
  end

  defp graph_index(nil), do: %{by_sp: %{}, by_po: %{}, statement_count: 0}

  defp graph_index(graph) do
    Enum.reduce(Graph.triples(graph), %{by_sp: %{}, by_po: %{}, statement_count: 0}, fn {subject,
                                                                                         predicate,
                                                                                         object},
                                                                                        index ->
      index
      |> Map.update!(:statement_count, &(&1 + 1))
      |> Map.update!(
        :by_sp,
        &Map.update(&1, {subject, predicate}, [object], fn objects -> [object | objects] end)
      )
      |> Map.update!(
        :by_po,
        &Map.update(&1, {predicate, object}, [subject], fn subjects -> [subject | subjects] end)
      )
    end)
  end

  defp put_flag(row, _key, false), do: row
  defp put_flag(row, key, true), do: Map.put(row, key, RDF.literal("true"))

  defp put_optional(row, _key, nil), do: row
  defp put_optional(row, key, value), do: Map.put(row, key, value)

  defp literal_integer(nil), do: nil
  defp literal_integer(integer), do: RDF.literal(integer)

  defp document_kinds, do: [RDF.iri(DOC.Document) | specific_document_kinds()]

  defp specific_document_kinds do
    [RDF.iri(DOC.Paper), RDF.iri(DOC.Thesis), RDF.iri(DOC.Transcript), RDF.iri(DOC.Spreadsheet)]
  end

  defp bibo_status, do: RDF.iri("http://purl.org/ontology/bibo/status")

  defp document_sort_key(document) do
    {if(document.workspace_owner_authored?, do: 0, else: 1), kind_order(document.kind),
     String.downcase(document.title)}
  end

  defp from_document_rows(rows) do
    row = Enum.min_by(rows, &(kind(&1["kind"]) |> kind_order()))
    iri = row_iri(row)
    kind = kind(row["kind"])
    metadata = metadata(rows)

    %{
      id: Id.id_from_iri(iri),
      iri: iri,
      kind: kind,
      cited?: cited?(rows),
      excluded?: excluded?(rows),
      has_document?: not metadata_only?(rows),
      metadata: metadata,
      path: path(iri, metadata_only?(rows)),
      workspace_owner_authored?: workspace_owner_authored?(rows),
      workspace_owner_name: value(rows, "workspaceOwnerName"),
      title: metadata[:title] || title(row["title"], iri)
    }
  end

  defp references_from_rows(rows) do
    rows
    |> Enum.group_by(&block_id/1)
    |> Map.new(fn {block_id, rows} -> {block_id, from_rows(rows)} end)
  end

  defp block_id(row), do: row |> Map.fetch!("block") |> term_value() |> Id.id_from_iri()

  defp row_iri(row), do: row |> Map.fetch!("doc") |> term_value()

  defp maybe_reject_excluded(documents, opts) do
    if Keyword.get(opts, :include_excluded, true) do
      documents
    else
      Enum.reject(documents, & &1.excluded?)
    end
  end

  defp excluded?(rows), do: Enum.any?(rows, &Map.has_key?(&1, "excluded"))

  defp workspace_owner_authored?(rows),
    do: Enum.any?(rows, &Map.has_key?(&1, "workspaceOwnerAuthored"))

  defp cited?(rows), do: Enum.any?(rows, &Map.has_key?(&1, "cited"))
  defp metadata_only?(rows), do: Enum.any?(rows, &Map.has_key?(&1, "metadataOnly"))

  defp title(nil, iri), do: Id.id_from_iri(iri)
  defp title(term, _iri), do: term_value(term)

  defp metadata(rows) do
    metadata = %{
      authors: values(rows, "authorName"),
      doi: value(rows, "doi"),
      issue: value(rows, "issue"),
      kind: value(rows, "metadataKind") |> kind_name(),
      page_count: integer_value(rows, "pageCount") || integer_value(rows, "metadataPageCount"),
      pages: value(rows, "pages"),
      publisher: value(rows, "publisherTitle"),
      status: status(rows),
      title: value(rows, "metadataTitle"),
      venue: value(rows, "venueTitle"),
      volume: value(rows, "volume"),
      year: value(rows, "year")
    }

    if empty_metadata?(metadata), do: %{}, else: metadata
  end

  defp empty_metadata?(metadata) do
    Enum.all?(metadata, fn
      {:authors, []} -> true
      {_key, nil} -> true
      {_key, _value} -> false
    end)
  end

  defp integer_value(rows, key) do
    case value(rows, key) do
      nil ->
        nil

      string ->
        case Integer.parse(string) do
          {int, _} -> int
          :error -> nil
        end
    end
  end

  defp values(rows, key) do
    rows
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&term_value/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp value(rows, key) do
    rows
    |> Enum.find_value(fn row ->
      case Map.get(row, key) do
        nil -> nil
        term -> term_value(term)
      end
    end)
  end

  defp status(rows) do
    case value(rows, "statusLabel") || value(rows, "status") do
      nil ->
        nil

      status ->
        status
        |> String.split(["#", "/"])
        |> List.last()
        |> String.replace("-", " ")
        |> String.downcase()
    end
  end

  defp kind_name(nil), do: nil

  defp kind_name(iri) do
    iri
    |> String.split(["#", "/"])
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp kind(nil), do: :document
  defp kind(term_to_iri(DOC.Paper)), do: :paper
  defp kind(term_to_iri(DOC.Thesis)), do: :thesis
  defp kind(term_to_iri(DOC.Transcript)), do: :transcript
  defp kind(term_to_iri(DOC.Spreadsheet)), do: :spreadsheet
  defp kind(_term), do: :document

  defp path(_iri, true), do: nil

  defp path(iri, false) do
    base = Id.base_iri()
    id = Id.id_from_iri(iri)

    if iri == base <> id do
      "/" <> id
    end
  end

  defp kind_order(:thesis), do: 0
  defp kind_order(:paper), do: 1
  defp kind_order(:transcript), do: 2
  defp kind_order(:spreadsheet), do: 3
  defp kind_order(:document), do: 4

  defp term_value(term), do: term |> RDF.Term.value() |> to_string()
end
