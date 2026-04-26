defmodule Sheaf.Assistant.ActivityTest do
  use ExUnit.Case, async: true

  alias Sheaf.Assistant.Activity
  alias Sheaf.Id

  test "builds user and assistant messages with contextual blank-node actors" do
    question = Id.iri("MSG001")
    reply = Id.iri("MSG002")
    session = Id.iri("SESS01")
    published_at = ~U[2026-04-26 10:00:00Z]

    assert {:ok, question_graph} =
             Activity.build_message(
               :user,
               %{
                 message_iri: question,
                 session_iri: session,
                 session_label: "Research session SESS01",
                 text: "What should I read about circular economies?"
               },
               published_at: published_at
             )

    assert RDF.Data.include?(question_graph, {question, RDF.type(), Sheaf.NS.DOC.Message})
    assert RDF.Data.include?(question_graph, {session, RDF.type(), Sheaf.NS.AS.OrderedCollection})
    assert RDF.Data.include?(question_graph, {session, Sheaf.NS.AS.items(), question})

    assert [user] =
             RDF.Description.get(
               RDF.Data.description(question_graph, question),
               Sheaf.NS.AS.attributedTo()
             )

    assert %RDF.BlankNode{} = user
    assert RDF.Data.include?(question_graph, {user, RDF.type(), Sheaf.NS.AS.Person})

    assert {:ok, reply_graph} =
             Activity.build_message(
               :assistant,
               %{
                 message_iri: reply,
                 model_name: "test-model",
                 session_iri: session,
                 session_label: "Research session SESS01",
                 in_reply_to: question,
                 text: "Start with the reuse papers."
               },
               published_at: published_at
             )

    assert RDF.Data.include?(reply_graph, {reply, RDF.type(), Sheaf.NS.DOC.Message})
    refute RDF.Data.include?(reply_graph, {reply, RDF.type(), Sheaf.NS.AS.Note})
    assert RDF.Data.include?(reply_graph, {reply, Sheaf.NS.AS.inReplyTo(), question})
    assert RDF.Data.include?(reply_graph, {session, Sheaf.NS.AS.items(), reply})

    assert [assistant] =
             RDF.Description.get(
               RDF.Data.description(reply_graph, reply),
               Sheaf.NS.AS.attributedTo()
             )

    assert %RDF.BlankNode{} = assistant
    assert RDF.Data.include?(reply_graph, {assistant, RDF.type(), Sheaf.NS.PROV.SoftwareAgent})

    assert RDF.Data.include?(
             reply_graph,
             {assistant, Sheaf.NS.DOC.assistantModelName(), "test-model"}
           )
  end
end
