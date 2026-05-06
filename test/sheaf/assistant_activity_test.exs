defmodule Sheaf.Assistant.ActivityTest do
  use ExUnit.Case, async: true

  alias Sheaf.Assistant.Activity
  alias Sheaf.Id

  test "builds user and assistant messages with contextual blank-node actors" do
    question = Id.iri("MSG001")
    reply = Id.iri("MSG002")
    session = Id.iri("SESS01")
    assistant_iri = Id.iri("AGENT1")
    published_at = ~U[2026-04-26 10:00:00Z]

    assert {:ok, question_graph} =
             Activity.build_message(
               :user,
               %{
                 message_iri: question,
                 session_iri: session,
                 session_label: "Assistant conversation SESS01",
                 conversation_mode: "quick",
                 text: "What should I read about circular economies?"
               },
               published_at: published_at
             )

    assert RDF.Data.include?(
             question_graph,
             {question, RDF.type(), Sheaf.NS.DOC.Message}
           )

    assert RDF.Data.include?(
             question_graph,
             {session, RDF.type(), Sheaf.NS.DOC.AssistantConversation}
           )

    assert RDF.Data.include?(
             question_graph,
             {session, RDF.type(), Sheaf.NS.AS.OrderedCollection}
           )

    assert RDF.Data.include?(
             question_graph,
             {session, Sheaf.NS.DOC.conversationMode(), "quick"}
           )

    assert RDF.Data.include?(
             question_graph,
             {session, Sheaf.NS.AS.items(), question}
           )

    assert [user] =
             RDF.Description.get(
               RDF.Data.description(question_graph, question),
               Sheaf.NS.AS.attributedTo()
             )

    assert %RDF.BlankNode{} = user

    assert RDF.Data.include?(
             question_graph,
             {user, RDF.type(), Sheaf.NS.AS.Person}
           )

    assert {:ok, reply_graph} =
             Activity.build_message(
               :assistant,
               %{
                 message_iri: reply,
                 actor_iri: assistant_iri,
                 model_name: "test-model",
                 session_iri: session,
                 session_label: "Assistant conversation SESS01",
                 conversation_mode: "research",
                 in_reply_to: question,
                 text: "Start with the reuse papers."
               },
               published_at: published_at
             )

    assert RDF.Data.include?(
             reply_graph,
             {reply, RDF.type(), Sheaf.NS.DOC.Message}
           )

    refute RDF.Data.include?(
             reply_graph,
             {reply, RDF.type(), Sheaf.NS.AS.Note}
           )

    assert RDF.Data.include?(
             reply_graph,
             {reply, Sheaf.NS.AS.inReplyTo(), question}
           )

    assert RDF.Data.include?(
             reply_graph,
             {session, Sheaf.NS.AS.items(), reply}
           )

    assert RDF.Data.include?(
             reply_graph,
             {session, Sheaf.NS.DOC.conversationMode(), "research"}
           )

    assert [^assistant_iri] =
             RDF.Description.get(
               RDF.Data.description(reply_graph, reply),
               Sheaf.NS.AS.attributedTo()
             )

    assert RDF.Data.include?(
             reply_graph,
             {assistant_iri, RDF.type(), Sheaf.NS.PROV.SoftwareAgent}
           )

    assert RDF.Data.include?(
             reply_graph,
             {assistant_iri, Sheaf.NS.DOC.assistantModelName(), "test-model"}
           )
  end

  test "insert_data writes assistant activity to the workspace graph" do
    message = Id.iri("MSG003")
    session = Id.iri("SESS03")

    assert {:ok, graph} =
             Activity.build_message(
               :user,
               %{
                 message_iri: message,
                 session_iri: session,
                 text: "Track this in RDF."
               },
               published_at: ~U[2026-04-26 11:00:00Z]
             )

    sparql = Activity.insert_data(graph)

    assert sparql =~ "INSERT DATA"
    assert sparql =~ "GRAPH <#{Sheaf.Workspace.graph()}>"
    assert sparql =~ "<#{message}>"
    assert sparql =~ "<https://less.rest/sheaf/Message>"
  end
end
