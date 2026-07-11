defmodule SheafWeb.ResourceControllerTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias ReqLLM.{Context, ToolCall, ToolResult}
  alias ReqLLM.Message.ContentPart
  alias Sheaf.Assistant.ContextStore
  alias Sheaf.Id
  alias Sheaf.NS.DOC

  @tag :tmp_dir
  test "serves a resolved resource as JSON from /:id", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    document = Id.iri("DOC123")
    section = Id.iri("SEC123")
    list = Id.iri("LIST12")

    graph =
      RDF.Graph.new(
        [
          {document, RDF.type(), DOC.Document},
          {document, RDF.type(), DOC.Thesis},
          {document, RDFS.label(), RDF.literal("Example Thesis")},
          {document, DOC.children(), list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Introduction")}
        ],
        name: document
      )
      |> then(fn graph ->
        RDF.list([section], graph: graph, head: list).graph
      end)

    assert :ok = Sheaf.Repo.assert(graph)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/DOC123")

    assert %{
             "id" => "DOC123",
             "iri" => "https://sheaf.less.rest/DOC123",
             "kind" => "thesis",
             "title" => "Example Thesis",
             "outline" => [
               %{
                 "id" => "SEC123",
                 "title" => "Introduction",
                 "number" => "1"
               }
             ]
           } = json_response(conn, 200)
  end

  @tag :tmp_dir
  test "plain curl negotiation serves a readable persisted conversation", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    conversation = Id.iri("CHAT01")

    workspace =
      RDF.Graph.new(
        [
          {conversation, RDF.type(), DOC.AssistantConversation},
          {conversation, RDFS.label(), RDF.literal("Trail research")},
          {conversation, DOC.conversationMode(), RDF.literal("research")}
        ],
        name: Sheaf.Workspace.graph()
      )

    context =
      Context.new([
        Context.system("Private system instructions."),
        Context.user(
          "Hidden injected context.\n\nWhich paper discusses trails?",
          %{
            sheaf_user_text: "Which paper discusses trails?"
          }
        ),
        Context.assistant("",
          tool_calls: [
            ToolCall.new("call_1", "web_search", ~s({"query":"trail papers"}))
          ]
        ),
        Context.tool_result_message(
          "web_search",
          "call_1",
          %ToolResult{
            content: [
              ContentPart.text("Found [a paper](https://example.test/paper).")
            ]
          }
        ),
        Context.assistant("The paper is relevant.")
      ])

    assert :ok = Sheaf.Repo.assert(workspace)
    assert :ok = ContextStore.write(conversation, context)

    conn =
      conn
      |> put_req_header("accept", "*/*")
      |> put_req_header("x-forwarded-proto", "https")
      |> get(~p"/CHAT01")

    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == [
             "text/markdown; charset=utf-8"
           ]

    assert get_resp_header(conn, "vary") == ["Accept"]
    assert body =~ "# Trail research"
    assert body =~ "Canonical URL: <https://www.example.com/CHAT01>"
    assert body =~ "- Mode: research"
    assert body =~ "### 1. User\n\nWhich paper discusses trails?"
    assert body =~ "#### Tool call: `web_search`"
    assert body =~ ~s("query": "trail papers")
    assert body =~ "### 3. Tool result: web_search"
    assert body =~ "[a paper](https://example.test/paper)"
    refute body =~ "Private system instructions"
    refute body =~ "Hidden injected context"
  end

  @tag :tmp_dir
  test "browser HTML negotiation still reaches the LiveView", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    conversation = Id.iri("CHAT02")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [{conversation, RDF.type(), DOC.AssistantConversation}],
                 name: Sheaf.Workspace.graph()
               )
             )

    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get(~p"/CHAT02")

    assert html_response(conn, 200) =~ "assistant-conversation-CHAT02"
  end
end
