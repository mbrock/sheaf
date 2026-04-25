defmodule Sheaf.Assistant.CorpusToolsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Tool
  alias Sheaf.Assistant.CorpusTools
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

    tools = CorpusTools.tools(search: search)
    tool = Enum.find(tools, &(&1.name == "search_text"))

    assert {:ok, %{query: "plastic", results: [hit]}} =
             Tool.execute(tool, %{
               "query" => "plastic",
               "document_id" => "DOC123",
               "include_spreadsheets" => false,
               "limit" => 5
             })

    assert_received {:search_args, "plastic", opts}
    assert Keyword.get(opts, :limit) == 5
    assert Keyword.get(opts, :document_id) == "DOC123"
    assert Keyword.get(opts, :kinds) == ["paragraph", "sourceHtml"]

    assert hit == %{
             document_id: "DOC123",
             document_title: "A paper",
             block_id: "BLK123",
             kind: :extracted,
             text: "Plastic packaging.",
             source_page: 4,
             match: :both,
             score: 0.99
           }
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

    assert result == %{
             id: "NOTE03",
             iri: to_string(Id.iri("NOTE03"))
           }
  end
end
