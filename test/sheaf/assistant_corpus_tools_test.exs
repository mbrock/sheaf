defmodule Sheaf.Assistant.CorpusToolsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Tool, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.{CorpusTools, ToolResultText, ToolResults}
  alias Sheaf.Id

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
    assert tool_text(result) =~ "Matching paragraph #EXACT1:"
    assert tool_text(result) =~ "Approximate matches"
    assert tool_text(result) =~ "Related excerpt #BLK123:"

    assert_received {:search_args, "plastic", opts}
    assert Keyword.get(opts, :limit) == 5
    assert Keyword.get(opts, :document_id) == "DOC123"
    assert Keyword.get(opts, :document_kind) == "literature"
    assert Keyword.get(opts, :kinds) == ["paragraph", "sourceHtml", "row"]
    assert Keyword.get(opts, :exact_limit) == 0

    assert_received {:exact_search_args, "plastic", exact_opts}
    assert Keyword.get(exact_opts, :limit) == 5
    assert Keyword.get(exact_opts, :document_id) == "DOC123"
    assert Keyword.get(exact_opts, :document_kind) == "literature"
    assert Keyword.get(exact_opts, :kinds) == ["paragraph", "sourceHtml", "row"]

    assert exact_hit == %ToolResults.SearchHit{
             document_id: "DOC123",
             document_title: "A paper",
             document_authors: [],
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
             block_id: "BLK123",
             kind: :extracted,
             text: "Plastic packaging.",
             source_page: 4,
             match: :both,
             score: 0.99
           }
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
             Tool.execute(tool, %{"id" => "RES111", "offset" => 10, "limit" => 2})

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
    assert tool_text(result) =~ "Intent: inspect a hugeint rendering edge case"
    assert tool_text(result) =~ "{0, 6}"
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

    assert {:ok, result} = Tool.execute(tool, %{"query" => "radio", "limit" => 1})

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

    assert_receive {:tool_finished, "write_note", {:ok, ^result}}

    assert %ToolResults.Note{id: "NOTE03", iri: iri} = sheaf_result(result)
    assert iri == to_string(Id.iri("NOTE03"))
    assert tool_text(result) =~ "NOTE SAVED #NOTE03"
  end

  test "write_note tool can be omitted" do
    tools = CorpusTools.tools(include_notes?: false)

    refute Enum.any?(tools, &(&1.name == "write_note"))
    assert Enum.any?(tools, &(&1.name == "search_text"))
  end

  test "read tool accepts only a blocks list and optional expansion" do
    tools = CorpusTools.tools(include_notes?: false)
    tool = Enum.find(tools, &(&1.name == "read"))

    refute Enum.any?(tools, &(&1.name == "get_block"))

    assert [
             type: {:list, :string},
             required: true,
             doc:
               "Block ids to read, without leading #. Blocks may belong to different documents."
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
            text: "A paragraph."
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
    assert text =~ "PARAGRAPH #PAR001"
    assert text =~ "EXCERPT #EXT001 p. 12"
    assert text =~ "A paragraph."
    assert text =~ "An excerpt."
  end

  test "selected block turn context omits the repeated document title" do
    text =
      ToolResultText.selected_block_text(%ToolResults.Block{
        document_id: "ABC123",
        id: "DEF456",
        type: :paragraph,
        text: "Selected paragraph text.",
        ancestry: [
          %ToolResults.ContextEntry{id: "ABC123", type: :document, title: "Draft chapter"},
          %ToolResults.ContextEntry{id: "SEC001", type: :section, title: "A section"},
          %ToolResults.ContextEntry{id: "DEF456", type: :paragraph, title: "paragraph"}
        ]
      })

    assert text =~ "The user has selected paragraph #DEF456:"
    assert text =~ "#SEC001 A section"
    assert text =~ "Selected paragraph text."
    refute text =~ "Draft chapter"
  end

  defp sheaf_result(%ToolResult{metadata: %{sheaf_result: result}}), do: result

  defp tool_text(%ToolResult{content: [%ContentPart{text: text} | _]}), do: text
end
