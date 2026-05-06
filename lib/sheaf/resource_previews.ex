defmodule Sheaf.ResourcePreviews do
  @moduledoc """
  Small on-demand previews for assistant-rendered resource references.
  """

  alias RDF.{Graph, Literal}
  alias Sheaf.{BlockPreviews, Document, Documents, Id, ResourceResolver}
  alias Sheaf.Assistant.Notes
  alias Sheaf.NS.BIBO

  require OpenTelemetry.Tracer, as: Tracer

  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Tracer.with_span "sheaf.resource_previews.get", %{kind: :internal} do
      id = String.trim(id)
      Tracer.set_attribute("sheaf.resource_id", id)

      case ResourceResolver.resolve(id) do
        {:ok, %{kind: :block}} -> block_preview(id)
        {:ok, %{kind: :document}} -> document_preview(id)
        {:ok, %{kind: :research_note}} -> note_preview(id)
        _other -> nil
      end
    end
  end

  def get(_id), do: nil

  defp block_preview(id) do
    case BlockPreviews.get(id) do
      %{document_id: doc_id} = preview ->
        Map.put(preview, :document, preview_document_entry(preview, doc_id))

      preview ->
        preview
    end
  end

  defp document_preview(id) do
    with iri = Id.iri(id),
         {:ok, %Graph{} = graph} <- Sheaf.fetch_graph(iri) do
      document = document_entry(id, graph, iri)

      %{
        id: id,
        type: :document,
        text: nil,
        document: document,
        document_id: id,
        document_title: document.title,
        document_authors: Map.get(document.metadata, :authors, []),
        document_year: Map.get(document.metadata, :year),
        toc: graph |> Document.toc(iri) |> toc_preview(2),
        path: "/#{id}"
      }
    else
      _other -> nil
    end
  end

  defp note_preview(id) do
    with {:ok, note, _graph} <- Notes.get(id) do
      title = note_value(note, RDF.NS.RDFS.label()) || "Research note"

      %{
        id: id,
        type: :research_note,
        text: note_value(note, Sheaf.NS.AS.content()),
        document: %{
          id: id,
          iri: to_string(note.subject),
          kind: :research_note,
          cited?: false,
          excluded?: false,
          has_document?: true,
          metadata: %{},
          path: "/#{id}",
          workspace_owner_authored?: false,
          workspace_owner_name: nil,
          title: title
        },
        document_id: id,
        document_title: title,
        document_authors: [],
        document_year: nil,
        toc: [],
        path: "/#{id}"
      }
    else
      _other -> nil
    end
  end

  defp document_entry(id, graph, iri) do
    with {:ok, documents} <- Documents.list(include_excluded: true),
         document when not is_nil(document) <- Enum.find(documents, &(&1.id == id)) do
      document
    else
      _other ->
        %{
          id: id,
          iri: to_string(iri),
          kind: Document.kind(graph, iri),
          cited?: false,
          excluded?: false,
          has_document?: true,
          metadata: fallback_metadata(graph, iri),
          path: "/#{id}",
          workspace_owner_authored?: false,
          workspace_owner_name: nil,
          title: Document.title(graph, iri) || id
        }
    end
  end

  defp fallback_metadata(graph, iri) do
    %{}
    |> put_optional(:page_count, page_count(graph, iri))
  end

  defp page_count(graph, iri) do
    graph
    |> Graph.description(iri)
    |> RDF.Description.get(BIBO.numPages(), [])
    |> List.first()
    |> literal_integer()
  end

  defp literal_integer(nil), do: nil

  defp literal_integer(%Literal{} = literal) do
    literal
    |> RDF.Literal.value()
    |> integer_value()
  end

  defp literal_integer(value), do: integer_value(value)

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp note_value(description, predicate) do
    description
    |> RDF.Description.first(predicate)
    |> case do
      nil -> nil
      term -> term |> RDF.Term.value() |> to_string()
    end
  end

  defp preview_document_entry(preview, id) do
    %{
      id: id,
      iri: to_string(Id.iri(id)),
      kind: :document,
      cited?: false,
      excluded?: false,
      has_document?: true,
      metadata: %{
        authors: Map.get(preview, :document_authors, []),
        status: Map.get(preview, :document_status),
        year: Map.get(preview, :document_year)
      },
      path: "/#{id}",
      workspace_owner_authored?: false,
      workspace_owner_name: nil,
      title: Map.get(preview, :document_title) || id
    }
  end

  defp toc_preview(entries, max_depth) do
    flatten_toc(entries, max_depth)
  end

  defp flatten_toc(_entries, max_depth) when max_depth <= 0, do: []

  defp flatten_toc(entries, max_depth) do
    Enum.flat_map(entries, fn entry ->
      current = %{
        id: entry.id,
        number: Enum.join(entry.number, "."),
        title: entry.title
      }

      [current | flatten_toc(entry.children, max_depth - 1)]
    end)
  end
end
