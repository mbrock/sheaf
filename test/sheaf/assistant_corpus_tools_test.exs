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
    assert "search_spreadsheets" in tool_names
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
