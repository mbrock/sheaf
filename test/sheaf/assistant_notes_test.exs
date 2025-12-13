defmodule Sheaf.Assistant.NotesTest do
  use ExUnit.Case, async: true

  alias Sheaf.Assistant.Notes
  alias Sheaf.Id
  alias Sheaf.NS.PROV
  require RDF.Graph

  test "builds an ActivityStreams note graph with formal block mentions" do
    note = Id.iri("NOTE01")
    agent = Id.iri("AGENT1")
    session = Id.iri("SESS01")
    published_at = ~U[2026-04-24 12:34:56Z]

    text = "Compare [#BLK111](/b/BLK111) with [#BLK222](/b/BLK222) and #BLK333."

    assert {:ok, graph} =
             Notes.build(
               %{
                 text: text,
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

    [description] = Notes.descriptions(graph)
    mentions = RDF.Description.get(description, Sheaf.NS.DOC.mentions(), [])

    assert description.subject == note

    assert MapSet.new(Enum.map(mentions, &Id.id_from_iri/1)) ==
             MapSet.new(~w[BLK111 BLK222 BLK333 BLK444])

    assert RDF.Data.include?(graph, {note, RDF.type(), Sheaf.NS.AS.Note})
    assert RDF.Data.include?(graph, {note, RDF.type(), Sheaf.NS.DOC.ResearchNote})
    assert RDF.Data.include?(graph, {note, Sheaf.NS.AS.attributedTo(), agent})
    assert RDF.Data.include?(graph, {note, Sheaf.NS.AS.context(), session})
    assert RDF.Data.include?(graph, {note, Sheaf.NS.AS.published(), published_at})
    assert RDF.Data.include?(graph, {note, Sheaf.NS.AS.content(), text})
    assert RDF.Data.include?(graph, {note, RDF.NS.RDFS.label(), "Circulation comparison"})
    assert RDF.Data.include?(graph, {agent, RDF.type(), PROV.SoftwareAgent})
    assert RDF.Data.include?(graph, {session, RDF.type(), Sheaf.NS.DOC.AssistantConversation})
    assert RDF.Data.include?(graph, {session, RDF.type(), Sheaf.NS.AS.OrderedCollection})
    assert RDF.Data.include?(graph, {session, Sheaf.NS.AS.items(), note})
    assert RDF.Data.include?(graph, {note, Sheaf.NS.DOC.mentions(), Id.iri("BLK444")})
  end

  test "write persists a note graph in the workspace graph" do
    test_pid = self()

    persist = fn graph ->
      send(test_pid, {:persist, graph})
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
               persist: persist
             )

    assert note == Id.iri("NOTE02")

    assert_receive {:persist, graph}
    assert graph.name == RDF.iri(Sheaf.Workspace.graph())
    assert RDF.Data.include?(graph, {note, RDF.type(), Sheaf.NS.AS.Note})
    assert RDF.Data.include?(graph, {note, Sheaf.NS.DOC.mentions(), Id.iri("ABC123")})
  end

  test "descriptions returns note descriptions newest first" do
    older = Id.iri("NOTE10")
    newer = Id.iri("NOTE20")
    agent = Id.iri("AGENT4")
    session = Id.iri("SESS04")

    graph =
      RDF.Graph.build older: older, newer: newer, agent: agent, session: session do
        @prefix Sheaf.NS.AS
        @prefix Sheaf.NS.DOC
        @prefix RDF.NS.RDFS

        older
        |> a(AS.Note)
        |> AS.content("Older note.")
        |> AS.published(~U[2026-04-24 11:00:00Z])
        |> DOC.mentions(Id.iri("BLK100"))

        newer
        |> a(AS.Note)
        |> RDFS.label("Newer note")
        |> AS.content("Newer note.")
        |> AS.published(~U[2026-04-24 12:00:00Z])
        |> AS.attributedTo(agent)
        |> AS.context(session)
        |> DOC.mentions([Id.iri("BLK200"), Id.iri("BLK201")])
      end

    assert [newer_description, older_description] = Notes.descriptions(graph)
    assert newer_description.subject == newer
    assert older_description.subject == older

    assert RDF.Description.first(newer_description, RDF.NS.RDFS.label()) ==
             RDF.literal("Newer note")

    assert MapSet.new(RDF.Description.get(newer_description, Sheaf.NS.DOC.mentions(), [])) ==
             MapSet.new([Id.iri("BLK200"), Id.iri("BLK201")])
  end

  test "returns the workspace graph from an RDF dataset" do
    session = Id.iri("SESS05")
    note = Id.iri("NOTE50")
    legacy_note = Id.iri("NOTE40")
    agent = Id.iri("AGENT5")
    question = Id.iri("QUESTION5")
    reply = Id.iri("REPLY5")
    user = Id.iri("USER5")

    workspace_graph =
      RDF.Graph.new(
        RDF.Graph.build note: note,
                        legacy_note: legacy_note,
                        agent: agent,
                        session: session,
                        question: question,
                        reply: reply,
                        user: user do
          @prefix Sheaf.NS.AS
          @prefix Sheaf.NS.DOC
          @prefix RDF.NS.RDFS

          note
          |> a(AS.Note)
          |> a(DOC.ResearchNote)
          |> AS.content("Newer note.")
          |> AS.published(~U[2026-04-24 14:00:00Z])
          |> AS.attributedTo(agent)
          |> AS.context(session)
          |> RDFS.label("Newer research note")
          |> DOC.mentions(Id.iri("BLK500"))

          legacy_note
          |> a(AS.Note)
          |> AS.content("Legacy note.")
          |> AS.published(~U[2026-04-24 13:00:00Z])
          |> RDFS.label("Legacy research note")

          agent
          |> RDFS.label("Paper reader")

          session
          |> RDFS.label("Research session SESS05")
          |> DOC.conversationMode("research")

          question
          |> a(DOC.Message)
          |> AS.context(session)
          |> AS.content("What changed in the appendix?")
          |> AS.published(~U[2026-04-24 12:00:00Z])
          |> AS.attributedTo(user)

          reply
          |> a(DOC.Message)
          |> AS.context(session)
          |> AS.content("A reply should not become the group title.")
          |> AS.inReplyTo(question)

          user
          |> RDFS.label("Reader")
        end,
        name: Sheaf.Repo.workspace_graph()
      )

    dataset = RDF.Dataset.new() |> RDF.Dataset.add(workspace_graph)
    graph = Notes.from_dataset(dataset)

    assert RDF.Data.include?(graph, {note, RDF.type(), Sheaf.NS.AS.Note})
    assert RDF.Data.include?(graph, {note, RDF.type(), Sheaf.NS.DOC.ResearchNote})
    assert RDF.Data.include?(graph, {legacy_note, RDF.type(), Sheaf.NS.AS.Note})
    refute RDF.Data.include?(graph, {legacy_note, RDF.type(), Sheaf.NS.DOC.ResearchNote})
    assert RDF.Data.include?(graph, {agent, RDF.NS.RDFS.label(), "Paper reader"})
    assert RDF.Data.include?(graph, {session, RDF.NS.RDFS.label(), "Research session SESS05"})
    assert RDF.Data.include?(graph, {question, RDF.type(), Sheaf.NS.DOC.Message})

    assert RDF.Data.include?(
             graph,
             {question, Sheaf.NS.AS.content(), "What changed in the appendix?"}
           )

    assert RDF.Data.include?(graph, {user, RDF.NS.RDFS.label(), "Reader"})
    assert RDF.Data.include?(graph, {reply, RDF.type(), Sheaf.NS.DOC.Message})
    assert RDF.Data.include?(graph, {reply, Sheaf.NS.AS.inReplyTo(), question})
  end
end
