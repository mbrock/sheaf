defmodule SheafWeb.AssistantHistoryComponentsTest do
  use SheafWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SheafWeb.AssistantHistoryComponents

  alias RDF.NS.RDFS
  alias Sheaf.NS.{AS, DOC, PROV}

  test "renders quick chat messages and research notes in session groups" do
    quick = RDF.iri("https://sheaf.less.rest/QUICK1")
    quick_user = RDF.iri("https://sheaf.less.rest/USER01")
    quick_reply = RDF.iri("https://sheaf.less.rest/REPLY1")
    quick_user_actor = RDF.bnode()
    quick_assistant_actor = RDF.bnode()
    research = RDF.iri("https://sheaf.less.rest/RESEA1")
    research_user = RDF.iri("https://sheaf.less.rest/USER02")
    note = RDF.iri("https://sheaf.less.rest/NOTE01")
    research_user_actor = RDF.bnode()
    note_agent = RDF.iri("https://sheaf.less.rest/AGENT1")

    graph =
      RDF.Graph.new([
        {quick, RDF.type(), DOC.AssistantConversation},
        {quick, RDF.type(), AS.OrderedCollection},
        {quick, RDFS.label(), RDF.literal("Assistant conversation QUICK1")},
        {quick, DOC.conversationMode(), RDF.literal("quick")},
        {quick, AS.items(), quick_user},
        {quick, AS.items(), quick_reply},
        {quick_user, RDF.type(), DOC.Message},
        {quick_user, AS.context(), quick},
        {quick_user, AS.attributedTo(), quick_user_actor},
        {quick_user, AS.content(), RDF.literal("Can you find Alise quotes?")},
        {quick_user, AS.published(), RDF.literal(~U[2026-04-26 13:08:44Z])},
        {quick_user_actor, RDF.type(), AS.Person},
        {quick_reply, RDF.type(), DOC.Message},
        {quick_reply, AS.context(), quick},
        {quick_reply, AS.inReplyTo(), quick_user},
        {quick_reply, AS.attributedTo(), quick_assistant_actor},
        {quick_reply, AS.content(), RDF.literal("Yes, Alise appears in #ABC123.")},
        {quick_reply, AS.published(), RDF.literal(~U[2026-04-26 13:09:40Z])},
        {quick_assistant_actor, RDF.type(), PROV.SoftwareAgent},
        {quick_assistant_actor, DOC.assistantModelName(), RDF.literal("test:model")},
        {research, RDF.type(), DOC.AssistantConversation},
        {research, RDF.type(), AS.OrderedCollection},
        {research, RDFS.label(), RDF.literal("Assistant conversation RESEA1")},
        {research, DOC.conversationMode(), RDF.literal("research")},
        {research, AS.items(), research_user},
        {research, AS.items(), note},
        {research_user, RDF.type(), DOC.Message},
        {research_user, AS.context(), research},
        {research_user, AS.attributedTo(), research_user_actor},
        {research_user, AS.content(), RDF.literal("Map the strongest evidence.")},
        {research_user, AS.published(), RDF.literal(~U[2026-04-26 13:13:00Z])},
        {research_user_actor, RDF.type(), AS.Person},
        {note, RDF.type(), AS.Note},
        {note, RDF.type(), DOC.ResearchNote},
        {note, RDFS.label(), RDF.literal("Evidence map note")},
        {note, AS.context(), research},
        {note, AS.attributedTo(), note_agent},
        {note, AS.content(), RDF.literal("Strongest evidence sits in #ABC123.")},
        {note, AS.published(), RDF.literal(~U[2026-04-26 13:13:46Z])},
        {note, DOC.mentions(), RDF.iri("https://sheaf.less.rest/ABC123")},
        {note_agent, RDF.type(), PROV.SoftwareAgent},
        {note_agent, RDFS.label(), RDF.literal("Sheaf research assistant")}
      ])

    items =
      graph
      |> RDF.Data.descriptions()
      |> Enum.filter(fn description ->
        RDF.Description.include?(description, {RDF.type(), DOC.Message}) ||
          RDF.Description.include?(description, {RDF.type(), AS.Note})
      end)

    html =
      render_component(&note_history/1,
        notes: items,
        notes_graph: graph,
        research_session_titles: %{},
        resource_paths: %{"ABC123" => "/b/ABC123"},
        notes_error: nil
      )

    assert html =~ "Can you find Alise quotes?"
    assert html =~ "Yes, Alise appears in"
    assert html =~ ~s(href="/b/ABC123")
    assert html =~ ~s(href="/QUICK1")
    assert html =~ ~s(aria-label="Open chat #QUICK1")
    assert html =~ "Map the strongest evidence."
    assert html =~ "Evidence map note"
    assert html =~ "Strongest evidence sits in"
    assert html =~ ~s(href="/RESEA1")
    assert html =~ ~s(aria-label="Open chat #RESEA1")

    expansive_html =
      render_component(&note_history/1,
        notes: items,
        notes_graph: graph,
        research_session_titles: %{},
        resource_paths: %{"ABC123" => "/b/ABC123"},
        notes_error: nil,
        variant: :expansive
      )

    assert expansive_html =~ "Open chat"
    assert expansive_html =~ ~s(href="/RESEA1")
  end
end
