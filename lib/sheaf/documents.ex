defmodule Sheaf.Documents do
  use RDF

  @moduledoc """
  Lists document resources stored in the dataset.
  """

  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @query """
  PREFIX sheaf: <https://less.rest/sheaf/>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>

  SELECT ?doc ?title ?kind WHERE {
    GRAPH ?graph {
      ?doc a sheaf:Document .
      OPTIONAL { ?doc rdfs:label ?title }
      OPTIONAL {
        ?doc a ?kind .
        FILTER(?kind IN (sheaf:Paper, sheaf:Thesis, sheaf:Transcript))
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
    |> Enum.map(&from_row/1)
    |> Enum.uniq_by(& &1.iri)
    |> Enum.sort_by(&{kind_order(&1.kind), String.downcase(&1.title)})
  end

  defp from_row(row) do
    iri = row |> Map.fetch!("doc") |> term_value()
    kind = kind(row["kind"])

    %{
      id: Id.id_from_iri(iri),
      iri: iri,
      kind: kind,
      path: path(iri),
      title: title(row["title"], iri)
    }
  end

  defp title(nil, iri), do: Id.id_from_iri(iri)
  defp title(term, _iri), do: term_value(term)

  defp kind(nil), do: :document
  defp kind(term_to_iri(DOC.Paper)), do: :paper
  defp kind(term_to_iri(DOC.Thesis)), do: :thesis
  defp kind(term_to_iri(DOC.Transcript)), do: :transcript
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
  defp kind_order(:document), do: 3

  defp term_value(term), do: term |> RDF.Term.value() |> to_string()
end
