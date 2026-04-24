defmodule Sheaf.Assistant.CorpusTools do
  @moduledoc """
  Corpus-aware tools for assistant chats.

  The tools are stateless wrappers over SPARQL and single-document graph
  fetches. No cached snapshot: each call hits Fuseki directly.
  """

  alias ReqLLM.Tool
  alias Sheaf.{Corpus, Document, Documents, Id}

  @search_result_limit 10

  @doc """
  Builds the tool list used by corpus assistant conversations.

  `notify` receives `{:tool_started, name, args}` and
  `{:tool_finished, name, result}` events.
  """
  def tools(notify \\ fn _event -> :ok end) when is_function(notify, 1) do
    [
      Tool.new!(
        name: "list_documents",
        description:
          "List every document in the Sheaf corpus (thesis + papers). " <>
            "Returns id, kind, title, authors, year, page count, DOI, venue.",
        callback: instrument(notify, "list_documents", &list_documents_tool/1)
      ),
      Tool.new!(
        name: "get_document",
        description:
          "Return a document's metadata and full section outline. " <>
            "Call this before drilling into a document so you know the structure.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Document id (6-char block id)"]
        ],
        callback: instrument(notify, "get_document", &get_document_tool/1)
      ),
      Tool.new!(
        name: "get_block",
        description:
          "Return one block's content. Sections come with their child handles " <>
            "so you can drill further; paragraphs and extracted blocks come with " <>
            "their full text. Every block includes its ancestry from the document root.",
        parameter_schema: [
          document_id: [type: :string, required: true, doc: "Containing document id"],
          block_id: [type: :string, required: true, doc: "Block id to fetch"]
        ],
        callback: instrument(notify, "get_block", &get_block_tool/1)
      ),
      Tool.new!(
        name: "search_text",
        description:
          "Case-insensitive substring search over paragraph and extracted-block " <>
            "text. Searches the whole corpus by default; pass document_id to scope. " <>
            "Returns hits with their document id, block id, kind, and full text.",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search string"],
          document_id: [type: :string, doc: "Optional: scope to one document"],
          limit: [type: :integer, default: @search_result_limit, doc: "Maximum hits"]
        ],
        callback: instrument(notify, "search_text", &search_text_tool/1)
      )
    ]
  end

  def titles do
    case Documents.list() do
      {:ok, docs} -> Map.new(docs, &{&1.id, &1.title})
      _ -> %{}
    end
  end

  def humanize("list_documents", _args, _titles), do: "Looking at the library"

  def humanize("get_document", args, titles) do
    "Reading outline of " <> quote_title(arg(args, :id), titles)
  end

  def humanize("get_block", args, titles) do
    doc_id = arg(args, :document_id)
    block_id = arg(args, :block_id)
    "Opening ##{block_id} in " <> quote_title(doc_id, titles)
  end

  def humanize("search_text", args, titles) do
    q = inspect(arg(args, :query) || "")
    scope = arg(args, :document_id)

    case scope do
      id when is_binary(id) and id != "" ->
        "Searching " <> q <> " in " <> quote_title(id, titles)

      _ ->
        "Searching the corpus for " <> q
    end
  end

  def humanize(name, _args, _titles), do: name

  defp instrument(notify, name, callback) do
    fn args ->
      notify.({:tool_started, name, args})
      result = callback.(args)
      notify.({:tool_finished, name, result})
      result
    end
  end

  defp list_documents_tool(_args) do
    case Documents.list() do
      {:ok, documents} ->
        {:ok, %{documents: Enum.map(documents, &document_summary/1)}}

      {:error, reason} ->
        {:error, "could not list documents: #{inspect(reason)}"}
    end
  end

  defp get_document_tool(args) do
    case arg(args, :id) do
      id when is_binary(id) and id != "" ->
        with {:ok, graph} <- Corpus.graph(id) do
          root = Id.iri(id)

          {:ok,
           %{
             id: id,
             title: Document.title(graph, root),
             kind: Document.kind(graph, root),
             outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
           }}
        end

      _ ->
        {:error, "document id is required"}
    end
  end

  defp get_block_tool(args) do
    doc_id = arg(args, :document_id)
    block_id = arg(args, :block_id)

    cond do
      not is_binary(doc_id) or doc_id == "" ->
        {:error, "document_id is required"}

      not is_binary(block_id) or block_id == "" ->
        {:error, "block_id is required"}

      true ->
        with {:ok, graph} <- Corpus.graph(doc_id) do
          root = Id.iri(doc_id)
          iri = Id.iri(block_id)

          cond do
            iri == root ->
              {:ok,
               %{
                 document_id: doc_id,
                 id: Id.id_from_iri(root),
                 type: :document,
                 title: Document.title(graph, root),
                 kind: Document.kind(graph, root),
                 ancestry: [
                   %{
                     id: Id.id_from_iri(root),
                     type: :document,
                     title: Document.title(graph, root)
                   }
                 ],
                 outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
               }}

            type = Document.block_type(graph, iri) ->
              payload = render_block(graph, doc_id, iri, type)

              ancestry = Corpus.ancestry(graph, root, iri)
              {:ok, Map.put(payload, :ancestry, ancestry)}

            true ->
              {:error, "block #{block_id} not found in document #{doc_id}"}
          end
        end
    end
  end

  defp search_text_tool(args) do
    query = arg(args, :query)

    if is_binary(query) do
      opts =
        [limit: arg(args, :limit) || @search_result_limit]
        |> maybe_add_scope(args)

      case Corpus.search_text(query, opts) do
        {:ok, results} -> {:ok, %{query: query, results: results}}
        {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
      end
    else
      {:error, "query is required"}
    end
  end

  defp maybe_add_scope(opts, args) do
    case arg(args, :document_id) do
      nil -> opts
      "" -> opts
      id -> Keyword.put(opts, :document_id, id)
    end
  end

  defp document_summary(doc) do
    %{
      id: doc.id,
      kind: doc.kind,
      title: doc.title,
      authors: Map.get(doc.metadata, :authors, []),
      year: Map.get(doc.metadata, :year),
      page_count: Map.get(doc.metadata, :page_count),
      doi: Map.get(doc.metadata, :doi),
      venue: Map.get(doc.metadata, :venue)
    }
  end

  defp outline_entry(%{id: id, title: title, number: number, children: children}) do
    %{
      id: id,
      number: Enum.join(number, "."),
      title: title,
      children: Enum.map(children, &outline_entry/1)
    }
  end

  defp render_block(graph, document_id, iri, type) do
    base = %{
      document_id: document_id,
      id: Id.id_from_iri(iri),
      type: type,
      title: block_title(graph, iri, type),
      source: block_source(graph, iri)
    }

    case type do
      :section ->
        Map.put(
          base,
          :children,
          Enum.map(Document.children(graph, iri), &child_handle(graph, &1))
        )

      :paragraph ->
        Map.put(base, :text, Document.paragraph_text(graph, iri))

      :extracted ->
        Map.put(base, :text, plain_text(Document.source_html(graph, iri)))
    end
  end

  defp child_handle(graph, iri) do
    type = Document.block_type(graph, iri)

    %{
      id: Id.id_from_iri(iri),
      type: type,
      title: block_title(graph, iri, type)
    }
  end

  defp block_title(graph, iri, :section), do: Document.heading(graph, iri)
  defp block_title(_graph, _iri, _type), do: nil

  defp block_source(graph, iri) do
    %{
      key: Document.source_key(graph, iri),
      page: Document.source_page(graph, iri),
      type: Document.source_block_type(graph, iri)
    }
  end

  defp quote_title(nil, _titles), do: "an unknown document"
  defp quote_title("", _titles), do: "an unknown document"

  defp quote_title(id, titles) do
    case Map.get(titles, id) do
      nil -> "##{id}"
      title -> ~s("#{ellipsize(title, 48)}")
    end
  end

  defp ellipsize(text, limit) do
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 3) <> "..."
  end

  defp arg(args, key) do
    Map.get(args, key) || Map.get(args, Atom.to_string(key))
  end

  defp plain_text(html) do
    html
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
