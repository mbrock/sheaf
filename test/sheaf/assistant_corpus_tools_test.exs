defmodule Sheaf.Assistant.CorpusToolsTest do
  use ExUnit.Case, async: false

  alias ReqLLM.{Tool, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.{CorpusTools, Notes, ToolResultText, ToolResults}
  alias Sheaf.Id
  alias Sheaf.NS.{AS, DOC}

  test "import tool exposes one bounded action surface and reports progress" do
    test_pid = self()

    importer = fn args, opts ->
      opts[:notify].("Submitting FILE01 to Datalab")
      send(test_pid, {:import_args, args})
      {:ok, %{action: "stage", run_id: "RUN001"}}
    end

    tools =
      CorpusTools.tools(tool_set: :import, document_importer: importer)

    tool = Enum.find(tools, &(&1.name == "document_import"))
    assert tool

    assert {:ok, %ToolResult{}} =
             Tool.execute(tool, %{
               "action" => "stage",
               "urls" => ["https://example.com/paper.pdf"]
             })

    assert_received {:import_args,
                     %{
                       "action" => "stage",
                       "urls" => ["https://example.com/paper.pdf"]
                     }}

    assert Enum.any?(tools, &(&1.name == "update_block_text"))
    assert Enum.any?(tools, &(&1.name == "unwrap_section"))
    assert Enum.any?(tools, &(&1.name == "web_search"))
    assert Enum.any?(tools, &(&1.name == "update_document_metadata"))
  end

  test "import web search renders answer text and cited sources" do
    tools =
      CorpusTools.tools(
        tool_set: :import,
        web_searcher: fn "find the DOI" ->
          {:ok,
           %{
             text: "The DOI is 10.1/example.",
             sources: [
               %{title: "DOI record", url: "https://doi.org/10.1/example"}
             ]
           }}
        end
      )

    tool = Enum.find(tools, &(&1.name == "web_search"))

    assert {:ok, result} = Tool.execute(tool, %{"query" => "find the DOI"})

    assert %ToolResults.WebSearch{query: "find the DOI"} =
             sheaf_result(result)

    assert tool_text(result) =~ "WEB SEARCH RESULTS"
    assert tool_text(result) =~ "The DOI is 10.1/example."
    assert tool_text(result) =~ "https://doi.org/10.1/example"
  end

  test "image tool saves a standalone generated image" do
    test_pid = self()

    tools =
      CorpusTools.tools(
        image_generator: fn prompt ->
          send(test_pid, {:image_generation, prompt})

          {:ok,
           %{
             image_id: "IMG123",
             path: "/images/IMG123",
             prompt: prompt
           }}
        end
      )

    tool = Enum.find(tools, &(&1.name == "generate_image"))

    assert {:ok, result} =
             Tool.execute(tool, %{
               "prompt" =>
                 "An archipelago of paper islands under a copper moon"
             })

    assert_received {:image_generation, prompt}
    assert prompt =~ "paper islands"

    assert %ToolResults.GeneratedImage{
             image_id: "IMG123",
             path: "/images/IMG123"
           } = sheaf_result(result)

    assert tool_text(result) =~ "GENERATED IMAGE #IMG123"
  end

  test "import metadata tool applies verified document fields" do
    test_pid = self()

    tools =
      CorpusTools.tools(
        tool_set: :import,
        metadata_updater: fn document_id, attrs ->
          send(test_pid, {:metadata_update, document_id, attrs})

          {:ok,
           %{
             document_id: document_id,
             expression: RDF.iri("https://example.com/expression"),
             fields: [:title, :authors, :doi]
           }}
        end
      )

    tool = Enum.find(tools, &(&1.name == "update_document_metadata"))

    assert {:ok, result} =
             Tool.execute(tool, %{
               "document_id" => "GY93FG",
               "title" => "Mountain Trail Formation",
               "authors" => ["S. J. Gilks", "J. P. Hague"],
               "doi" => "10.1000/example",
               "folder" => "Trail systems",
               "micro_abstract" =>
                 "Explains how paths emerge from repeated movement."
             })

    assert_receive {:metadata_update, "GY93FG", attrs}
    assert attrs[:title] == "Mountain Trail Formation"
    assert attrs[:folder] == "Trail systems"

    assert attrs[:micro_abstract] ==
             "Explains how paths emerge from repeated movement."

    assert %ToolResults.DocumentMetadataUpdate{document_id: "GY93FG"} =
             sheaf_result(result)

    assert tool_text(result) =~ "title, authors, doi"
  end

  test "search_text tool uses embedding index search and preserves assistant hit shape" do
    test_pid = self()

    search = fn query, opts ->
      send(test_pid, {:search_args, query, opts})

      {:ok,
       [
         %{
           iri: to_string(Id.iri("BLK123")),
           doc_iri: to_string(Id.iri("DOC123")),
           doc_title: "A paper",
           doc_status: "mikael",
           kind: "sourceHtml",
           text: "<p>Plastic packaging.</p>",
           source_page: 4,
           match: :both,
           score: 0.99
         }
       ]}
    end

    exact_search = fn query, opts ->
      send(test_pid, {:exact_search_args, query, opts})

      {:ok,
       [
         %{
           iri: to_string(Id.iri("EXACT1")),
           doc_iri: to_string(Id.iri("DOC123")),
           doc_title: "A paper",
           doc_status: "draft",
           kind: "paragraph",
           text: "Plastic appears exactly here.",
           source_page: nil,
           match: :exact,
           score: 0.95
         }
       ]}
    end

    tools = CorpusTools.tools(search: search, exact_search: exact_search)
    tool = Enum.find(tools, &(&1.name == "search_text"))

    assert {:ok, %ToolResult{} = result} =
             Tool.execute(tool, %{
               "query" => "plastic",
               "document_id" => "DOC123",
               "document_kind" => "literature",
               "limit" => 5
             })

    assert %ToolResults.SearchResults{
             exact_results: [exact_hit],
             approximate_results: [hit]
           } = sheaf_result(result)

    assert tool_text(result) =~ "Exact matches"
    assert tool_text(result) =~ "Source: A paper [draft] (#DOC123)"
    assert tool_text(result) =~ "Matching paragraph #EXACT1:"
    assert tool_text(result) =~ "Approximate matches"
    assert tool_text(result) =~ "Source: A paper [MIKAEL] (#DOC123)"
    assert tool_text(result) =~ "Related excerpt #BLK123:"

    assert_received {:search_args, "plastic", opts}
    assert Keyword.get(opts, :limit) == 5
    assert Keyword.get(opts, :document_id) == "DOC123"
    assert Keyword.get(opts, :document_kind) == "literature"

    assert Keyword.get(opts, :kinds) == [
             "paragraph",
             "sourceHtml",
             "row",
             "note",
             "sourceFile"
           ]

    assert Keyword.get(opts, :exact_limit) == 0

    assert_received {:exact_search_args, "plastic", exact_opts}
    assert Keyword.get(exact_opts, :limit) == 5
    assert Keyword.get(exact_opts, :document_id) == "DOC123"
    assert Keyword.get(exact_opts, :document_kind) == "literature"

    assert Keyword.get(exact_opts, :kinds) == [
             "paragraph",
             "sourceHtml",
             "row",
             "note",
             "sourceFile"
           ]

    assert exact_hit == %ToolResults.SearchHit{
             document_id: "DOC123",
             document_title: "A paper",
             document_authors: [],
             document_status: "draft",
             block_id: "EXACT1",
             kind: :paragraph,
             text: "Plastic appears exactly here.",
             source_page: nil,
             match: :exact,
             score: 0.95
           }

    assert hit == %ToolResults.SearchHit{
             document_id: "DOC123",
             document_title: "A paper",
             document_authors: [],
             document_status: "mikael",
             block_id: "BLK123",
             kind: :extracted,
             text: "Plastic packaging.",
             source_page: 4,
             match: :both,
             score: 0.99
           }
  end

  test "list document text renders all document statuses" do
    text =
      ToolResultText.to_text(%ToolResults.ListDocuments{
        folders: ["Landscape", "Trail systems"],
        documents: [
          %ToolResults.DocumentSummary{
            id: "DOC111",
            kind: :thesis,
            title: "Same thesis",
            authors: ["Ieva Lange"],
            year: "2026",
            status: "mikael",
            micro_abstract: "A compact account of the thesis contribution.",
            workspace_owner_authored?: true
          },
          %ToolResults.DocumentSummary{
            id: "DOC222",
            kind: :thesis,
            title: "Same thesis",
            authors: ["Ieva Lange"],
            year: "2026",
            status: "draft",
            workspace_owner_authored?: true
          }
        ]
      })

    assert text =~ "- #DOC111 Same thesis [MIKAEL] - 2026 | Ieva Lange"
    assert text =~ "- #DOC222 Same thesis [draft] - 2026 | Ieva Lange"
    assert text =~ "FOLDERS\n- Landscape\n- Trail systems"
    assert text =~ "Unfiled (2)"

    assert text =~
             "Micro abstract: A compact account of the thesis contribution."
  end

  test "sidecar spreadsheet tools are hidden when no sidecar sheets are imported" do
    tools =
      CorpusTools.tools(
        include_notes?: false,
        spreadsheet_lister: fn -> {:ok, []} end
      )

    tool_names = Enum.map(tools, & &1.name)

    assert "search_text" in tool_names
    refute "list_spreadsheets" in tool_names
    refute "query_spreadsheets" in tool_names
    refute "read_spreadsheet_query_result" in tool_names
    refute "search_spreadsheets" in tool_names
  end

  test "sidecar spreadsheet tools are shown when sidecar sheets are imported" do
    tools =
      CorpusTools.tools(
        include_notes?: false,
        spreadsheet_lister: fn -> {:ok, [%{id: 1}]} end
      )

    tool_names = Enum.map(tools, & &1.name)

    assert "list_spreadsheets" in tool_names
    assert "query_spreadsheets" in tool_names
    assert "read_spreadsheet_query_result" in tool_names
    assert "search_spreadsheets" in tool_names
  end

  test "read_spreadsheet_query_result returns a saved result page" do
    tools =
      CorpusTools.tools(
        include_notes?: false,
        spreadsheet_lister: fn -> {:ok, [%{id: 1}]} end,
        query_result_reader: fn id, opts ->
          assert id == "RES111"
          assert opts[:offset] == 10
          assert opts[:limit] == 2

          {:ok,
           %{
             id: "RES111",
             iri: "https://example.com/sheaf/RES111",
             file_iri: "https://example.com/sheaf/FILE11",
             sql: "SELECT name FROM example",
             columns: ["name"],
             rows: [%{"name" => "alpha"}, %{"name" => "beta"}],
             row_count: 42,
             offset: 10,
             limit: 2
           }}
        end
      )

    tool = Enum.find(tools, &(&1.name == "read_spreadsheet_query_result"))

    assert {:ok, result} =
             Tool.execute(tool, %{
               "id" => "RES111",
               "offset" => 10,
               "limit" => 2
             })

    assert %ToolResults.SpreadsheetQueryResultPage{
             id: "RES111",
             rows: [%{"name" => "alpha"}, %{"name" => "beta"}],
             row_count: 42,
             offset: 10
           } = sheaf_result(result)

    assert tool_text(result) =~ "SPREADSHEET QUERY RESULT"
    assert tool_text(result) =~ "name\nalpha\nbeta"
  end

  test "query_spreadsheets renders non-scalar DuckDB values in TSV" do
    tools =
      CorpusTools.tools(
        include_notes?: false,
        spreadsheet_lister: fn -> {:ok, [%{id: "xl_a", sheets: []}]} end,
        spreadsheet_query: fn sql, opts ->
          assert sql == "SELECT span FROM example"
          assert opts[:limit] == 500

          {:ok,
           %{
             columns: ["span"],
             rows: [%{"span" => {0, 6}}],
             row_count: 1,
             result_id: nil,
             result_iri: nil,
             result_file_iri: nil
           }}
        end
      )

    tool = Enum.find(tools, &(&1.name == "query_spreadsheets"))
    assert tool.parameter_schema[:intent][:required]
    assert tool.parameter_schema[:limit][:doc] =~ "full SQL result is saved"

    assert {:ok, result} =
             Tool.execute(tool, %{
               "intent" => "inspect a hugeint rendering edge case",
               "sql" => "SELECT span FROM example",
               "limit" => 500
             })

    assert tool_text(result) =~ "Format: TSV"

    assert tool_text(result) =~
             "Intent: inspect a hugeint rendering edge case"

    assert tool_text(result) =~ "{0, 6}"
  end

  test "present_spreadsheet_query_result reads a saved result for table presentation" do
    tools =
      CorpusTools.tools(
        include_notes?: false,
        spreadsheet_lister: fn -> {:ok, [%{id: "xl_a", sheets: []}]} end,
        query_result_reader: fn id, opts ->
          assert id == "QRY123"
          assert opts[:offset] == 5
          assert opts[:limit] == 25

          {:ok,
           %{
             id: "QRY123",
             iri: "https://sheaf.less.rest/QRY123",
             file_iri: "file:///tmp/query.parquet",
             sql: "SELECT buyer_type, tenders FROM summary",
             columns: ["buyer_type", "tenders"],
             rows: [%{"buyer_type" => "agency", "tenders" => 12}],
             row_count: 42,
             offset: 5,
             limit: 25
           }}
        end
      )

    tool = Enum.find(tools, &(&1.name == "present_spreadsheet_query_result"))
    assert tool.parameter_schema[:title][:required]

    assert {:list, {:map, _column_schema}} =
             tool.parameter_schema[:columns][:type]

    assert {:ok, result} =
             Tool.execute(tool, %{
               "id" => "QRY123",
               "title" => "Tender counts",
               "description" => "Grouped by buyer type.",
               "offset" => 5,
               "limit" => 25,
               "columns" => [
                 %{
                   "name" => "buyer_type",
                   "label" => "Buyer type",
                   "type" => "text"
                 },
                 %{"name" => "missing", "label" => "Ignored"}
               ]
             })

    assert tool_text(result) =~ "PRESENTED SPREADSHEET QUERY RESULT"

    assert %ToolResults.PresentedSpreadsheetQueryResult{} =
             presented = result.metadata.sheaf_result

    assert presented.title == "Tender counts"
    assert presented.description == "Grouped by buyer type."

    assert presented.column_specs == [
             %{
               name: "buyer_type",
               label: "Buyer type",
               type: "text",
               unit: nil
             }
           ]

    assert presented.rows == [%{"buyer_type" => "agency", "tenders" => 12}]
  end

  test "list_spreadsheets can filter and limit sheet metadata" do
    spreadsheets = [
      %{
        id: "xl_a",
        title: "alpha.xlsx",
        path: "/tmp/alpha.xlsx",
        sheets: [
          %{
            spreadsheet_id: "xl_a",
            name: "Summary",
            table_name: "xlsx_alpha_1",
            row_count: 2,
            col_count: 1,
            columns: [%{name: "name", header: "name"}]
          },
          %{
            spreadsheet_id: "xl_a",
            name: "Radio",
            table_name: "xlsx_alpha_2",
            row_count: 5,
            col_count: 1,
            columns: [%{name: "radio_station", header: "radio_station"}]
          }
        ]
      },
      %{
        id: "xl_b",
        title: "beta.xlsx",
        path: "/tmp/beta.xlsx",
        sheets: [
          %{
            spreadsheet_id: "xl_b",
            name: "Costs",
            table_name: "xlsx_beta_1",
            row_count: 3,
            col_count: 1,
            columns: [%{name: "amount", header: "amount"}]
          }
        ]
      }
    ]

    tools =
      CorpusTools.tools(
        include_notes?: false,
        spreadsheet_lister: fn -> {:ok, spreadsheets} end
      )

    tool = Enum.find(tools, &(&1.name == "list_spreadsheets"))

    assert tool.parameter_schema[:query]
    assert tool.parameter_schema[:limit]

    assert {:ok, result} =
             Tool.execute(tool, %{"query" => "radio", "limit" => 1})

    assert %ToolResults.ListSpreadsheets{
             query: "radio",
             total_spreadsheets: 1,
             total_sheets: 1,
             returned_spreadsheets: 1,
             returned_sheets: 1,
             truncated?: false,
             spreadsheets: [spreadsheet]
           } = sheaf_result(result)

    assert [%ToolResults.SpreadsheetSheet{name: "Radio"}] = spreadsheet.sheets
    assert tool_text(result) =~ "Showing 1 spreadsheets and 1 sheets."
    assert tool_text(result) =~ "xlsx_alpha_2"
    refute tool_text(result) =~ "xlsx_beta_1"
  end

  test "write_note tool persists through the configured note writer and emits events" do
    test_pid = self()
    agent = Id.iri("AGENT3")
    session = Id.iri("SESS03")

    note_writer = fn attrs ->
      send(test_pid, {:note_attrs, attrs})
      {:ok, Id.iri("NOTE03")}
    end

    tools =
      CorpusTools.tools(
        notify: fn event -> send(test_pid, event) end,
        note_context: %{
          agent_iri: agent,
          agent_label: "Research bot",
          session_iri: session,
          session_label: "Reading session"
        },
        note_writer: note_writer
      )

    tool = Enum.find(tools, &(&1.name == "write_note"))

    assert {:ok, result} =
             Tool.execute(tool, %{
               "text" => "This relates #ABC123 to the introduction.",
               "block_ids" => ["ABC123"],
               "title" => "A note"
             })

    assert_receive {:tool_started, "write_note", %{text: _text}}

    assert_receive {:note_attrs,
                    %{
                      text: "This relates #ABC123 to the introduction.",
                      title: "A note",
                      block_ids: ["ABC123"],
                      agent_iri: ^agent,
                      session_iri: ^session
                    }}

    assert_receive {:tool_finished, "write_note", %{text: _text},
                    {:ok, ^result}}

    assert %ToolResults.Note{id: "NOTE03", iri: iri} = sheaf_result(result)
    assert iri == to_string(Id.iri("NOTE03"))
    assert tool_text(result) =~ "NOTE SAVED #NOTE03"
  end

  test "tag_paragraphs tool attaches writing tags to multiple paragraphs" do
    test_pid = self()

    paragraph_tagger = fn block_ids, tags ->
      send(test_pid, {:tag_args, block_ids, tags})

      {:ok,
       %{
         block_ids: block_ids,
         tags: tags,
         tag_iris: Enum.map(tags, &"https://less.rest/sheaf/#{&1}"),
         statement_count: length(block_ids) * length(tags)
       }}
    end

    tools =
      CorpusTools.tools(
        include_notes?: false,
        paragraph_tagger: paragraph_tagger
      )

    tool = Enum.find(tools, &(&1.name == "tag_paragraphs"))

    assert [
             type:
               {:list,
                {:in,
                 [
                   "placeholder",
                   "needs_evidence",
                   "needs_revision",
                   "fragment"
                 ]}},
             required: true,
             doc: _doc
           ] = tool.parameter_schema[:tags]

    assert {:ok, result} =
             Tool.execute(tool, %{
               "blocks" => ["PAR111", "PAR222"],
               "tags" => ["needs_evidence", "fragment"]
             })

    assert_receive {:tag_args, ["PAR111", "PAR222"],
                    ["needs_evidence", "fragment"]}

    assert %ToolResults.ParagraphTags{
             block_ids: ["PAR111", "PAR222"],
             tags: ["needs_evidence", "fragment"],
             statement_count: 4
           } = sheaf_result(result)

    assert tool_text(result) =~ "PARAGRAPH TAGS ATTACHED"
    assert tool_text(result) =~ "Blocks: #PAR111, #PAR222"
    assert tool_text(result) =~ "Tags: needs_evidence, fragment"
  end

  test "write_note tool can be omitted" do
    tools = CorpusTools.tools(include_notes?: false)

    refute Enum.any?(tools, &(&1.name == "write_note"))
    assert Enum.any?(tools, &(&1.name == "search_text"))
  end

  test "unified assistant tool sets separate safe capabilities from changes" do
    safe_names =
      CorpusTools.tools(tool_set: :assistant)
      |> Enum.map(& &1.name)

    assert "list_documents" in safe_names
    assert "read" in safe_names
    assert "search_text" in safe_names
    assert "web_search" in safe_names
    assert "write_note" in safe_names
    refute "tag_paragraphs" in safe_names
    refute "generate_image" in safe_names
    refute "update_block_text" in safe_names
    refute "document_import" in safe_names

    change_names =
      CorpusTools.tools(tool_set: :assistant_changes)
      |> Enum.map(& &1.name)

    assert "tag_paragraphs" in change_names
    assert "update_block_text" in change_names
    assert "document_import" in change_names
    assert "update_document_metadata" in change_names
    assert "generate_image" in change_names
    assert "web_search" in change_names
    assert "write_note" in change_names
  end

  test "edit tool set exposes document mutation tools and visible search index refresh" do
    test_pid = self()

    tools =
      CorpusTools.tools(
        tool_set: :edit,
        include_notes?: true,
        block_text_replacer: fn block, text ->
          send(test_pid, {:replace, block, text})

          {:ok,
           %{
             action: :replace_paragraph_text,
             document_id: "DOC111",
             block_id: block,
             block_type: :paragraph,
             text: text,
             affected_blocks: [block],
             statement_count: 6
           }}
        end,
        block_deleter: fn block ->
          send(test_pid, {:delete, block})

          {:ok,
           %{
             action: :delete_block,
             document_id: "DOC111",
             block_id: block,
             affected_blocks: [block],
             statement_count: 8
           }}
        end,
        search_index_updater: fn blocks ->
          send(test_pid, {:index, blocks})

          {:ok,
           %{
             block_ids: blocks,
             affected_blocks: blocks,
             embedding: %{
               target_count: length(blocks),
               embedded_count: 1,
               skipped_count: 0
             },
             search: %{count: 12, synced_at: "2026-05-04T12:00:00Z"}
           }}
        end
      )

    tool_names = Enum.map(tools, & &1.name)

    assert "update_block_text" in tool_names
    assert "move_block" in tool_names
    assert "insert_paragraph" in tool_names
    assert "delete_block" in tool_names
    assert "unwrap_section" in tool_names
    assert "update_search_index" in tool_names
    refute "write_note" in tool_names
    refute "query_spreadsheets" in tool_names

    update_tool = Enum.find(tools, &(&1.name == "update_block_text"))

    assert {:ok, update_result} =
             Tool.execute(update_tool, %{
               "block" => "PAR111",
               "text" => "New."
             })

    assert_receive {:replace, "PAR111", "New."}

    assert %ToolResults.BlockEdit{block_id: "PAR111", statement_count: 6} =
             sheaf_result(update_result)

    assert tool_text(update_result) =~ "BLOCK EDIT APPLIED"

    delete_tool = Enum.find(tools, &(&1.name == "delete_block"))

    assert {:ok, delete_result} =
             Tool.execute(delete_tool, %{"block" => "PAR111"})

    assert_receive {:delete, "PAR111"}

    assert %ToolResults.BlockEdit{
             action: :delete_block,
             block_id: "PAR111",
             affected_blocks: ["PAR111"],
             statement_count: 8
           } = sheaf_result(delete_result)

    index_tool = Enum.find(tools, &(&1.name == "update_search_index"))

    assert {:ok, index_result} =
             Tool.execute(index_tool, %{"blocks" => ["PAR111"]})

    assert_receive {:index, ["PAR111"]}

    assert %ToolResults.SearchIndexUpdate{
             affected_blocks: ["PAR111"],
             embedding_target_count: 1,
             search_count: 12
           } = sheaf_result(index_result)

    assert tool_text(index_result) =~ "SEARCH INDEX UPDATED"
  end

  test "read tool accepts only a blocks list and optional expansion" do
    tools = CorpusTools.tools(include_notes?: false)
    tool = Enum.find(tools, &(&1.name == "read"))

    refute Enum.any?(tools, &(&1.name == "get_block"))

    assert [
             type: {:list, :string},
             required: true,
             doc:
               "Sheaf resource handles to read. Use ids without leading # for ordinary documents and blocks; use the complete IRI for a source-file #content block."
           ] = tool.parameter_schema[:blocks]

    assert [
             type: :boolean,
             default: false,
             doc:
               "When true, sections and document roots are expanded into their full descendant contents."
           ] = tool.parameter_schema[:expand]

    refute Keyword.has_key?(tool.parameter_schema, :document_id)
    refute Keyword.has_key?(tool.parameter_schema, :block_id)
    refute Keyword.has_key?(tool.parameter_schema, :block_ids)

    assert {:error, %{tag: :parameter_validation}} = Tool.execute(tool, %{})
  end

  test "read tool can read a research note resource" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-corpus-tools-read-note-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})

    assert {:ok, _note} =
             Notes.write(
               %{
                 text:
                   "String figures ask Sheaf to carry citation with care.",
                 title: "String figures and citation care",
                 agent_id: "AGT999",
                 session_id: "SES999"
               },
               note_iri: Id.iri("NOTE99"),
               published_at: ~U[2026-05-06 12:00:00Z]
             )

    tool =
      CorpusTools.tools(include_notes?: false)
      |> Enum.find(&(&1.name == "read"))

    assert {:ok, %ToolResult{} = result} =
             Tool.execute(tool, %{"blocks" => ["NOTE99"]})

    assert %ToolResults.Block{
             document_id: "NOTE99",
             id: "NOTE99",
             type: :note,
             title: "String figures and citation care",
             text: "String figures ask Sheaf to carry citation with care."
           } = sheaf_result(result)

    assert tool_text(result) =~ "RESEARCH NOTE #NOTE99"

    assert tool_text(result) =~
             "String figures ask Sheaf to carry citation with care."
  end

  test "source-file search is compact and its content IRI is readable" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-corpus-tools-source-file-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})

    source_file = RDF.iri("https://sheaf.less.rest/REPO/source-files/abc")
    block = RDF.iri(to_string(source_file) <> "#content")

    text =
      Enum.map_join(1..200, "\n", fn line ->
        "line #{line}: renderer source implementation"
      end)

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {source_file, RDF.type(), DOC.GitSourceFile},
                   {source_file, DOC.sourcePath(), "src/renderer.cc"},
                   {source_file, DOC.hasSourceFileBlock(), block},
                   {block, RDF.type(), DOC.SourceFileBlock},
                   {block, DOC.inSourceFile(), source_file},
                   {block, DOC.text(), text}
                 ],
                 name: RDF.iri("https://sheaf.less.rest/REPO/text")
               )
             )

    result_shape = %{
      iri: to_string(block),
      doc_iri: to_string(source_file),
      doc_title: "src/renderer.cc",
      kind: "sourceFile",
      text: text,
      match_text: "line 120: renderer source implementation",
      source_page: nil,
      match: :semantic,
      score: 0.91
    }

    tools =
      CorpusTools.tools(
        include_notes?: false,
        exact_search: fn _query, _opts -> {:ok, []} end,
        search: fn _query, _opts -> {:ok, [result_shape]} end
      )

    search = Enum.find(tools, &(&1.name == "search_text"))

    assert {:ok, %ToolResult{} = search_result} =
             Tool.execute(search, %{"query" => "renderer"})

    assert %ToolResults.SearchResults{
             approximate_results: [
               %ToolResults.SearchHit{
                 kind: :sourceFile,
                 resource_iri: resource_iri,
                 byte_size: byte_size,
                 line_count: 200,
                 text: excerpt
               }
             ]
           } = sheaf_result(search_result)

    assert resource_iri == to_string(block)
    assert byte_size == byte_size(text)
    assert excerpt == "line 120: renderer source implementation"
    refute tool_text(search_result) =~ text
    assert tool_text(search_result) =~ "Size: #{byte_size} bytes, 200 lines"
    assert tool_text(search_result) =~ ~s(read blocks=["#{block}"])

    fallback_tools =
      CorpusTools.tools(
        include_notes?: false,
        exact_search: fn _query, _opts -> {:ok, []} end,
        search: fn _query, _opts ->
          {:ok, [%{result_shape | match_text: nil}]}
        end
      )

    fallback_search = Enum.find(fallback_tools, &(&1.name == "search_text"))

    assert {:ok, %ToolResult{} = fallback_result} =
             Tool.execute(fallback_search, %{"query" => "line 120"})

    assert %ToolResults.SearchResults{
             approximate_results: [
               %ToolResults.SearchHit{text: fallback_excerpt}
             ]
           } = sheaf_result(fallback_result)

    assert fallback_excerpt =~ "line 120: renderer source implementation"
    refute fallback_excerpt == text

    read = Enum.find(tools, &(&1.name == "read"))

    assert {:ok, %ToolResult{} = read_result} =
             Tool.execute(read, %{"blocks" => [to_string(block)]})

    assert %ToolResults.Block{
             type: :source_file,
             resource_iri: ^resource_iri,
             title: "src/renderer.cc",
             byte_size: ^byte_size,
             line_count: 200,
             text: ^text
           } = sheaf_result(read_result)

    assert tool_text(read_result) =~ text
  end

  test "list_notes returns persisted notes newest first with mentions" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-corpus-tools-list-notes-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})

    assert {:ok, _note} =
             Notes.write(
               %{
                 text: "A durable observation linked to #BLOCK1.",
                 title: "Linked observation",
                 block_ids: ["BLOCK1"],
                 agent_id: "AGT999",
                 session_id: "SES999"
               },
               note_iri: Id.iri("NOTE98"),
               published_at: ~U[2026-05-07 12:00:00Z]
             )

    tool =
      CorpusTools.tools(include_notes?: false)
      |> Enum.find(&(&1.name == "list_notes"))

    assert {:ok, %ToolResult{} = result} = Tool.execute(tool, %{})

    assert %ToolResults.ListNotes{
             notes: [
               %ToolResults.ResearchNoteSummary{
                 id: "NOTE98",
                 title: "Linked observation",
                 text: "A durable observation linked to #BLOCK1.",
                 published: "2026-05-07T12:00:00Z",
                 mentions: ["BLOCK1"]
               }
             ]
           } = sheaf_result(result)

    assert tool_text(result) =~ "RESEARCH NOTES"
    assert tool_text(result) =~ "#NOTE98 Linked observation"
    assert tool_text(result) =~ "Mentions: #BLOCK1"
  end

  test "expanded read text keeps block tags on every rendered block" do
    text =
      ToolResultText.to_text(%ToolResults.Blocks{
        expanded?: true,
        blocks: [
          %ToolResults.Block{
            id: "SEC001",
            type: :section,
            title: "A section"
          },
          %ToolResults.Block{
            id: "PAR001",
            type: :paragraph,
            text: "A paragraph.",
            tags: [%{name: "needs_revision", label: "needs revision"}]
          },
          %ToolResults.Block{
            id: "EXT001",
            type: :extracted,
            text: "An excerpt.",
            source: %ToolResults.Source{page: 12}
          }
        ]
      })

    assert text =~ "SECTION #SEC001 A section"
    assert text =~ "PARAGRAPH #PAR001 [tags: needs_revision]"
    assert text =~ "EXCERPT #EXT001 p. 12"
    assert text =~ "A paragraph."
    assert text =~ "An excerpt."
  end

  test "read tool includes writing tags from the workspace graph" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-corpus-tools-read-tags-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})

    document = Id.iri("RCT001")
    list = Id.iri("RCTL01")
    paragraph = Id.iri("RCTP01")
    revision = Id.iri("RCTR01")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, DOC.children(), list},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.paragraph(), revision},
          {revision, RDF.type(), DOC.Paragraph},
          {revision, DOC.text(), RDF.literal("This needs another pass.")}
        ],
        name: document
      )
      |> then(fn graph ->
        RDF.list([paragraph], graph: graph, head: list).graph
      end)

    workspace =
      RDF.Graph.new(
        [
          {paragraph, AS.tag(), RDF.iri(DOC.NeedsRevisionTag)}
        ],
        name: Sheaf.Workspace.graph()
      )

    assert :ok = Sheaf.Repo.assert(graph)
    assert :ok = Sheaf.Repo.assert(workspace)

    tool =
      CorpusTools.tools(include_notes?: false)
      |> Enum.find(&(&1.name == "read"))

    assert {:ok, %ToolResult{} = result} =
             Tool.execute(tool, %{"blocks" => ["RCT001"], "expand" => true})

    assert tool_text(result) =~ "PARAGRAPH #RCTP01 [tags: needs_revision]"
    assert tool_text(result) =~ "This needs another pass."
  end

  test "selected block turn context omits the repeated document title" do
    text =
      ToolResultText.selected_block_text(%ToolResults.Block{
        document_id: "ABC123",
        id: "DEF456",
        type: :paragraph,
        text: "Selected paragraph text.",
        tags: [%{name: "fragment", label: "fragment"}],
        ancestry: [
          %ToolResults.ContextEntry{
            id: "ABC123",
            type: :document,
            title: "Draft chapter"
          },
          %ToolResults.ContextEntry{
            id: "SEC001",
            type: :section,
            title: "A section"
          },
          %ToolResults.ContextEntry{
            id: "DEF456",
            type: :paragraph,
            title: "paragraph"
          }
        ]
      })

    assert text =~ "The user has selected paragraph #DEF456:"
    assert text =~ "#SEC001 A section"
    assert text =~ "Tags: fragment"
    assert text =~ "Selected paragraph text."
    refute text =~ "Draft chapter"
  end

  defp sheaf_result(%ToolResult{metadata: %{sheaf_result: result}}),
    do: result

  defp tool_text(%ToolResult{content: [%ContentPart{text: text} | _]}),
    do: text
end
