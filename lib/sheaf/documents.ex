defmodule Sheaf.Documents do
  use RDF

  @moduledoc """
  Lists document resources stored in the dataset.
  """

  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @query """
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX dcterms: <http://purl.org/dc/terms/>
  PREFIX fabio: <http://purl.org/spar/fabio/>
  PREFIX foaf: <http://xmlns.com/foaf/0.1/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?doc ?title ?kind ?metadataTitle ?metadataKind ?authorName ?year ?venueTitle ?publisherTitle ?doi ?volume ?issue ?pages ?pageCount WHERE {
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
          OPTIONAL { ?author foaf:name ?authorName }
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
      }
    }
  }
  """

  def list do
    with {:ok, result} <- Sheaf.select(@query) do
      {:ok, from_rows(result.results)}
    end
  end

  @doc false
  def from_rows(rows) do
    rows
    |> Enum.group_by(&row_iri/1)
    |> Enum.map(fn {_iri, rows} -> from_document_rows(rows) end)
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
      metadata: metadata,
      path: path(iri),
      title: metadata[:title] || title(row["title"], iri)
    }
  end

  defp row_iri(row), do: row |> Map.fetch!("doc") |> term_value()

  defp title(nil, iri), do: Id.id_from_iri(iri)
  defp title(term, _iri), do: term_value(term)

  defp metadata(rows) do
    metadata = %{
      authors: values(rows, "authorName"),
      doi: value(rows, "doi"),
      issue: value(rows, "issue"),
      kind: value(rows, "metadataKind") |> kind_name(),
      page_count: integer_value(rows, "pageCount"),
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

  defp path(iri) do
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
