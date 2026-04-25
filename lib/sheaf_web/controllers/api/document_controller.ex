defmodule SheafWeb.API.DocumentController do
  @moduledoc """
  Minimal JSON API over the Sheaf document graph.

  Designed for in-process agent tools and for poking at the system with curl.
  Every response carries stable IRIs so callers can drill down without guessing.
  """

  use SheafWeb, :controller

  alias Sheaf.{Document, Documents, Id}

  def index(conn, _params) do
    case Documents.list() do
      {:ok, documents} ->
        json(conn, %{documents: Enum.map(documents, &summary/1)})

      {:error, reason} ->
        send_error(conn, 502, "failed to list documents", reason)
    end
  end

  def show(conn, %{"id" => id}) do
    root = Id.iri(id)
    {:ok, graph} = Sheaf.fetch_graph(root)

    summary = document_summary(id, graph, root)
    outline = Document.toc(graph, root) |> Enum.map(&outline_entry/1)

    json(conn, Map.put(summary, :outline, outline))
  end

  def chunks(conn, %{"id" => id}) do
    root = Id.iri(id)
    {:ok, graph} = Sheaf.fetch_graph(root)

    chunks = Document.text_chunks(graph, root) |> Enum.map(&chunk_entry/1)

    json(conn, %{id: id, iri: to_string(root), chunks: chunks})
  end

  def block(conn, %{"id" => id, "block_id" => block_id}) do
    root = Id.iri(id)
    block_iri = Id.iri(block_id)
    {:ok, graph} = Sheaf.fetch_graph(root)

    case block_payload(graph, block_iri) do
      nil ->
        send_error(conn, 404, "block not found in document", %{
          document: id,
          block: block_id
        })

      payload ->
        json(conn, Map.put(payload, :document, %{id: id, iri: to_string(root)}))
    end
  end

  defp summary(document) do
    %{
      id: document.id,
      iri: to_string(document.iri),
      kind: document.kind,
      title: document.title,
      path: document.path,
      metadata: document.metadata
    }
  end

  defp document_summary(id, graph, root) do
    %{
      id: id,
      iri: to_string(root),
      title: Document.title(graph, root),
      kind: Document.kind(graph, root)
    }
  end

  defp outline_entry(%{iri: iri, title: title, number: number, children: children}) do
    %{
      id: Id.id_from_iri(iri),
      iri: to_string(iri),
      number: Enum.join(number, "."),
      title: title,
      children: Enum.map(children, &outline_entry/1)
    }
  end

  defp chunk_entry(%{iri: iri} = chunk) do
    %{
      id: Id.id_from_iri(iri),
      iri: to_string(iri),
      type: chunk.type,
      text: chunk.text,
      source: %{
        key: chunk.source_key,
        page: chunk.source_page,
        type: chunk.source_type
      }
    }
  end

  defp block_payload(graph, block_iri) do
    case Document.block_type(graph, block_iri) do
      nil ->
        nil

      type ->
        children =
          graph
          |> Document.children(block_iri)
          |> Enum.map(&child_handle(graph, &1))

        %{
          id: Id.id_from_iri(block_iri),
          iri: to_string(block_iri),
          type: type,
          title: block_title(graph, block_iri, type),
          text: block_text(graph, block_iri, type),
          source: block_source(graph, block_iri),
          children: children
        }
        |> maybe_add_coding(graph, block_iri, type)
    end
  end

  defp child_handle(graph, iri) do
    type = Document.block_type(graph, iri)

    %{
      id: Id.id_from_iri(iri),
      iri: to_string(iri),
      type: type,
      title: block_title(graph, iri, type)
    }
  end

  defp block_title(graph, iri, :section), do: Document.heading(graph, iri)
  defp block_title(_graph, _iri, _type), do: nil

  defp block_text(graph, iri, :paragraph), do: Document.paragraph_text(graph, iri)
  defp block_text(graph, iri, :extracted), do: Document.source_html(graph, iri)
  defp block_text(graph, iri, :row), do: Document.text(graph, iri)
  defp block_text(_graph, _iri, _type), do: nil

  defp block_source(graph, iri) do
    %{
      key: Document.source_key(graph, iri),
      page: Document.source_page(graph, iri),
      type: Document.source_block_type(graph, iri)
    }
  end

  defp maybe_add_coding(payload, graph, iri, :row) do
    Map.put(payload, :coding, %{
      row: Document.spreadsheet_row(graph, iri),
      source: Document.spreadsheet_source(graph, iri),
      category: Document.code_category(graph, iri),
      category_title: Document.code_category_title(graph, iri)
    })
  end

  defp maybe_add_coding(payload, _graph, _iri, _type), do: payload

  defp send_error(conn, status, message, reason) do
    conn
    |> put_status(status)
    |> json(%{error: message, reason: inspect(reason)})
  end
end
