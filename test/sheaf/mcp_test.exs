defmodule Sheaf.MCPTest do
  use ExUnit.Case, async: true

  alias ReqLLM.{Tool, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.MCP

  test "exposes only the bounded research-library tool surface" do
    assert MCP.tools() |> Enum.map(& &1.name) |> MapSet.new() ==
             MapSet.new(~w(
               list_documents
               get_document
               read
               search_text
               list_notes
               write_note
             ))
  end

  test "initialize negotiates supported and unknown protocol revisions" do
    assert {:response,
            %{
              "id" => 1,
              "result" => %{
                "protocolVersion" => "2025-06-18",
                "capabilities" => %{"tools" => %{}}
              }
            }} =
             MCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18"}
             })

    assert {:response, %{"result" => %{"protocolVersion" => "2025-11-25"}}} =
             MCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => "init",
               "method" => "initialize",
               "params" => %{"protocolVersion" => "future-version"}
             })
  end

  test "tools/list publishes MCP schemas and safety annotations" do
    tools = [
      Tool.new!(
        name: "lookup",
        description: "Look something up",
        parameter_schema: [
          query: [type: :string, required: true, doc: "Search query"]
        ],
        callback: fn _args -> {:ok, "unused"} end
      ),
      Tool.new!(
        name: "write_note",
        description: "Save a note",
        parameter_schema: [text: [type: :string, required: true]],
        callback: fn _args -> {:ok, "unused"} end
      )
    ]

    assert {:response, %{"result" => %{"tools" => listed}}} =
             MCP.handle(
               %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
               tools: tools
             )

    lookup = Enum.find(listed, &(&1["name"] == "lookup"))
    write_note = Enum.find(listed, &(&1["name"] == "write_note"))

    assert lookup["inputSchema"]["required"] == ["query"]
    assert lookup["annotations"]["readOnlyHint"]
    refute write_note["annotations"]["readOnlyHint"]
    refute write_note["annotations"]["destructiveHint"]
  end

  test "tools/call converts native tool results and errors" do
    ok_tool =
      Tool.new!(
        name: "read",
        description: "Read a resource",
        parameter_schema: [id: [type: :string, required: true]],
        callback: fn %{id: id} ->
          {:ok, %ToolResult{content: [ContentPart.text("RESOURCE ##{id}")]}}
        end
      )

    error_tool =
      Tool.new!(
        name: "search_text",
        description: "Search text",
        callback: fn _args -> {:error, "search unavailable"} end
      )

    assert {:response,
            %{
              "result" => %{
                "content" => [
                  %{"type" => "text", "text" => "RESOURCE #ABC123"}
                ],
                "isError" => false
              }
            }} =
             MCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 3,
                 "method" => "tools/call",
                 "params" => %{
                   "name" => "read",
                   "arguments" => %{"id" => "ABC123"}
                 }
               },
               tools: [ok_tool]
             )

    assert {:response,
            %{
              "result" => %{
                "content" => [
                  %{"type" => "text", "text" => "search unavailable"}
                ],
                "isError" => true
              }
            }} =
             MCP.handle(
               %{
                 "jsonrpc" => "2.0",
                 "id" => 4,
                 "method" => "tools/call",
                 "params" => %{"name" => "search_text", "arguments" => %{}}
               },
               tools: [error_tool]
             )
  end

  test "notifications are accepted and unknown requests return JSON-RPC errors" do
    assert :accepted =
             MCP.handle(%{
               "jsonrpc" => "2.0",
               "method" => "notifications/initialized"
             })

    assert {:response,
            %{"error" => %{"code" => -32601, "message" => message}}} =
             MCP.handle(%{
               "jsonrpc" => "2.0",
               "id" => 5,
               "method" => "resources/list"
             })

    assert message =~ "resources/list"
  end
end
