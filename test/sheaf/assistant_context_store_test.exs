defmodule Sheaf.Assistant.ContextStoreTest do
  use ExUnit.Case, async: true

  alias RDF.Graph
  alias ReqLLM.{Context, Tool, ToolCall, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.{ContextCodec, ContextStore, ToolResults}

  test "codec preserves ReqLLM messages and structured Sheaf tool result metadata" do
    sheaf_result = %ToolResults.SpreadsheetQuery{
      intent: "inspect rows",
      sql: "SELECT * FROM example",
      result_id: "RES111",
      result_iri: "https://sheaf.less.rest/RES111",
      row_count: 2,
      columns: ["name"],
      rows: [%{"name" => "alpha"}]
    }

    context =
      Context.new([
        Context.system("System prompt."),
        Context.assistant("",
          tool_calls: [ToolCall.new("call_1", "query_spreadsheets", ~s({"sql":"SELECT 1"}))]
        ),
        Context.tool_result_message(
          "query_spreadsheets",
          "call_1",
          %ToolResult{
            content: [ContentPart.text("SPREADSHEET QUERY\nResult: #RES111")],
            metadata: %{sheaf_result: sheaf_result}
          }
        )
      ])

    assert {:ok, decoded} =
             context
             |> ContextCodec.encode_context()
             |> Jason.encode!()
             |> Jason.decode!()
             |> ContextCodec.decode_context()

    [system, assistant, tool] = decoded.messages

    assert system.role == :system
    assert [%ToolCall{id: "call_1"}] = assistant.tool_calls
    assert tool.role == :tool
    assert tool.tool_call_id == "call_1"

    assert %ToolResults.SpreadsheetQuery{result_id: "RES111"} =
             Map.fetch!(tool.metadata, "sheaf_result")
  end

  test "stores context messages as indexed rdf:JSON payloads" do
    session = Sheaf.Id.iri("CHAT01")
    empty_graph = Graph.new(name: RDF.iri(ContextStore.graph()))

    context =
      Context.new([
        Context.system("System prompt."),
        Context.user("What should I read?")
      ])

    assert :ok =
             ContextStore.write(session, context,
               graph: empty_graph,
               persist: fn graph ->
                 send(self(), {:persisted_context_graph, graph})
                 :ok
               end
             )

    assert_receive {:persisted_context_graph, graph}

    assert {:ok, decoded} = ContextStore.read(session, graph: graph)
    assert Enum.map(decoded.messages, & &1.role) == [:system, :user]

    context_description = Graph.description(graph, ContextStore.context_iri(session))

    [message_node | _] =
      RDF.Description.get(context_description, Sheaf.NS.DOC.hasContextMessage())

    message_description = Graph.description(graph, message_node)
    payload = RDF.Description.first(message_description, Sheaf.NS.DOC.reqLLMMessage())

    assert RDF.Literal.datatype_id(payload) ==
             RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON")
  end

  test "stores available tool schemas as an rdf:JSON payload" do
    session = Sheaf.Id.iri("CHAT02")
    empty_graph = Graph.new(name: RDF.iri(ContextStore.graph()))

    tool =
      Tool.new!(
        name: "lookup",
        description: "Look up a thing.",
        parameter_schema: [
          id: [type: :string, required: true, doc: "Thing id"]
        ],
        callback: fn _args -> {:ok, "found"} end
      )

    context =
      Context.new([Context.system("System prompt.")])
      |> Map.put(:tools, [tool])

    assert :ok =
             ContextStore.write(session, context,
               graph: empty_graph,
               persist: fn graph ->
                 send(self(), {:persisted_context_graph, graph})
                 :ok
               end
             )

    assert_receive {:persisted_context_graph, graph}

    context_description = Graph.description(graph, ContextStore.context_iri(session))
    payload = RDF.Description.first(context_description, Sheaf.NS.DOC.toolSchemaList())

    assert RDF.Literal.datatype_id(payload) ==
             RDF.iri("http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON")

    assert [%{} = schema] = RDF.Term.value(payload)
    assert inspect(schema) =~ "lookup"
    refute inspect(schema) =~ "callback"
  end
end
