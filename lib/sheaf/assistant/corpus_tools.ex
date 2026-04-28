defmodule Sheaf.Assistant.CorpusTools do
  @moduledoc """
  Corpus-aware tools for assistant chats.

  The tools are stateless wrappers over RDF graph fetches and the derived
  embedding search index. No cached snapshot: each call reads current data.
  """

  alias ReqLLM.{Tool, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.{Corpus, Document, Documents, Id, Spreadsheets}
  alias Sheaf.Assistant.Notes
  alias Sheaf.Assistant.{ToolResultText, ToolResults}

  @search_result_limit 10
  @default_search_kinds ~w(paragraph sourceHtml)

  @doc """
  Builds the tool list used by corpus assistant conversations.

  `notify` receives `{:tool_started, name, args}` and
  `{:tool_finished, name, result}` events.
  """
  def tools(opts \\ [])

  def tools(notify) when is_function(notify, 1), do: tools(notify: notify)

  def tools(opts) when is_list(opts) do
    notify = Keyword.get(opts, :notify, fn _event -> :ok end)
    search = Keyword.get(opts, :search, &Sheaf.Embedding.Index.search/2)
    exact_search = Keyword.get(opts, :exact_search, &Sheaf.Embedding.Index.exact_search/2)
    include_notes? = Keyword.get(opts, :include_notes?, true)

    tools = [
      Tool.new!(
        name: "list_documents",
        description:
          "List every document in the Sheaf corpus. " <>
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
        name: "read",
        description:
          "Read one or more blocks by id. Pass blocks as a list of 6-character ids. " <>
            "Blocks may come from different documents; their documents are resolved automatically. " <>
            "By default sections and documents are returned collapsed with child handles. " <>
            "Set expand=true to read the full descendant contents of sections or whole documents. " <>
            "Expanded output still tags every section, paragraph, excerpt, and row with its block id.",
        parameter_schema: [
          blocks: [
            type: {:list, :string},
            required: true,
            doc: "Block ids to read, without leading #. Blocks may belong to different documents."
          ],
          expand: [
            type: :boolean,
            default: false,
            doc:
              "When true, sections and document roots are expanded into their full descendant contents."
          ]
        ],
        callback: instrument(notify, "read", &read_tool/1)
      ),
      Tool.new!(
        name: "search_text",
        description:
          "Hybrid exact and semantic search over paragraph and extracted-block " <>
            "text. Searches the main prose corpus; pass document_id to scope. " <>
            "Use list_spreadsheets, query_spreadsheets, or search_spreadsheets for tabular data. " <>
            "Exact text matches contribute to ranking alongside embedding similarity. " <>
            "Returns hits with their document id, block id, kind, and full text.",
        parameter_schema: [
          query: [
            type: :string,
            required: true,
            doc:
              "Exact phrase or space-separated keywords, for example \"circular economy\" or \"politics economy\"."
          ],
          document_id: [type: :string, doc: "Optional: scope to one document"],
          limit: [type: :integer, default: @search_result_limit, doc: "Maximum hits per category"]
        ],
        callback: instrument(notify, "search_text", &search_text_tool(&1, search, exact_search))
      ),
      Tool.new!(
        name: "list_spreadsheets",
        description:
          "List imported spreadsheet workbooks and sheets available in the SQLite sidecar. " <>
            "Returns SQL table names, row counts, and column names for query_spreadsheets.",
        callback: instrument(notify, "list_spreadsheets", &list_spreadsheets_tool/1)
      ),
      Tool.new!(
        name: "query_spreadsheets",
        description:
          "Run a read-only SQL SELECT/WITH query against imported spreadsheet sheet tables. " <>
            "Call list_spreadsheets first to discover table and column names. " <>
            "Use SQLite syntax; every sheet table has __row_number and __text columns.",
        parameter_schema: [
          sql: [
            type: :string,
            required: true,
            doc:
              "Read-only SQL SELECT or WITH query, for example: SELECT * FROM ss_xl_abc_1 LIMIT 5"
          ],
          limit: [
            type: :integer,
            default: 50,
            doc: "Maximum rows returned by the wrapper, capped by Sheaf."
          ]
        ],
        callback: instrument(notify, "query_spreadsheets", &query_spreadsheets_tool/1)
      ),
      Tool.new!(
        name: "search_spreadsheets",
        description:
          "Exact-ish keyword search over imported spreadsheet rows. " <>
            "Use this to find rows before writing a more precise SQL query.",
        parameter_schema: [
          query: [
            type: :string,
            required: true,
            doc: "Words or phrase to find in spreadsheet rows."
          ],
          limit: [type: :integer, default: 20, doc: "Maximum matching rows returned."]
        ],
        callback: instrument(notify, "search_spreadsheets", &search_spreadsheets_tool/1)
      )
    ]

    if include_notes? do
      note_context = Keyword.get_lazy(opts, :note_context, &default_note_context/0) |> Map.new()
      note_writer = Keyword.get(opts, :note_writer, &Notes.write/1)

      tools ++
        [
          write_note_tool_definition(notify, note_context, note_writer)
        ]
    else
      tools
    end
  end

  defp write_note_tool_definition(notify, note_context, note_writer) do
    Tool.new!(
      name: "write_note",
      description:
        "Persist a durable research note as RDF. Use this for observations, " <>
          "claims, quote candidates, cross-paper links, or reading-plan notes " <>
          "that should survive the chat. Pass mentioned block ids explicitly.",
      parameter_schema: [
        text: [
          type: :string,
          required: true,
          doc:
            "Self-contained note text. Include simple block references like #ABC123 when relevant."
        ],
        block_ids: [
          type: {:list, :string},
          default: [],
          doc: "Block ids mentioned or related by this note, without the leading #."
        ],
        title: [type: :string, doc: "Optional short title for the note."]
      ],
      callback:
        instrument(notify, "write_note", fn args ->
          write_note_tool(args, note_context, note_writer)
        end)
    )
  end

  def titles do
    case Documents.list(include_excluded: false) do
      {:ok, docs} -> Map.new(docs, &{&1.id, &1.title})
      _ -> %{}
    end
  end

  def block_context_text(graph, root, block_id)
      when is_binary(block_id) and block_id != "" do
    case block_from_graph(graph, Id.id_from_iri(root), root, block_id) do
      {:ok, block} ->
        block
        |> ToolResultText.to_text()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def block_context_text(_graph, _root, _block_id), do: {:error, :invalid_block_id}

  def selected_block_context_text(graph, root, block_id)
      when is_binary(block_id) and block_id != "" do
    case block_from_graph(graph, Id.id_from_iri(root), root, block_id) do
      {:ok, block} ->
        block
        |> ToolResultText.selected_block_text()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  def selected_block_context_text(_graph, _root, _block_id), do: {:error, :invalid_block_id}

  def humanize("list_documents", _args, _titles), do: "Checking the library"

  def humanize("get_document", args, titles) do
    "Reading the outline of " <> quote_title(arg(args, :id), titles)
  end

  def humanize("read", args, _titles) do
    block_ids = requested_blocks(args)
    expanded? = expand?(args)

    target =
      case block_ids do
        [block_id] -> "##{block_id}"
        ids when is_list(ids) and ids != [] -> "#{length(ids)} blocks"
        _ids -> "a block"
      end

    suffix = if expanded?, do: " with full contents", else: ""
    "Reading #{target}" <> suffix
  end

  def humanize("search_text", args, titles) do
    q = smart_quote(arg(args, :query) || "")
    scope = arg(args, :document_id)

    case scope do
      id when is_binary(id) and id != "" ->
        "Searching for " <> q <> " in " <> quote_title(id, titles)

      _ ->
        "Searching for " <> q <> " across the corpus"
    end
  end

  def humanize("list_spreadsheets", _args, _titles), do: "Checking spreadsheets"

  def humanize("query_spreadsheets", _args, _titles), do: "Querying spreadsheets"

  def humanize("search_spreadsheets", args, _titles) do
    "Searching spreadsheets for " <> smart_quote(arg(args, :query) || "")
  end

  def humanize("write_note", _args, _titles), do: "Saving a research note"

  def humanize(name, _args, _titles), do: name

  @doc """
  Builds a short human-readable summary of a finished tool result,
  suitable for the right-hand side of a compact tool-call row.
  """
  def result_summary(name, {:ok, %ToolResult{metadata: %{sheaf_result: result}}}) do
    result_summary(name, {:ok, result})
  end

  def result_summary("list_documents", {:ok, %ToolResults.ListDocuments{documents: docs}}) do
    pluralize(length(docs), "document", "documents")
  end

  def result_summary("get_document", {:ok, %ToolResults.Document{title: title, outline: outline}}) do
    sections = "outline with " <> pluralize(length(outline), "section", "sections")

    case title do
      nil -> sections
      "" -> sections
      _t -> sections
    end
  end

  def result_summary("read", {:ok, %ToolResults.Block{type: :section, children: children}}) do
    "section with " <> pluralize(length(children), "child", "children")
  end

  def result_summary("read", {:ok, %ToolResults.Block{type: :paragraph, text: text}})
      when is_binary(text) do
    excerpt_or_kind(text, "paragraph")
  end

  def result_summary("read", {:ok, %ToolResults.Block{type: :extracted, text: text}})
      when is_binary(text) do
    excerpt_or_kind(text, "extracted block")
  end

  def result_summary("read", {:ok, %ToolResults.Block{type: :row, text: text}})
      when is_binary(text) do
    excerpt_or_kind(text, "row")
  end

  def result_summary("read", {:ok, %ToolResults.Block{type: :document, title: title}}) do
    "document" <> if(title in [nil, ""], do: "", else: ": " <> ellipsize(title, 60))
  end

  def result_summary("read", {:ok, %ToolResults.Blocks{blocks: blocks, expanded?: expanded?}}) do
    summary = pluralize(length(blocks), "block", "blocks")
    if expanded?, do: summary <> " expanded", else: summary
  end

  def result_summary("search_text", {:ok, %ToolResults.SearchResults{} = results}) do
    count = length(results.exact_results) + length(results.approximate_results)
    pluralize(count, "hit", "hits")
  end

  def result_summary(
        "list_spreadsheets",
        {:ok, %ToolResults.ListSpreadsheets{spreadsheets: docs}}
      ) do
    pluralize(length(docs), "spreadsheet", "spreadsheets")
  end

  def result_summary("query_spreadsheets", {:ok, %ToolResults.SpreadsheetQuery{rows: rows}}) do
    pluralize(length(rows), "row", "rows")
  end

  def result_summary("search_spreadsheets", {:ok, %ToolResults.SpreadsheetSearch{hits: hits}}) do
    pluralize(length(hits), "hit", "hits")
  end

  def result_summary("write_note", {:ok, %ToolResults.Note{}}), do: "note saved"

  def result_summary(_name, {:error, reason}) when is_binary(reason) do
    "error: " <> ellipsize(reason, 80)
  end

  def result_summary(_name, {:error, reason}) do
    "error: " <> ellipsize(inspect(reason), 80)
  end

  def result_summary(_name, _result), do: nil

  defp pluralize(1, singular, _plural), do: "1 " <> singular
  defp pluralize(n, _singular, plural), do: "#{n} #{plural}"

  defp excerpt_or_kind(text, kind) do
    case text |> to_string() |> normalize_text() do
      "" -> kind
      text -> smart_quote(ellipsize(text, 140))
    end
  end

  defp smart_quote(text), do: "“#{text}”"

  defp instrument(notify, name, callback) do
    fn args ->
      notify.({:tool_started, name, args})
      result = callback.(args)
      notify.({:tool_finished, name, result})
      result
    end
  end

  defp rendered_result(result) do
    %ToolResult{
      content: [ContentPart.text(ToolResultText.to_text(result))],
      metadata: %{sheaf_result: result}
    }
  end

  defp list_documents_tool(_args) do
    case Documents.list(include_excluded: false) do
      {:ok, documents} ->
        {:ok,
         documents
         |> Enum.filter(&assistant_list_document?/1)
         |> Enum.map(&document_summary/1)
         |> then(&%ToolResults.ListDocuments{documents: &1})
         |> rendered_result()}

      {:error, reason} ->
        {:error, "could not list documents: #{inspect(reason)}"}
    end
  end

  defp get_document_tool(args) do
    case arg(args, :id) do
      id when is_binary(id) and id != "" ->
        with {:ok, graph} <- Corpus.graph(id) do
          root = Id.iri(id)

          %ToolResults.Document{
            id: id,
            title: Document.title(graph, root),
            kind: Document.kind(graph, root),
            outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
          }
          |> rendered_result()
          |> then(&{:ok, &1})
        end

      _ ->
        {:error, "document id is required"}
    end
  end

  defp read_tool(args) do
    block_ids = requested_blocks(args)
    expanded? = expand?(args)

    if block_ids == [] do
      {:error, "blocks is required"}
    else
      case read_blocks(block_ids, expanded?) do
        {:ok, [block]} when not expanded? ->
          block
          |> rendered_result()
          |> then(&{:ok, &1})

        {:ok, blocks} ->
          %ToolResults.Blocks{blocks: blocks, expanded?: expanded?}
          |> rendered_result()
          |> then(&{:ok, &1})

        {:error, {:not_found, block_id}} ->
          {:error, "block #{block_id} not found"}

        {:error, {reason, block_id}} ->
          {:error, "could not read block #{block_id}: #{inspect(reason)}"}
      end
    end
  end

  defp search_text_tool(args, search, exact_search) do
    query = arg(args, :query)

    if is_binary(query) do
      opts =
        [limit: arg(args, :limit) || @search_result_limit]
        |> maybe_add_scope(args)
        |> Keyword.put(:kinds, @default_search_kinds)

      with {:ok, exact_results} <- exact_search.(query, opts),
           {:ok, approximate_results} <- search.(query, Keyword.put(opts, :exact_limit, 0)) do
        %ToolResults.SearchResults{
          exact_results: exact_results |> Enum.map(&search_hit/1) |> add_search_contexts(),
          approximate_results:
            approximate_results |> Enum.map(&search_hit/1) |> add_search_contexts()
        }
        |> rendered_result()
        |> then(&{:ok, &1})
      else
        {:error, reason} -> {:error, "search failed: #{inspect(reason)}"}
      end
    else
      {:error, "query is required"}
    end
  end

  defp list_spreadsheets_tool(_args) do
    case Spreadsheets.list() do
      {:ok, spreadsheets} ->
        spreadsheets
        |> Enum.map(&spreadsheet_result/1)
        |> then(&%ToolResults.ListSpreadsheets{spreadsheets: &1})
        |> rendered_result()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, "could not list spreadsheets: #{inspect(reason)}"}
    end
  end

  defp query_spreadsheets_tool(args) do
    sql = arg(args, :sql)

    if is_binary(sql) and String.trim(sql) != "" do
      case Spreadsheets.query(sql, limit: arg(args, :limit) || 50) do
        {:ok, result} ->
          %ToolResults.SpreadsheetQuery{
            sql: sql,
            columns: result.columns,
            rows: result.rows
          }
          |> rendered_result()
          |> then(&{:ok, &1})

        {:error, reason} ->
          {:error, "spreadsheet query failed: #{inspect(reason)}"}
      end
    else
      {:error, "sql is required"}
    end
  end

  defp search_spreadsheets_tool(args) do
    query = arg(args, :query)

    if is_binary(query) and String.trim(query) != "" do
      case Spreadsheets.search(query, limit: arg(args, :limit) || 20) do
        {:ok, hits} ->
          %ToolResults.SpreadsheetSearch{query: query, hits: hits}
          |> rendered_result()
          |> then(&{:ok, &1})

        {:error, reason} ->
          {:error, "spreadsheet search failed: #{inspect(reason)}"}
      end
    else
      {:error, "query is required"}
    end
  end

  defp write_note_tool(args, note_context, note_writer) do
    attrs =
      note_context
      |> Map.merge(%{
        text: arg(args, :text),
        block_ids: arg(args, :block_ids) || [],
        title: arg(args, :title)
      })
      |> drop_nil_values()

    case note_writer.(attrs) do
      {:ok, %RDF.IRI{} = note} ->
        %ToolResults.Note{id: Id.id_from_iri(note), iri: to_string(note)}
        |> rendered_result()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, "could not write note: #{inspect(reason)}"}

      other ->
        {:error, "could not write note: unexpected result #{inspect(other)}"}
    end
  end

  defp maybe_add_scope(opts, args) do
    case arg(args, :document_id) do
      nil -> opts
      "" -> opts
      id -> Keyword.put(opts, :document_id, id)
    end
  end

  defp expand?(args), do: arg(args, :expand) in [true, "true"]

  defp spreadsheet_result(spreadsheet) do
    %ToolResults.Spreadsheet{
      id: spreadsheet.id,
      title: spreadsheet.title,
      path: spreadsheet.path,
      sheets: Enum.map(spreadsheet.sheets, &spreadsheet_sheet_result/1)
    }
  end

  defp spreadsheet_sheet_result(sheet) do
    %ToolResults.SpreadsheetSheet{
      spreadsheet_id: sheet.spreadsheet_id,
      name: sheet.name,
      table_name: sheet.table_name,
      row_count: sheet.row_count,
      col_count: sheet.col_count,
      columns: sheet.columns
    }
  end

  defp search_hit(result) do
    %ToolResults.SearchHit{
      document_id: result.doc_iri && Id.id_from_iri(result.doc_iri),
      document_title: result.doc_title,
      document_authors: Map.get(result, :doc_authors, []),
      block_id: Id.id_from_iri(result.iri),
      kind: search_hit_kind(result.kind),
      text: search_hit_text(result),
      source_page: result.source_page,
      match: result.match,
      score: result.score
    }
    |> maybe_add_search_coding(result)
  end

  defp search_hit_kind("paragraph"), do: :paragraph
  defp search_hit_kind("sourceHtml"), do: :extracted
  defp search_hit_kind("row"), do: :row
  defp search_hit_kind(kind) when is_binary(kind), do: String.to_atom(kind)
  defp search_hit_kind(kind), do: kind

  defp search_hit_text(%{kind: "sourceHtml", text: text}), do: plain_text(text)
  defp search_hit_text(%{text: text}), do: normalize_text(text)

  defp maybe_add_search_coding(hit, %{kind: "row"} = result) do
    Map.put(hit, :coding, %ToolResults.Coding{
      row: result.spreadsheet_row,
      source: result.spreadsheet_source,
      category: Map.get(result, :code_category),
      category_title: result.code_category_title
    })
  end

  defp maybe_add_search_coding(hit, _result), do: hit

  defp add_search_contexts(hits) do
    hits
    |> Enum.group_by(& &1.document_id)
    |> Enum.flat_map(fn {_document_id, document_hits} ->
      add_document_contexts(document_hits)
    end)
  end

  defp add_document_contexts([%ToolResults.SearchHit{document_id: document_id} | _] = hits)
       when is_binary(document_id) and document_id != "" do
    try do
      case Corpus.graph(document_id) do
        {:ok, graph} ->
          root = Id.iri(document_id)

          Enum.map(hits, fn hit ->
            context =
              graph
              |> Corpus.ancestry(root, Id.iri(hit.block_id))
              |> Enum.map(&context_entry/1)
              |> section_context(hit.block_id)

            %{hit | context: context}
          end)

        _ ->
          hits
      end
    rescue
      _error -> hits
    end
  end

  defp add_document_contexts(hits), do: hits

  defp section_context(entries, block_id) do
    Enum.reject(entries, fn
      %ToolResults.ContextEntry{type: :document} -> true
      %ToolResults.ContextEntry{id: ^block_id} -> true
      _entry -> false
    end)
  end

  defp document_summary(doc) do
    %ToolResults.DocumentSummary{
      id: doc.id,
      kind: doc.kind,
      metadata_kind: Map.get(doc.metadata, :kind),
      title: doc.title,
      authors: Map.get(doc.metadata, :authors, []),
      year: Map.get(doc.metadata, :year),
      page_count: Map.get(doc.metadata, :page_count),
      doi: Map.get(doc.metadata, :doi),
      venue: Map.get(doc.metadata, :venue),
      publisher: Map.get(doc.metadata, :publisher),
      pages: Map.get(doc.metadata, :pages),
      status: Map.get(doc.metadata, :status),
      cited?: Map.get(doc, :cited?, false),
      has_document?: Map.get(doc, :has_document?, true),
      workspace_owner_authored?: Map.get(doc, :workspace_owner_authored?, false)
    }
  end

  defp assistant_list_document?(%{kind: kind}) when kind in [:transcript, :spreadsheet], do: false
  defp assistant_list_document?(%{has_document?: false}), do: false
  defp assistant_list_document?(_doc), do: true

  defp requested_blocks(args) do
    args
    |> arg(:blocks)
    |> List.wrap()
    |> normalize_block_ids()
  end

  defp normalize_block_ids(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp outline_entry(%{id: id, title: title, number: number, children: children}) do
    %ToolResults.OutlineEntry{
      id: id,
      number: Enum.join(number, "."),
      title: title,
      children: Enum.map(children, &outline_entry/1)
    }
  end

  defp read_blocks(block_ids, expanded?) do
    Enum.reduce_while(block_ids, {:ok, []}, fn block_id, {:ok, blocks} ->
      case read_block(block_id, expanded?) do
        {:ok, block} when is_list(block) -> {:cont, {:ok, blocks ++ block}}
        {:ok, block} -> {:cont, {:ok, blocks ++ [block]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp read_block(block_id, expanded?) do
    with {:ok, document_id} <- document_for_block(block_id),
         {:ok, graph} <- Corpus.graph(document_id) do
      root = Id.iri(document_id)

      if expanded? do
        graph
        |> expanded_blocks_from_graph(document_id, root, Id.iri(block_id))
        |> prepend_document_header(graph, document_id, root)
      else
        block_from_graph(graph, document_id, root, block_id)
      end
    else
      {:error, :not_found} -> {:error, {:not_found, block_id}}
      {:error, reason} -> {:error, {reason, block_id}}
    end
  end

  defp document_for_block(block_id) do
    case Corpus.find_document(block_id) do
      nil -> {:error, :not_found}
      document_id -> {:ok, document_id}
    end
  end

  defp prepend_document_header({:error, reason}, _graph, _document_id, _root),
    do: {:error, reason}

  defp prepend_document_header(
         {:ok, [%ToolResults.Block{type: :document} | _blocks] = blocks},
         _graph,
         _document_id,
         _root
       ) do
    {:ok, blocks}
  end

  defp prepend_document_header({:ok, blocks}, graph, document_id, root) do
    case block_from_graph(graph, document_id, root, document_id) do
      {:ok, document} -> {:ok, [document | blocks]}
      {:error, _reason} -> {:ok, blocks}
    end
  end

  defp expanded_blocks_from_graph(graph, document_id, root, iri) do
    block_id = Id.id_from_iri(iri)

    case block_from_graph(graph, document_id, root, block_id) do
      {:ok, block} ->
        descendants =
          graph
          |> Document.children(iri)
          |> Enum.flat_map(fn child ->
            case expanded_blocks_from_graph(graph, document_id, root, child) do
              {:ok, blocks} -> blocks
              {:error, _reason} -> []
            end
          end)

        {:ok, [block | descendants]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp block_from_graph(graph, document_id, root, block_id) do
    iri = Id.iri(block_id)

    cond do
      iri == root ->
        {:ok,
         %ToolResults.Block{
           document_id: document_id,
           id: Id.id_from_iri(root),
           type: :document,
           title: Document.title(graph, root),
           kind: Document.kind(graph, root),
           ancestry: [
             %ToolResults.ContextEntry{
               id: Id.id_from_iri(root),
               type: :document,
               title: Document.title(graph, root)
             }
           ],
           outline: Enum.map(Document.toc(graph, root), &outline_entry/1)
         }}

      type = Document.block_type(graph, iri) ->
        block =
          graph
          |> render_block(document_id, iri, type)
          |> Map.put(
            :ancestry,
            graph |> Corpus.ancestry(root, iri) |> Enum.map(&context_entry/1)
          )

        {:ok, block}

      true ->
        {:error, {:not_found, block_id}}
    end
  end

  defp render_block(graph, document_id, iri, type) do
    base = %ToolResults.Block{
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

      :row ->
        base
        |> Map.put(:text, Document.text(graph, iri))
        |> Map.put(:coding, row_coding(graph, iri))
    end
  end

  defp child_handle(graph, iri) do
    type = Document.block_type(graph, iri)

    %ToolResults.Child{
      id: Id.id_from_iri(iri),
      type: type,
      title: block_title(graph, iri, type),
      preview: block_preview(graph, iri, type)
    }
  end

  defp context_entry(%{id: id, type: type, title: title}) do
    %ToolResults.ContextEntry{id: id, type: type, title: title}
  end

  defp block_title(graph, iri, :section), do: Document.heading(graph, iri)
  defp block_title(_graph, _iri, _type), do: nil

  defp block_preview(graph, iri, :paragraph),
    do: graph |> Document.paragraph_text(iri) |> preview()

  defp block_preview(graph, iri, :extracted),
    do: graph |> Document.source_html(iri) |> plain_text() |> preview()

  defp block_preview(graph, iri, :row), do: graph |> Document.text(iri) |> preview()
  defp block_preview(_graph, _iri, _type), do: nil

  defp block_source(graph, iri) do
    %ToolResults.Source{
      key: Document.source_key(graph, iri),
      page: Document.source_page(graph, iri),
      type: Document.source_block_type(graph, iri)
    }
  end

  defp row_coding(graph, iri) do
    %ToolResults.Coding{
      row: Document.spreadsheet_row(graph, iri),
      source: Document.spreadsheet_source(graph, iri),
      category: Document.code_category(graph, iri),
      category_title: Document.code_category_title(graph, iri)
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
    if String.length(text) <= limit, do: text, else: String.slice(text, 0, limit - 1) <> "…"
  end

  defp preview(nil), do: nil

  defp preview(text) do
    text
    |> normalize_text()
    |> ellipsize(180)
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
    |> normalize_text()
  end

  defp normalize_text(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp default_note_context do
    %{
      agent_iri: Sheaf.mint(),
      agent_label: "Sheaf research assistant",
      session_iri: Sheaf.mint(),
      session_label: "Assistant conversation",
      conversation_mode: "research"
    }
  end

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end
end
