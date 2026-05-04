defmodule Sheaf.Assistant.CorpusTools do
  @moduledoc """
  Corpus-aware tools for assistant chats.

  The tools are stateless wrappers over RDF graph fetches and the derived
  embedding search index. No cached snapshot: each call reads current data.
  """

  alias ReqLLM.{Tool, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.{BlockTags, Corpus, Document, DocumentEdits, Documents, Id, Spreadsheets}
  alias Sheaf.Assistant.Notes
  alias Sheaf.Assistant.{QueryResults, SpreadsheetSession, ToolResultText, ToolResults}
  alias Sheaf.Embedding.Index, as: EmbeddingIndex
  alias Sheaf.Search.Index, as: SearchIndex

  @search_result_limit 10
  @spreadsheet_list_limit 50
  @default_search_kinds ~w(paragraph sourceHtml row)

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
    paragraph_tagger = Keyword.get(opts, :paragraph_tagger, &BlockTags.attach/2)
    include_notes? = Keyword.get(opts, :include_notes?, true)
    tool_set = Keyword.get(opts, :tool_set, :default)
    spreadsheet_session = Keyword.get(opts, :spreadsheet_session)
    query_result_context = Keyword.get(opts, :query_result_context, [])
    query_result_reader = Keyword.get(opts, :query_result_reader, &QueryResults.read/2)

    block_text_replacer =
      Keyword.get(opts, :block_text_replacer, &DocumentEdits.replace_block_text/2)

    block_mover = Keyword.get(opts, :block_mover, &DocumentEdits.move_block/3)
    paragraph_inserter = Keyword.get(opts, :paragraph_inserter, &DocumentEdits.insert_paragraph/3)
    block_deleter = Keyword.get(opts, :block_deleter, &DocumentEdits.delete_block/1)

    search_index_updater =
      Keyword.get(opts, :search_index_updater, &update_search_index_for_blocks/1)

    {spreadsheet_lister, spreadsheet_query, spreadsheet_search, spreadsheet_dialect,
     spreadsheet_result_reader} =
      spreadsheet_backend(opts, spreadsheet_session, query_result_context, query_result_reader)

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
          "Hybrid exact and semantic search over paragraph, extracted-block, and RDF row " <>
            "text. Searches the RDF document corpus; pass document_id to scope to one " <>
            "document or document_kind to scope to a document type such as thesis, literature, " <>
            "spreadsheet, transcript, or document. " <>
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
          document_kind: [
            type: :string,
            doc: "Optional: scope to one document kind, e.g. thesis, literature, spreadsheet."
          ],
          limit: [type: :integer, default: @search_result_limit, doc: "Maximum hits per category"]
        ],
        callback: instrument(notify, "search_text", &search_text_tool(&1, search, exact_search))
      ),
      Tool.new!(
        name: "tag_paragraphs",
        description:
          "Attach writing-attention tags directly to one or more thesis paragraph blocks. " <>
            "Use this for draft paragraphs that are placeholders, fragments, need evidence, " <>
            "or need revision. Only paragraph blocks are accepted.",
        parameter_schema: [
          blocks: [
            type: {:list, :string},
            required: true,
            doc: "Paragraph block ids to tag, without leading #."
          ],
          tags: [
            type: {:list, {:in, BlockTags.tag_names()}},
            required: true,
            doc:
              "Writing tags to attach. Allowed values: " <> Enum.join(BlockTags.tag_names(), ", ")
          ]
        ],
        callback:
          instrument(notify, "tag_paragraphs", fn args ->
            tag_paragraphs_tool(args, paragraph_tagger)
          end)
      )
    ]

    tools =
      if tool_set == :edit do
        tools ++
          edit_tool_definitions(
            notify,
            block_text_replacer,
            block_mover,
            paragraph_inserter,
            block_deleter,
            search_index_updater
          )
      else
        tools ++
          sidecar_spreadsheet_tools(
            notify,
            spreadsheet_lister,
            spreadsheet_query,
            spreadsheet_search,
            spreadsheet_result_reader,
            spreadsheet_dialect
          )
      end

    if include_notes? and tool_set != :edit do
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

  defp edit_tool_definitions(
         notify,
         block_text_replacer,
         block_mover,
         paragraph_inserter,
         block_deleter,
         search_index_updater
       ) do
    [
      Tool.new!(
        name: "update_block_text",
        description:
          "Replace the full text of one editable thesis block. For a paragraph block, " <>
            "this creates a new active paragraph revision and invalidates the old one. " <>
            "For a section block, this changes the heading title. Only paragraph and " <>
            "section blocks are accepted.",
        parameter_schema: [
          block: [type: :string, required: true, doc: "Paragraph or section block id."],
          text: [
            type: :string,
            required: true,
            doc: "Complete replacement paragraph text or complete replacement heading title."
          ]
        ],
        callback:
          instrument(notify, "update_block_text", fn args ->
            update_block_text_tool(args, block_text_replacer)
          end)
      ),
      Tool.new!(
        name: "move_block",
        description:
          "Move an existing block to a new location in the same document. " <>
            "Use position=after to make block the next sibling of target, " <>
            "position=before to make it the previous sibling, or first_child/last_child " <>
            "to reparent it under a section or document block.",
        parameter_schema: [
          block: [type: :string, required: true, doc: "Block id to move."],
          target: [type: :string, required: true, doc: "Block id used as the placement target."],
          position: [
            type: {:in, ["before", "after", "first_child", "last_child"]},
            required: true,
            doc: "Where to place block relative to target."
          ]
        ],
        callback:
          instrument(notify, "move_block", fn args ->
            move_block_tool(args, block_mover)
          end)
      ),
      Tool.new!(
        name: "insert_paragraph",
        description:
          "Insert a new thesis paragraph block at a specific location. " <>
            "Use position=after to insert as the next sibling of target, " <>
            "position=before for previous sibling, or first_child/last_child under " <>
            "a section or document block.",
        parameter_schema: [
          target: [type: :string, required: true, doc: "Block id used as the placement target."],
          position: [
            type: {:in, ["before", "after", "first_child", "last_child"]},
            required: true,
            doc: "Where to insert the paragraph relative to target."
          ],
          text: [
            type: :string,
            required: true,
            doc: "Full text for the new paragraph block."
          ]
        ],
        callback:
          instrument(notify, "insert_paragraph", fn args ->
            insert_paragraph_tool(args, paragraph_inserter)
          end)
      ),
      Tool.new!(
        name: "delete_block",
        description:
          "Delete one existing thesis block from the document. " <>
            "Deleting a section also deletes all of its descendant blocks. " <>
            "Document roots cannot be deleted.",
        parameter_schema: [
          block: [type: :string, required: true, doc: "Block id to delete."]
        ],
        callback:
          instrument(notify, "delete_block", fn args ->
            delete_block_tool(args, block_deleter)
          end)
      ),
      Tool.new!(
        name: "update_search_index",
        description:
          "Refresh derived search indexes after document edits. " <>
            "Pass the paragraph, section, or document blocks affected by the edit. " <>
            "The tool re-embeds stale affected text blocks and updates the SQLite FTS mirror.",
        parameter_schema: [
          blocks: [
            type: {:list, :string},
            required: true,
            doc:
              "Edited, inserted, moved, or deleted block ids. Section/document ids are expanded to text-bearing descendants."
          ]
        ],
        callback:
          instrument(notify, "update_search_index", fn args ->
            update_search_index_tool(args, search_index_updater)
          end)
      )
    ]
  end

  defp spreadsheet_backend(opts, nil, _query_result_context, query_result_reader) do
    {
      Keyword.get(opts, :spreadsheet_lister, &Spreadsheets.list/0),
      Keyword.get(opts, :spreadsheet_query, &Spreadsheets.query/2),
      Keyword.get(opts, :spreadsheet_search, &Spreadsheets.search/2),
      :sqlite,
      query_result_reader
    }
  end

  defp spreadsheet_backend(opts, spreadsheet_session, query_result_context, query_result_reader) do
    {
      Keyword.get(opts, :spreadsheet_lister, fn ->
        SpreadsheetSession.list(spreadsheet_session)
      end),
      Keyword.get(opts, :spreadsheet_query, fn sql, query_opts ->
        SpreadsheetSession.query(
          spreadsheet_session,
          sql,
          Keyword.put(query_opts, :query_result_context, query_result_context)
        )
      end),
      Keyword.get(opts, :spreadsheet_search, fn query, search_opts ->
        SpreadsheetSession.search(spreadsheet_session, query, search_opts)
      end),
      :duckdb,
      query_result_reader
    }
  end

  defp sidecar_spreadsheet_tools(
         notify,
         spreadsheet_lister,
         spreadsheet_query,
         spreadsheet_search,
         spreadsheet_result_reader,
         spreadsheet_dialect
       ) do
    case spreadsheet_lister.() do
      {:ok, [_spreadsheet | _spreadsheets]} ->
        [
          list_spreadsheets_tool_definition(notify, spreadsheet_lister, spreadsheet_dialect),
          query_spreadsheets_tool_definition(notify, spreadsheet_query, spreadsheet_dialect),
          read_spreadsheet_query_result_tool_definition(notify, spreadsheet_result_reader),
          search_spreadsheets_tool_definition(notify, spreadsheet_search)
        ]

      _empty_or_error ->
        []
    end
  end

  defp read_spreadsheet_query_result_tool_definition(notify, query_result_reader) do
    Tool.new!(
      name: "read_spreadsheet_query_result",
      description:
        "Read a page of rows from a saved spreadsheet query result. " <>
          "query_spreadsheets returns the result id. Rows are returned as TSV.",
      parameter_schema: [
        id: [
          type: :string,
          required: true,
          doc: "Saved query result id or IRI returned by query_spreadsheets."
        ],
        offset: [
          type: :integer,
          default: 0,
          doc: "Zero-based row offset into the saved result."
        ],
        limit: [
          type: :integer,
          default: 50,
          doc: "Maximum rows to read from the saved result page."
        ]
      ],
      callback:
        instrument(notify, "read_spreadsheet_query_result", fn args ->
          read_spreadsheet_query_result_tool(args, query_result_reader)
        end)
    )
  end

  defp list_spreadsheets_tool_definition(notify, spreadsheet_lister, spreadsheet_dialect) do
    Tool.new!(
      name: "list_spreadsheets",
      description:
        "List spreadsheet workbooks and sheets available in the #{spreadsheet_label(spreadsheet_dialect)} workspace. " <>
          "Returns SQL table names, row counts, and column names for query_spreadsheets. " <>
          "Use query to filter by workbook title, path, sheet name, table name, or column name.",
      parameter_schema: [
        query: [
          type: :string,
          doc:
            "Optional case-insensitive filter for workbook title/path, sheet name, table name, or column name."
        ],
        limit: [
          type: :integer,
          default: @spreadsheet_list_limit,
          doc: "Maximum sheets returned by the wrapper, capped by Sheaf."
        ]
      ],
      callback:
        instrument(notify, "list_spreadsheets", fn args ->
          list_spreadsheets_tool(args, spreadsheet_lister)
        end)
    )
  end

  defp query_spreadsheets_tool_definition(notify, spreadsheet_query, spreadsheet_dialect) do
    Tool.new!(
      name: "query_spreadsheets",
      description:
        "Run SQL against spreadsheet sheet tables in the #{spreadsheet_label(spreadsheet_dialect)} workspace. " <>
          "Call list_spreadsheets first to discover table and column names. " <>
          "Metadata tables sheaf_spreadsheets and sheaf_spreadsheet_sheets are available for discovery. " <>
          spreadsheet_query_guidance(spreadsheet_dialect),
      parameter_schema: [
        intent: [
          type: :string,
          required: true,
          doc:
            "Plain-English purpose of this SQL, such as \"rank surnames by popularity\" or \"create a reusable tender summary view\"."
        ],
        sql: [
          type: :string,
          required: true,
          doc: spreadsheet_sql_doc(spreadsheet_dialect)
        ],
        limit: [
          type: :integer,
          default: 50,
          doc:
            "Preview rows to include in this tool response. The full SQL result is saved and can be paged by result id, so prefer pagination over conservative SQL LIMIT when the complete result may be useful."
        ]
      ],
      callback:
        instrument(notify, "query_spreadsheets", fn args ->
          query_spreadsheets_tool(args, spreadsheet_query)
        end)
    )
  end

  defp search_spreadsheets_tool_definition(notify, spreadsheet_search) do
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
      callback:
        instrument(notify, "search_spreadsheets", fn args ->
          search_spreadsheets_tool(args, spreadsheet_search)
        end)
    )
  end

  defp spreadsheet_label(:duckdb), do: "per-chat DuckDB"
  defp spreadsheet_label(:sqlite), do: "SQLite sidecar"

  defp spreadsheet_query_guidance(:duckdb) do
    "Use DuckDB SQL. Spreadsheet source columns are imported as VARCHAR under DuckDB-normalized SQL column names; use try_cast for numeric/date analysis. " <>
      "Every loaded sheet table also has __row_number and __text columns. " <>
      "You may create temporary tables or views for scratch work in this chat session. " <>
      "The response includes a TSV preview plus a durable result id for the full final result; use read_spreadsheet_query_result to page it. " <>
      "Do not add SQL LIMIT just to save tool-output tokens when the full result may be useful later. If a saved result is useful for the user, mention its id like #PK9ACK in your reply so Sheaf can render it as a clickable resource."
  end

  defp spreadsheet_query_guidance(:sqlite) do
    "Use SQLite syntax; spreadsheet source columns are TEXT, and every sheet table has __row_number and __text columns. The response includes a preview plus a durable result id for the full final result."
  end

  defp spreadsheet_sql_doc(:duckdb) do
    "DuckDB SQL query or script. Spreadsheet source columns are VARCHAR; cast with try_cast when needed. Multi-statement scripts are allowed, and the final statement is saved as the durable result. Example: CREATE TEMP VIEW tender_summary AS SELECT tender_id, try_cast(total_bids AS INTEGER) AS bids FROM xlsx_inventory_abc_1; SELECT * FROM tender_summary"
  end

  defp spreadsheet_sql_doc(:sqlite) do
    "Read-only SQL SELECT or WITH query. Spreadsheet source columns are TEXT. Example: SELECT * FROM ss_xl_abc_1 LIMIT 5"
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

  def humanize("list_spreadsheets", args, _titles) do
    case args |> arg(:query) |> clean_intent() do
      nil -> "Listing available spreadsheet sheets"
      query -> "Listing spreadsheet sheets matching " <> smart_quote(query)
    end
  end

  def humanize("query_spreadsheets", args, _titles) do
    case args |> arg(:intent) |> clean_intent() do
      nil -> "Querying spreadsheets"
      intent -> intent
    end
  end

  def humanize("read_spreadsheet_query_result", _args, _titles),
    do: "Reading spreadsheet query result"

  def humanize("search_spreadsheets", args, _titles) do
    "Searching spreadsheet rows for " <> smart_quote(arg(args, :query) || "")
  end

  def humanize("write_note", _args, _titles), do: "Saving a research note"

  def humanize("tag_paragraphs", args, _titles) do
    block_ids = requested_blocks(args)

    case block_ids do
      [block_id] -> "Tagging ##{block_id}"
      ids when is_list(ids) and ids != [] -> "Tagging #{length(ids)} paragraphs"
      _ids -> "Tagging paragraphs"
    end
  end

  def humanize("update_block_text", args, _titles) do
    case arg(args, :block) do
      block when is_binary(block) and block != "" -> "Updating ##{block}"
      _ -> "Updating a block"
    end
  end

  def humanize("move_block", args, _titles) do
    block = arg(args, :block)
    target = arg(args, :target)
    position = arg(args, :position)

    if is_binary(block) and is_binary(target) and is_binary(position) do
      "Moving ##{block} #{position} ##{target}"
    else
      "Moving a block"
    end
  end

  def humanize("insert_paragraph", args, _titles) do
    target = arg(args, :target)
    position = arg(args, :position)

    if is_binary(target) and is_binary(position) do
      "Inserting a paragraph #{position} ##{target}"
    else
      "Inserting a paragraph"
    end
  end

  def humanize("update_search_index", args, _titles) do
    block_ids = requested_blocks(args)

    case block_ids do
      [block_id] -> "Updating search indexes for ##{block_id}"
      ids when is_list(ids) and ids != [] -> "Updating search indexes for #{length(ids)} blocks"
      _ids -> "Updating search indexes"
    end
  end

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

  def result_summary(
        "read_spreadsheet_query_result",
        {:ok, %ToolResults.SpreadsheetQueryResultPage{rows: rows}}
      ) do
    pluralize(length(rows), "row", "rows")
  end

  def result_summary("search_spreadsheets", {:ok, %ToolResults.SpreadsheetSearch{hits: hits}}) do
    pluralize(length(hits), "hit", "hits")
  end

  def result_summary("write_note", {:ok, %ToolResults.Note{}}), do: "note saved"

  def result_summary("tag_paragraphs", {:ok, %ToolResults.ParagraphTags{} = result}) do
    "#{pluralize(length(result.tags), "tag", "tags")} on " <>
      pluralize(length(result.block_ids), "paragraph", "paragraphs")
  end

  def result_summary(name, {:ok, %ToolResults.BlockEdit{} = result})
      when name in ["update_block_text", "move_block", "insert_paragraph", "delete_block"] do
    "changed " <> pluralize(result.statement_count, "statement", "statements")
  end

  def result_summary("update_search_index", {:ok, %ToolResults.SearchIndexUpdate{} = result}) do
    "#{pluralize(length(result.affected_blocks), "affected block", "affected blocks")}, " <>
      "#{pluralize(result.embedding_embedded_count, "embedding", "embeddings")} refreshed"
  end

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
      result = safe_callback(callback, args)
      notify.({:tool_finished, name, result})
      result
    end
  end

  defp safe_callback(callback, args) do
    callback.(args)
  rescue
    exception ->
      {:error, Exception.message(exception)}
  catch
    kind, reason ->
      {:error, "#{kind}: #{inspect(reason)}"}
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
        |> maybe_add_document_kind(args)
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

  defp list_spreadsheets_tool(args, spreadsheet_lister) do
    case spreadsheet_lister.() do
      {:ok, spreadsheets} ->
        query = arg(args, :query) |> normalize_optional_text()
        limit = args |> arg(:limit) |> clamp_spreadsheet_list_limit()
        spreadsheets = filter_spreadsheets(spreadsheets, query)
        total_spreadsheets = length(spreadsheets)

        total_sheets =
          Enum.sum(Enum.map(spreadsheets, fn spreadsheet -> length(spreadsheet.sheets) end))

        {spreadsheets, truncated?} =
          spreadsheets
          |> take_spreadsheet_sheets(limit)

        spreadsheets
        |> Enum.map(&spreadsheet_result/1)
        |> then(
          &%ToolResults.ListSpreadsheets{
            spreadsheets: &1,
            query: query,
            total_spreadsheets: total_spreadsheets,
            total_sheets: total_sheets,
            returned_spreadsheets: length(&1),
            returned_sheets:
              Enum.sum(Enum.map(&1, fn spreadsheet -> length(spreadsheet.sheets) end)),
            limit: limit,
            truncated?: truncated?
          }
        )
        |> rendered_result()
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, "could not list spreadsheets: #{inspect(reason)}"}
    end
  end

  defp query_spreadsheets_tool(args, spreadsheet_query) do
    sql = arg(args, :sql)
    intent = args |> arg(:intent) |> clean_intent()

    cond do
      not is_binary(sql) or String.trim(sql) == "" ->
        {:error, "sql is required"}

      is_nil(intent) ->
        {:error, "intent is required"}

      true ->
        case spreadsheet_query.(sql, limit: arg(args, :limit) || 50) do
          {:ok, result} ->
            %ToolResults.SpreadsheetQuery{
              intent: intent,
              sql: sql,
              result_id: Map.get(result, :result_id),
              result_iri: Map.get(result, :result_iri),
              result_file_iri: Map.get(result, :result_file_iri),
              row_count: Map.get(result, :row_count, length(result.rows)),
              offset: 0,
              limit: arg(args, :limit) || 50,
              columns: result.columns,
              rows: result.rows
            }
            |> rendered_result()
            |> then(&{:ok, &1})

          {:error, reason} ->
            {:error, "spreadsheet query failed: #{inspect(reason)}"}
        end
    end
  end

  defp clean_intent(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      intent -> ellipsize(intent, 120)
    end
  end

  defp clean_intent(_value), do: nil

  defp read_spreadsheet_query_result_tool(args, query_result_reader) do
    id = arg(args, :id)

    if is_binary(id) and String.trim(id) != "" do
      opts = [offset: arg(args, :offset) || 0, limit: arg(args, :limit) || 50]

      case query_result_reader.(id, opts) do
        {:ok, result} ->
          %ToolResults.SpreadsheetQueryResultPage{
            id: result.id,
            iri: result.iri,
            file_iri: result.file_iri,
            sql: result.sql,
            columns: result.columns,
            rows: result.rows,
            row_count: result.row_count,
            offset: result.offset,
            limit: result.limit
          }
          |> rendered_result()
          |> then(&{:ok, &1})

        {:error, reason} ->
          {:error, "could not read spreadsheet query result: #{inspect(reason)}"}
      end
    else
      {:error, "id is required"}
    end
  end

  defp search_spreadsheets_tool(args, spreadsheet_search) do
    query = arg(args, :query)

    if is_binary(query) and String.trim(query) != "" do
      case spreadsheet_search.(query, limit: arg(args, :limit) || 20) do
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

  defp tag_paragraphs_tool(args, paragraph_tagger) do
    block_ids = requested_blocks(args)
    tags = args |> arg(:tags) |> List.wrap()

    case paragraph_tagger.(block_ids, tags) do
      {:ok, %{block_ids: block_ids, tags: tags} = result} ->
        %ToolResults.ParagraphTags{
          block_ids: block_ids,
          tags: tags,
          tag_iris: Map.get(result, :tag_iris, []),
          statement_count: Map.get(result, :statement_count, length(block_ids) * length(tags))
        }
        |> rendered_result()
        |> then(&{:ok, &1})

      {:error, reason} when is_binary(reason) ->
        {:error, "could not tag paragraphs: #{reason}"}

      {:error, reason} ->
        {:error, "could not tag paragraphs: #{inspect(reason)}"}

      other ->
        {:error, "could not tag paragraphs: unexpected result #{inspect(other)}"}
    end
  end

  defp update_block_text_tool(args, block_text_replacer) do
    block = arg(args, :block)
    text = arg(args, :text)

    cond do
      not is_binary(block) or String.trim(block) == "" ->
        {:error, "block is required"}

      not is_binary(text) ->
        {:error, "text is required"}

      true ->
        case block_text_replacer.(block, text) do
          {:ok, result} ->
            result
            |> block_edit_result()
            |> rendered_result()
            |> then(&{:ok, &1})

          {:error, reason} when is_binary(reason) ->
            {:error, "could not update block text: #{reason}"}

          {:error, reason} ->
            {:error, "could not update block text: #{inspect(reason)}"}

          other ->
            {:error, "could not update block text: unexpected result #{inspect(other)}"}
        end
    end
  end

  defp move_block_tool(args, block_mover) do
    block = arg(args, :block)
    target = arg(args, :target)
    position = arg(args, :position)

    cond do
      not is_binary(block) or String.trim(block) == "" ->
        {:error, "block is required"}

      not is_binary(target) or String.trim(target) == "" ->
        {:error, "target is required"}

      not is_binary(position) or String.trim(position) == "" ->
        {:error, "position is required"}

      true ->
        case block_mover.(block, target, position) do
          {:ok, result} ->
            result
            |> block_edit_result()
            |> rendered_result()
            |> then(&{:ok, &1})

          {:error, reason} when is_binary(reason) ->
            {:error, "could not move block: #{reason}"}

          {:error, reason} ->
            {:error, "could not move block: #{inspect(reason)}"}

          other ->
            {:error, "could not move block: unexpected result #{inspect(other)}"}
        end
    end
  end

  defp insert_paragraph_tool(args, paragraph_inserter) do
    target = arg(args, :target)
    position = arg(args, :position)
    text = arg(args, :text)

    cond do
      not is_binary(target) or String.trim(target) == "" ->
        {:error, "target is required"}

      not is_binary(position) or String.trim(position) == "" ->
        {:error, "position is required"}

      not is_binary(text) ->
        {:error, "text is required"}

      true ->
        case paragraph_inserter.(target, position, text) do
          {:ok, result} ->
            result
            |> block_edit_result()
            |> rendered_result()
            |> then(&{:ok, &1})

          {:error, reason} when is_binary(reason) ->
            {:error, "could not insert paragraph: #{reason}"}

          {:error, reason} ->
            {:error, "could not insert paragraph: #{inspect(reason)}"}

          other ->
            {:error, "could not insert paragraph: unexpected result #{inspect(other)}"}
        end
    end
  end

  defp delete_block_tool(args, block_deleter) do
    block = arg(args, :block)

    cond do
      not is_binary(block) or String.trim(block) == "" ->
        {:error, "block is required"}

      true ->
        case block_deleter.(block) do
          {:ok, result} ->
            result
            |> block_edit_result()
            |> rendered_result()
            |> then(&{:ok, &1})

          {:error, reason} when is_binary(reason) ->
            {:error, "could not delete block: #{reason}"}

          {:error, reason} ->
            {:error, "could not delete block: #{inspect(reason)}"}

          other ->
            {:error, "could not delete block: unexpected result #{inspect(other)}"}
        end
    end
  end

  defp update_search_index_tool(args, search_index_updater) do
    block_ids = requested_blocks(args)

    if block_ids == [] do
      {:error, "blocks is required"}
    else
      case search_index_updater.(block_ids) do
        {:ok, result} ->
          result
          |> search_index_update_result(block_ids)
          |> rendered_result()
          |> then(&{:ok, &1})

        {:error, reason} when is_binary(reason) ->
          {:error, "could not update search indexes: #{reason}"}

        {:error, reason} ->
          {:error, "could not update search indexes: #{inspect(reason)}"}

        other ->
          {:error, "could not update search indexes: unexpected result #{inspect(other)}"}
      end
    end
  end

  defp block_edit_result(result) when is_map(result) do
    %ToolResults.BlockEdit{
      action: Map.get(result, :action),
      document_id: Map.get(result, :document_id),
      block_id: Map.get(result, :block_id),
      block_type: Map.get(result, :block_type),
      target_id: Map.get(result, :target_id),
      position: Map.get(result, :position),
      text: Map.get(result, :text),
      previous_text: Map.get(result, :previous_text),
      affected_blocks: Map.get(result, :affected_blocks, []),
      statement_count: Map.get(result, :statement_count, 0)
    }
  end

  defp search_index_update_result(result, requested_blocks) when is_map(result) do
    embedding = Map.get(result, :embedding, %{})
    search = Map.get(result, :search, %{})

    %ToolResults.SearchIndexUpdate{
      block_ids: Map.get(result, :block_ids, requested_blocks),
      affected_blocks: Map.get(result, :affected_blocks, []),
      embedding_target_count: Map.get(embedding, :target_count, 0),
      embedding_embedded_count: Map.get(embedding, :embedded_count, 0),
      embedding_skipped_count: Map.get(embedding, :skipped_count, 0),
      embedding_error_count: Map.get(embedding, :error_count, 0),
      embedding_status: Map.get(embedding, :status),
      search_count: Map.get(search, :count, 0),
      search_synced_at: Map.get(search, :synced_at)
    }
  end

  defp update_search_index_for_blocks(block_ids) do
    with {:ok, affected_blocks} <- affected_text_block_ids(block_ids),
         {:ok, rows} <- Sheaf.TextUnits.fetch_rows(),
         affected_iris = MapSet.new(Enum.map(affected_blocks, &(Id.iri(&1) |> to_string()))),
         embedding_units =
           rows
           |> Enum.filter(fn row ->
             iri = row |> Map.fetch!("iri") |> RDF.Term.value() |> to_string()
             MapSet.member?(affected_iris, iri)
           end)
           |> EmbeddingIndex.units_from_rows(),
         {:ok, embedding} <- EmbeddingIndex.sync_units(embedding_units),
         {:ok, search} <- SearchIndex.sync() do
      {:ok,
       %{
         block_ids: block_ids,
         affected_blocks: affected_blocks,
         embedding: embedding,
         search: search
       }}
    end
  end

  defp affected_text_block_ids(block_ids) do
    block_ids
    |> List.wrap()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn block_id, {:ok, affected} ->
      case DocumentEdits.text_block_ids([block_id]) do
        {:ok, []} ->
          {:cont, {:ok, MapSet.put(affected, block_id)}}

        {:ok, ids} ->
          {:cont, {:ok, Enum.reduce(ids, affected, &MapSet.put(&2, &1))}}

        {:error, reason} when is_binary(reason) ->
          if String.ends_with?(reason, " not found") do
            {:cont, {:ok, MapSet.put(affected, block_id)}}
          else
            {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, affected} -> {:ok, MapSet.to_list(affected)}
      error -> error
    end
  end

  defp maybe_add_scope(opts, args) do
    case arg(args, :document_id) do
      nil -> opts
      "" -> opts
      id -> Keyword.put(opts, :document_id, id)
    end
  end

  defp maybe_add_document_kind(opts, args) do
    case arg(args, :document_kind) do
      nil -> opts
      "" -> opts
      kind -> Keyword.put(opts, :document_kind, kind)
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

  defp filter_spreadsheets(spreadsheets, nil), do: spreadsheets

  defp filter_spreadsheets(spreadsheets, query) do
    terms = query |> String.downcase() |> search_terms()

    Enum.flat_map(spreadsheets, fn spreadsheet ->
      sheet_matches =
        Enum.filter(spreadsheet.sheets, fn sheet ->
          spreadsheet_match_text(spreadsheet, sheet)
          |> String.downcase()
          |> contains_all_terms?(terms)
        end)

      cond do
        sheet_matches != [] ->
          [Map.put(spreadsheet, :sheets, sheet_matches)]

        spreadsheet_match_text(spreadsheet, nil)
        |> String.downcase()
        |> contains_all_terms?(terms) ->
          [spreadsheet]

        true ->
          []
      end
    end)
  end

  defp spreadsheet_match_text(spreadsheet, nil) do
    Enum.join(
      [spreadsheet.id, spreadsheet.title, spreadsheet.path, Map.get(spreadsheet, :basename)],
      " "
    )
  end

  defp spreadsheet_match_text(spreadsheet, sheet) do
    columns =
      sheet.columns
      |> Enum.map(fn
        %{name: name, header: header} -> [name, header]
        %{"name" => name, "header" => header} -> [name, header]
        %{name: name} -> [name]
        %{"name" => name} -> [name]
        other -> [to_string(other)]
      end)

    [spreadsheet_match_text(spreadsheet, nil), sheet.name, sheet.table_name, columns]
    |> List.flatten()
    |> Enum.join(" ")
  end

  defp contains_all_terms?(_text, []), do: true
  defp contains_all_terms?(text, terms), do: Enum.all?(terms, &String.contains?(text, &1))

  defp take_spreadsheet_sheets(spreadsheets, limit) do
    {kept, _remaining} =
      Enum.reduce_while(spreadsheets, {[], limit}, fn spreadsheet, {kept, remaining} ->
        cond do
          remaining <= 0 ->
            {:halt, {kept, remaining}}

          length(spreadsheet.sheets) <= remaining ->
            {:cont, {[spreadsheet | kept], remaining - length(spreadsheet.sheets)}}

          true ->
            spreadsheet = Map.put(spreadsheet, :sheets, Enum.take(spreadsheet.sheets, remaining))
            {:halt, {[spreadsheet | kept], 0}}
        end
      end)

    kept = Enum.reverse(kept)
    returned_sheets = Enum.sum(Enum.map(kept, fn spreadsheet -> length(spreadsheet.sheets) end))

    total_sheets =
      Enum.sum(Enum.map(spreadsheets, fn spreadsheet -> length(spreadsheet.sheets) end))

    {kept, returned_sheets < total_sheets}
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
    catch
      :exit, _reason -> hits
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

  defp assistant_list_document?(%{kind: :transcript}), do: false
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

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp normalize_optional_text(_value), do: nil

  defp clamp_spreadsheet_list_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@spreadsheet_list_limit)

  defp clamp_spreadsheet_list_limit(_limit), do: @spreadsheet_list_limit

  defp search_terms(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(query)
    |> Enum.map(fn [term] -> term end)
    |> Enum.uniq()
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
