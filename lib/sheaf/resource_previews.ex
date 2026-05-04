defmodule Sheaf.ResourcePreviews do
  @moduledoc """
  Small on-demand previews for assistant-rendered resource references.
  """

  alias RDF.{Description, Graph, Literal}
  alias Sheaf.{BlockPreviews, Document, Id, ResourceResolver}
  alias Sheaf.NS.{DCTERMS, FABIO, FOAF}

  require OpenTelemetry.Tracer, as: Tracer

  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Tracer.with_span "sheaf.resource_previews.get", %{kind: :internal} do
      id = String.trim(id)
      Tracer.set_attribute("sheaf.resource_id", id)

      case ResourceResolver.resolve(id) do
        {:ok, %{kind: :block}} -> BlockPreviews.get(id)
        {:ok, %{kind: :document}} -> document_preview(id)
        _other -> nil
      end
    end
  end

  def get(_id), do: nil

  defp document_preview(id) do
    with iri = Id.iri(id),
         {:ok, %Graph{} = graph} <- Sheaf.fetch_graph(iri) do
      metadata = document_metadata(graph, metadata_graph(), id)

      %{
        id: id,
        type: :document,
        text: nil,
        document_id: id,
        document_kind: graph |> Document.kind(iri) |> document_kind_label(),
        document_title: Document.title(graph, iri) || id,
        document_authors: document_authors(metadata),
        document_year: document_year(metadata),
        toc: graph |> Document.toc(iri) |> toc_preview(),
        path: "/#{id}"
      }
    else
      _other -> nil
    end
  end

  defp metadata_graph do
    case Sheaf.fetch_graph(Sheaf.Repo.metadata_graph()) do
      {:ok, %Graph{} = graph} -> graph
      {:error, _reason} -> Graph.new()
    end
  end

  defp document_metadata(%Graph{} = graph, %Graph{} = metadata, doc_id) do
    doc = Id.iri(doc_id)
    description = RDF.Data.description(graph, doc)
    expression = Description.first(description, FABIO.isRepresentationOf())
    expression = expression || first_object(metadata, doc, FABIO.isRepresentationOf())

    %{
      authors: author_names(metadata, expression),
      year: first_object(metadata, expression, FABIO.hasPublicationYear()) |> term_value()
    }
  end

  defp document_authors(%{authors: authors}) when is_list(authors), do: authors
  defp document_authors(_metadata), do: []

  defp document_year(%{year: year}) when not is_nil(year), do: to_string(year)
  defp document_year(_metadata), do: nil

  defp document_kind_label(:thesis), do: "Thesis"
  defp document_kind_label(:transcript), do: "Transcript"
  defp document_kind_label(:paper), do: "Paper"
  defp document_kind_label(:spreadsheet), do: "Spreadsheet"
  defp document_kind_label(_kind), do: "Document"

  defp toc_preview(entries) do
    entries
    |> flatten_toc()
    |> Enum.take(8)
  end

  defp flatten_toc(entries) do
    Enum.flat_map(entries, fn entry ->
      current = %{
        id: entry.id,
        number: Enum.join(entry.number, "."),
        title: entry.title
      }

      [current | flatten_toc(entry.children)]
    end)
  end

  defp author_names(_metadata, nil), do: []

  defp author_names(metadata, expression) do
    metadata
    |> objects_for(expression, DCTERMS.creator())
    |> Enum.flat_map(fn
      %Literal{} = literal -> [Literal.lexical(literal)]
      author -> first_object(metadata, author, FOAF.name()) |> List.wrap()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&term_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp first_object(_graph, nil, _predicate), do: nil

  defp first_object(graph, subject, predicate) do
    graph
    |> objects_for(subject, predicate)
    |> List.first()
  end

  defp objects_for(_graph, nil, _predicate), do: []

  defp objects_for(%Graph{} = graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {^subject, ^predicate, object} -> [object]
      _triple -> []
    end)
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()
end
