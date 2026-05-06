defmodule Sheaf.GoogleDocsImporterTest do
  use ExUnit.Case, async: true

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.GoogleDocsImporter
  alias Sheaf.NS.DOC
  require RDF.Graph

  test "extracts a coherent recursive section subgraph" do
    %{
      graph: graph,
      old_section: old_section,
      old_paragraph: old_paragraph,
      old_revision: old_revision
    } =
      fixture_graph()

    subgraph = GoogleDocsImporter.section_subgraph(graph, old_section)

    assert RDF.Data.include?(
             subgraph,
             {old_section, RDFS.label(), RDF.literal("Old chapter")}
           )

    assert RDF.Data.include?(
             subgraph,
             {old_paragraph, DOC.paragraph(), old_revision}
           )

    assert RDF.Data.include?(
             subgraph,
             {old_revision, DOC.text(), RDF.literal("Old paragraph.")}
           )

    refute RDF.Data.include?(
             subgraph,
             {RDF.iri("https://example.com/sheaf/DOC"), RDFS.label(),
              RDF.literal("Document")}
           )
  end

  test "builds a section replacement plan that only retracts parent list links" do
    %{
      graph: existing_graph,
      document: document,
      old_section: old_section,
      keep_section: keep_section,
      new_graph: new_graph,
      new_section: new_section,
      new_revision: new_revision
    } = fixture_graph()

    activity = RDF.iri("https://example.com/sheaf/ACT")
    generated_at = ~U[2026-05-03 12:00:00Z]

    assert {:ok, plan} =
             GoogleDocsImporter.section_replacement_plan(
               existing_graph,
               document,
               old_section,
               new_graph,
               new_section,
               activity_iri: activity,
               generated_at: generated_at,
               source_url: "https://docs.google.com/document/d/example/edit"
             )

    assert plan.old_children == [old_section, keep_section]
    assert plan.new_children == [new_section, keep_section]

    assert Sheaf.Document.children(plan.assert, document) == [
             new_section,
             keep_section
           ]

    assert RDF.Data.include?(
             plan.assert,
             {new_revision, DOC.text(), RDF.literal("New paragraph.")}
           )

    assert RDF.Data.include?(
             plan.retract,
             {document, DOC.children(), plan.retract |> child_list(document)}
           )

    refute RDF.Data.include?(
             plan.retract,
             {old_section, RDFS.label(), RDF.literal("Old chapter")}
           )

    expected_provenance =
      RDF.Graph.build activity: activity,
                      old_section: old_section,
                      new_section: new_section,
                      generated_at: generated_at do
        activity
        |> a(Sheaf.NS.PROV.Activity)
        |> RDFS.label("Google Docs section import")
        |> DOC.sourceKey("https://docs.google.com/document/d/example/edit")
        |> Sheaf.NS.PROV.used(old_section)
        |> Sheaf.NS.PROV.generated(new_section)
        |> Sheaf.NS.PROV.invalidated(old_section)
        |> Sheaf.NS.PROV.endedAtTime(generated_at)

        new_section
        |> Sheaf.NS.PROV.wasRevisionOf(old_section)
        |> Sheaf.NS.PROV.wasGeneratedBy(activity)
        |> Sheaf.NS.PROV.generatedAtTime(generated_at)

        old_section
        |> Sheaf.NS.PROV.wasInvalidatedBy(activity)
        |> Sheaf.NS.PROV.invalidatedAtTime(generated_at)
      end
      |> Graph.change_name(RDF.iri(Sheaf.Repo.workspace_graph()))

    assert RDF.Graph.name(plan.provenance) ==
             RDF.iri(Sheaf.Repo.workspace_graph())

    assert RDF.Graph.isomorphic?(plan.provenance, expected_provenance)
  end

  test "finds sections by exact title" do
    %{graph: graph, old_section: old_section} = fixture_graph()

    assert {:ok, ^old_section} =
             GoogleDocsImporter.section_iri_by_title(graph, "Old chapter")

    assert {:error, {:section_not_found, "Missing"}} =
             GoogleDocsImporter.section_iri_by_title(graph, "Missing")
  end

  defp fixture_graph do
    document = RDF.iri("https://example.com/sheaf/DOC")
    root_list = RDF.iri("https://example.com/sheaf/LIST")
    old_section = RDF.iri("https://example.com/sheaf/OLD")
    old_list = RDF.iri("https://example.com/sheaf/OLDLIST")
    old_paragraph = RDF.iri("https://example.com/sheaf/OLDP")
    old_revision = RDF.iri("https://example.com/sheaf/OLDPV")
    keep_section = RDF.iri("https://example.com/sheaf/KEEP")
    new_section = RDF.iri("https://example.com/sheaf/NEW")
    new_list = RDF.iri("https://example.com/sheaf/NEWLIST")
    new_paragraph = RDF.iri("https://example.com/sheaf/NEWP")
    new_revision = RDF.iri("https://example.com/sheaf/NEWPV")

    graph =
      Graph.new(
        [
          {document, RDFS.label(), RDF.literal("Document")},
          {document, DOC.children(), root_list},
          {old_section, RDF.type(), DOC.Section},
          {old_section, RDFS.label(), RDF.literal("Old chapter")},
          {old_section, DOC.children(), old_list},
          {old_paragraph, RDF.type(), DOC.ParagraphBlock},
          {old_paragraph, DOC.paragraph(), old_revision},
          {old_revision, RDF.type(), DOC.Paragraph},
          {old_revision, DOC.text(), RDF.literal("Old paragraph.")},
          {keep_section, RDF.type(), DOC.Section},
          {keep_section, RDFS.label(), RDF.literal("Keep chapter")}
        ],
        name: document
      )
      |> then(fn graph ->
        RDF.list([old_section, keep_section], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([old_paragraph], graph: graph, head: old_list).graph
      end)

    new_graph =
      Graph.new(
        [
          {document, RDFS.label(), RDF.literal("Document")},
          {document, DOC.children(),
           RDF.iri("https://example.com/sheaf/NEWROOTLIST")},
          {new_section, RDF.type(), DOC.Section},
          {new_section, RDFS.label(), RDF.literal("New chapter")},
          {new_section, DOC.children(), new_list},
          {new_paragraph, RDF.type(), DOC.ParagraphBlock},
          {new_paragraph, DOC.paragraph(), new_revision},
          {new_revision, RDF.type(), DOC.Paragraph},
          {new_revision, DOC.text(), RDF.literal("New paragraph.")}
        ],
        name: document
      )
      |> then(fn graph ->
        RDF.list([new_section],
          graph: graph,
          head: RDF.iri("https://example.com/sheaf/NEWROOTLIST")
        ).graph
      end)
      |> then(fn graph ->
        RDF.list([new_paragraph], graph: graph, head: new_list).graph
      end)

    %{
      graph: graph,
      document: document,
      old_section: old_section,
      old_paragraph: old_paragraph,
      old_revision: old_revision,
      keep_section: keep_section,
      new_graph: new_graph,
      new_section: new_section,
      new_revision: new_revision
    }
  end

  defp child_list(graph, document) do
    Enum.find_value(Graph.triples(graph), fn
      {^document, predicate, object} ->
        if predicate == DOC.children(), do: object

      _triple ->
        nil
    end)
  end
end
