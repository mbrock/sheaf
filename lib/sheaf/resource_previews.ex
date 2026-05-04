defmodule Sheaf.ResourcePreviews do
  @moduledoc """
  Small on-demand previews for assistant-rendered resource references.
  """

  alias RDF.Graph
  alias Sheaf.{BlockPreviews, Document, Documents, Id, ResourceResolver}

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
          metadata: %{},
          path: "/#{id}",
          workspace_owner_authored?: false,
          workspace_owner_name: nil,
          title: Document.title(graph, iri) || id
        }
    end
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
