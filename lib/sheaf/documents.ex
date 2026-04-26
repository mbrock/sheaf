defmodule Sheaf.Documents do
  use RDF

  @moduledoc """
  Lists document resources stored in the dataset.
  """

  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @query """
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX cito: <http://purl.org/spar/cito/>
  PREFIX dcterms: <http://purl.org/dc/terms/>
  PREFIX fabio: <http://purl.org/spar/fabio/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  PREFIX frbr: <http://purl.org/vocab/frbr/core#>
  PREFIX bibo: <http://purl.org/ontology/bibo/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?doc ?title ?kind ?metadataTitle ?metadataKind ?authorName ?year ?venueTitle ?publisherTitle ?doi ?volume ?issue ?pages ?pageCount ?metadataPageCount ?excluded ?cited ?metadataOnly WHERE {
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
        }
        BIND(COALESCE(?resourceTitle, ?workTitle, ?metadataTitle) AS ?title)
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

  SELECT ?block ?doc ?title ?kind ?metadataTitle ?metadataKind ?authorName ?year ?venueTitle ?publisherTitle ?doi ?volume ?issue ?pages ?pageCount ?metadataPageCount ?cited ?metadataOnly WHERE {
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
        }
        BIND(COALESCE(?resourceTitle, ?workTitle, ?metadataTitle) AS ?title)
      }
    }
  }
  """

  def list(opts \\ []) do
    with {:ok, result} <- Sheaf.select(@query) do
      {:ok, from_rows(result.results, opts)}
    end
  end

  def references_for_document(document_iri) do
    document_iri = RDF.iri(document_iri)
    query = String.replace(@reference_query, "__DOCUMENT_IRI__", to_string(document_iri))

    with {:ok, result} <- Sheaf.select(query) do
      {:ok, references_from_rows(result.results)}
    end
  end

  @doc false
  def from_rows(rows, opts \\ []) do
    rows
    |> Enum.group_by(&row_iri/1)
    |> Enum.map(fn {_iri, rows} -> from_document_rows(rows) end)
    |> maybe_reject_excluded(opts)
    |> Enum.sort_by(&{kind_order(&1.kind), String.downcase(&1.title)})
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
