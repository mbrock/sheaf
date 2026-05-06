defmodule SheafWeb.ResourceController do
  @moduledoc """
  Content-negotiated resource endpoint for short Sheaf ids.
  """

  use SheafWeb, :controller

  alias RDF.Description
  alias RDF.NS.RDFS
  alias Sheaf.{Corpus, Document, Id, ResourceResolver}
  alias Sheaf.Assistant.{Notes, QueryResults}
  alias Sheaf.NS.AS
  alias Sheaf.NS.DOC

  def show(%{private: %{phoenix_format: "json"}} = conn, %{"id" => id}) do
    case resource_payload(id) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{
          error: "resource not found",
          id: id,
          reason: inspect(reason)
        })
    end
  end

  def show(conn, %{"id" => _id}) do
    conn
    |> put_status(:not_acceptable)
    |> text("Use Accept: application/json for resource JSON.")
  end

  def resource_payload(id) do
    case ResourceResolver.resolve(id) do
      {:ok, %{kind: :document, id: document_id}} ->
        document_payload(document_id)

      {:ok, %{kind: :block, id: block_id, document_id: document_id}} ->
        block_payload(document_id, block_id)

      {:ok, %{kind: :research_note, id: note_id}} ->
        note_payload(note_id)

      {:ok, %{kind: :spreadsheet_query_result, id: result_id}} ->
        query_result_payload(result_id)

      {:ok, %{kind: :assistant_conversation, id: chat_id}} ->
        {:ok,
         %{
           id: chat_id,
           iri: to_string(Id.iri(chat_id)),
           kind: "assistant_conversation"
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp document_payload(document_id) do
    root = Id.iri(document_id)

    with {:ok, graph} <- Sheaf.fetch_graph(root) do
      {:ok,
       %{
         id: document_id,
         iri: to_string(root),
         kind: Document.kind(graph, root),
         title: Document.title(graph, root),
         outline: graph |> Document.toc(root) |> Enum.map(&outline_entry/1)
       }}
    end
  end

  defp block_payload(document_id, block_id) do
    root = Id.iri(document_id)
    block = Id.iri(block_id)

    with {:ok, graph} <- Corpus.graph(document_id),
         payload when not is_nil(payload) <- block_entry(graph, block) do
      {:ok,
       payload
       |> Map.put(:kind, "block")
       |> Map.put(:document, %{id: document_id, iri: to_string(root)})}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp note_payload(note_id) do
    with {:ok, note, _graph} <- Notes.get(note_id) do
      {:ok,
       %{
         id: note_id,
         iri: to_string(note.subject),
         kind: "research_note",
         title: literal_value(note, RDFS.label()),
         text: literal_value(note, AS.content()),
         published: published_value(note),
         context: iri_value(note, AS.context()),
         attributed_to: iri_value(note, AS.attributedTo()),
         mentions: iri_values(note, DOC.mentions())
       }}
    end
  end

  defp query_result_payload(result_id) do
    with {:ok, result} <- QueryResults.read(result_id, limit: 100) do
      {:ok,
       result
       |> Map.take([
         :id,
         :iri,
         :file_iri,
         :sql,
         :columns,
         :row_count,
         :offset,
         :limit,
         :rows
       ])
       |> Map.put(:kind, "spreadsheet_query_result")}
    end
  end

  defp outline_entry(%{
         iri: iri,
         title: title,
         number: number,
         children: children
       }) do
    %{
      id: Id.id_from_iri(iri),
      iri: to_string(iri),
      number: Enum.join(number, "."),
      title: title,
      children: Enum.map(children, &outline_entry/1)
    }
  end

  defp block_entry(graph, block) do
    case Document.block_type(graph, block) do
      nil ->
        nil

      type ->
        %{
          id: Id.id_from_iri(block),
          iri: to_string(block),
          type: type,
          title: block_title(graph, block, type),
          text: block_text(graph, block, type),
          children:
            graph
            |> Document.children(block)
            |> Enum.map(&block_child(graph, &1))
        }
    end
  end

  defp block_child(graph, iri) do
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

  defp block_text(graph, iri, :paragraph),
    do: Document.paragraph_text(graph, iri)

  defp block_text(graph, iri, :extracted),
    do: Document.source_html(graph, iri)

  defp block_text(graph, iri, :row), do: Document.text(graph, iri)
  defp block_text(_graph, _iri, _type), do: nil

  defp literal_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> term_value()
  end

  defp published_value(%Description{} = description) do
    description
    |> Description.first(AS.published())
    |> term_value()
    |> case do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> value
    end
  end

  defp iri_value(%Description{} = description, predicate) do
    description
    |> Description.first(predicate)
    |> case do
      nil -> nil
      iri -> %{id: Id.id_from_iri(iri), iri: to_string(iri)}
    end
  end

  defp iri_values(%Description{} = description, predicate) do
    description
    |> Description.get(predicate, [])
    |> Enum.map(&%{id: Id.id_from_iri(&1), iri: to_string(&1)})
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    RDF.Term.value(term)
  end
end
