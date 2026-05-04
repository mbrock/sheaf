defmodule Sheaf.BlockPreviews do
  @moduledoc """
  Small previews for block references rendered in assistant Markdown.
  """

  alias Sheaf.{Corpus, Document, Documents, Id}

  require OpenTelemetry.Tracer, as: Tracer

  @spec for_ids([String.t()]) :: map()
  def for_ids(ids) when is_list(ids) do
    Tracer.with_span "sheaf.block_previews.for_ids", %{kind: :internal} do
      ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()
      Tracer.set_attribute("sheaf.block_count", length(ids))

      ids
      |> Enum.map(fn id -> {id, safe_find_document(id)} end)
      |> Enum.reject(fn {_id, doc_id} -> is_nil(doc_id) end)
      |> Enum.group_by(fn {_id, doc_id} -> doc_id end, fn {id, _doc_id} -> id end)
      |> previews_for_documents()
      |> Map.new()
    end
  end

  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Tracer.with_span "sheaf.block_previews.get", %{kind: :internal} do
      Tracer.set_attribute("sheaf.block_id", id)

      id
      |> List.wrap()
      |> for_ids()
      |> Map.get(id)
    end
  end

  defp previews_for_documents(grouped_ids) when map_size(grouped_ids) == 0, do: []

  defp previews_for_documents(grouped_ids) do
    documents_by_id = documents_by_id()

    Enum.flat_map(grouped_ids, fn {doc_id, ids} ->
      previews_for_document(doc_id, ids, Map.get(documents_by_id, doc_id))
    end)
  end

  defp previews_for_document(doc_id, ids, document_metadata) do
    case Corpus.graph(doc_id) do
      {:ok, graph} ->
        ids
        |> Enum.map(fn id -> {id, preview_from_graph(graph, doc_id, id, document_metadata)} end)
        |> Enum.reject(fn {_id, preview} -> is_nil(preview) end)

      {:error, _reason} ->
        []
    end
  end

  defp safe_find_document(id) do
    Corpus.find_document(id)
  catch
    :exit, _reason -> nil
  end

  defp preview_from_graph(graph, doc_id, id, document_metadata) do
    with iri = Id.iri(id),
         type when not is_nil(type) <- Document.block_type(graph, iri),
         text when text != "" <- block_text(graph, iri, type) do
      ancestry = Corpus.ancestry(graph, Id.iri(doc_id), iri)
      document = Enum.find(ancestry, &(&1.type == :document))
      section = ancestry |> Enum.reverse() |> Enum.find(&(&1.type == :section))

      %{
        id: id,
        type: type,
        text: text,
        document_id: doc_id,
        document_title: entry_title(document, doc_id),
        document_authors: document_authors(document_metadata),
        document_year: document_year(document_metadata),
        section_id: entry_id(section),
        section_title: entry_title(section, nil),
        path: block_path(doc_id, id)
      }
    else
      _other -> nil
    end
  end

  defp documents_by_id do
    case Documents.list() do
      {:ok, documents} -> Map.new(documents, &{&1.id, &1})
      {:error, _reason} -> %{}
    end
  end

  defp document_authors(%{metadata: %{authors: authors}}) when is_list(authors), do: authors
  defp document_authors(_document), do: []

  defp document_year(%{metadata: %{year: year}}) when not is_nil(year), do: to_string(year)
  defp document_year(_document), do: nil

  defp block_text(graph, iri, :paragraph), do: Document.paragraph_text(graph, iri)
  defp block_text(graph, iri, :section), do: Document.heading(graph, iri)
  defp block_text(graph, iri, :row), do: Document.text(graph, iri)
  defp block_text(graph, iri, :extracted), do: graph |> Document.source_html(iri) |> plain_text()
  defp block_text(_graph, _iri, _type), do: ""

  defp block_path(doc_id, id) when doc_id == id, do: "/#{doc_id}"
  defp block_path(doc_id, id), do: "/#{doc_id}?block=#{id}#block-#{id}"

  defp entry_id(nil), do: nil
  defp entry_id(%{id: id}), do: id

  defp entry_title(nil, fallback), do: fallback
  defp entry_title(%{title: title}, fallback) when title in [nil, ""], do: fallback
  defp entry_title(%{title: title}, _fallback), do: title

  defp plain_text(html) do
    html
    |> to_string()
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
