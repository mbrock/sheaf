defmodule Sheaf.Assistant.NotesTest do
  use ExUnit.Case, async: true

  alias RDF.NS.RDFS
  alias Sheaf.Assistant.Notes
  alias Sheaf.Id
  alias Sheaf.NS.{AS, DOC, PROV}

  test "builds an ActivityStreams note graph with formal block mentions" do
    note = Id.iri("NOTE01")
    agent = Id.iri("AGENT1")
    session = Id.iri("SESS01")
    published_at = ~U[2026-04-24 12:34:56Z]

    assert {:ok, built} =
             Notes.build(
               %{
                 text: "Compare [#BLK111](/b/BLK111) with [#BLK222](/b/BLK222) and #BLK333.",
                 title: "Circulation comparison",
                 block_ids: ["BLK222", "BLK444"],
                 agent_iri: agent,
                 agent_label: "Paper reader",
                 session_iri: session,
                 session_label: "Swapshop reading"
               },
               note_iri: note,
               published_at: published_at
             )

    graph = built.graph

    assert built.id == "NOTE01"
    assert built.agent_id == "AGENT1"
    assert built.session_id == "SESS01"
    assert MapSet.new(built.block_ids) == MapSet.new(~w[BLK111 BLK222 BLK333 BLK444])

    assert RDF.Data.include?(graph, {note, RDF.type(), AS.Note})
    assert RDF.Data.include?(graph, {note, AS.attributedTo(), agent})
    assert RDF.Data.include?(graph, {note, AS.context(), session})
    assert RDF.Data.include?(graph, {note, AS.published(), published_at})
    assert RDF.Data.include?(graph, {note, AS.content(), built.text})
    assert RDF.Data.include?(graph, {note, RDFS.label(), "Circulation comparison"})
    assert RDF.Data.include?(graph, {agent, RDF.type(), PROV.SoftwareAgent})
    assert RDF.Data.include?(graph, {session, RDF.type(), DOC.ResearchSession})
    assert RDF.Data.include?(graph, {note, DOC.mentions(), Id.iri("BLK444")})
  end

  test "write persists an INSERT DATA update and omits the graph from the result" do
    test_pid = self()

    update = fn sparql ->
      send(test_pid, {:sparql_update, sparql})
      :ok
    end

    assert {:ok, note} =
             Notes.write(
               %{
                 text: "Useful quote at [#ABC123](/b/ABC123).",
                 agent_id: "AGENT2",
                 session_id: "SESS02"
               },
               note_iri: Id.iri("NOTE02"),
               published_at: ~U[2026-04-24 13:00:00Z],
               update: update
             )

    refute Map.has_key?(note, :graph)
    assert note.block_ids == ["ABC123"]

    assert_receive {:sparql_update, sparql}
    assert sparql =~ "INSERT DATA"
    assert sparql =~ "<https://www.w3.org/ns/activitystreams#Note>"
    assert sparql =~ "<https://less.rest/sheaf/mentions>"
    assert sparql =~ "<#{Id.iri("ABC123")}>"
  end

  test "from_rows groups note mentions and sorts newest notes first" do
    older = Id.iri("NOTE10")
    newer = Id.iri("NOTE20")
    agent = Id.iri("AGENT4")
    session = Id.iri("SESS04")

    rows = [
      %{
        "note" => older,
        "content" => RDF.literal("Older note."),
        "published" => RDF.literal(~U[2026-04-24 11:00:00Z]),
        "mention" => Id.iri("BLK100")
      },
      %{
        "note" => newer,
        "title" => RDF.literal("Newer note"),
        "content" => RDF.literal("Newer note."),
        "published" => RDF.literal(~U[2026-04-24 12:00:00Z]),
        "agent" => agent,
        "agentLabel" => RDF.literal("Research bot"),
        "context" => session,
        "contextLabel" => RDF.literal("Reading session"),
        "mention" => Id.iri("BLK200")
      },
      %{
        "note" => newer,
        "title" => RDF.literal("Newer note"),
        "content" => RDF.literal("Newer note."),
        "published" => RDF.literal(~U[2026-04-24 12:00:00Z]),
        "agent" => agent,
        "context" => session,
        "mention" => Id.iri("BLK201")
      }
    ]

    assert [
             %{
               id: "NOTE20",
               title: "Newer note",
               agent_id: "AGENT4",
               agent_label: "Research bot",
               session_id: "SESS04",
               session_label: "Reading session",
               mentions: [%{id: "BLK200", path: "/b/BLK200"}, %{id: "BLK201", path: "/b/BLK201"}]
             },
             %{id: "NOTE10", mentions: [%{id: "BLK100", path: "/b/BLK100"}]}
           ] = Notes.from_rows(rows)
  end
end
