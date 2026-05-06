defmodule SheafWeb.API.NoteControllerTest do
  use SheafWeb.ConnCase, async: false
  use RDF

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.{AS, DOC, PROV}

  @tag :tmp_dir
  test "lists research notes", %{conn: conn, tmp_dir: tmp_dir} do
    start_supervised!({Sheaf.Repo, path: Path.join(tmp_dir, "repo.sqlite3")})

    note = Id.iri("NOTE01")
    session = Id.iri("SESSION")
    agent = Id.iri("AGENT1")
    block = Id.iri("BLOCK1")

    graph =
      RDF.Graph.new(
        [
          {note, RDF.type(), AS.Note},
          {note, RDF.type(), DOC.ResearchNote},
          {note, RDFS.label(), RDF.literal("Evidence map note")},
          {note, AS.content(), RDF.literal("Strongest evidence sits in #BLOCK1.")},
          {note, AS.published(), RDF.literal(~U[2026-04-26 13:13:46Z])},
          {note, AS.context(), session},
          {note, AS.attributedTo(), agent},
          {note, DOC.mentions(), block},
          {agent, RDF.type(), PROV.SoftwareAgent}
        ],
        name: Sheaf.Repo.workspace_graph()
      )

    assert :ok = Sheaf.Repo.assert(graph)

    conn = get(conn, ~p"/api/notes")

    assert %{
             "notes" => [
               %{
                 "id" => "NOTE01",
                 "iri" => "https://sheaf.less.rest/NOTE01",
                 "title" => "Evidence map note",
                 "text" => "Strongest evidence sits in #BLOCK1.",
                 "published" => "2026-04-26T13:13:46Z",
                 "context" => %{
                   "id" => "SESSION",
                   "iri" => "https://sheaf.less.rest/SESSION"
                 },
                 "attributed_to" => %{
                   "id" => "AGENT1",
                   "iri" => "https://sheaf.less.rest/AGENT1"
                 },
                 "mentions" => [
                   %{"id" => "BLOCK1", "iri" => "https://sheaf.less.rest/BLOCK1"}
                 ]
               }
             ]
           } = json_response(conn, 200)
  end
end
