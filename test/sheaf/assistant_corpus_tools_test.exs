defmodule Sheaf.Assistant.CorpusToolsTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Tool
  alias Sheaf.Assistant.CorpusTools
  alias Sheaf.Id

  test "write_note tool persists through the configured note writer and emits events" do
    test_pid = self()
    agent = Id.iri("AGENT3")
    session = Id.iri("SESS03")

    note_writer = fn attrs ->
      send(test_pid, {:note_attrs, attrs})

      {:ok,
       %{
         id: "NOTE03",
         iri: to_string(Id.iri("NOTE03")),
         agent_id: "AGENT3",
         session_id: "SESS03",
         block_ids: attrs.block_ids,
         published_at: "2026-04-24T13:30:00Z"
       }}
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
               "text" => "This relates [#ABC123](/b/ABC123) to the introduction.",
               "block_ids" => ["ABC123"],
               "title" => "A note"
             })

    assert_receive {:tool_started, "write_note", %{text: _text}}

    assert_receive {:note_attrs,
                    %{
                      text: "This relates [#ABC123](/b/ABC123) to the introduction.",
                      title: "A note",
                      block_ids: ["ABC123"],
                      agent_iri: ^agent,
                      session_iri: ^session
                    }}

    assert_receive {:tool_finished, "write_note", {:ok, ^result}}

    assert result == %{
             id: "NOTE03",
             iri: to_string(Id.iri("NOTE03")),
             agent_id: "AGENT3",
             session_id: "SESS03",
             block_ids: ["ABC123"],
             published_at: "2026-04-24T13:30:00Z"
           }
  end
end
