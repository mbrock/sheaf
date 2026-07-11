defmodule Sheaf.DocumentMetadataTest do
  use ExUnit.Case, async: true

  use RDF

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.DocumentMetadata
  alias Sheaf.NS.{DCTERMS, FABIO, FOAF}

  test "replaces supplied bibliographic fields and preserves unrelated metadata" do
    document = ~I<https://example.com/document>
    expression = ~I<https://example.com/expression>
    old_author = ~I<https://example.com/old-author>
    graph_name = ~I<https://example.com/metadata>

    graph =
      Graph.new(
        [
          {document, FABIO.isRepresentationOf(), expression},
          {expression, RDF.type(), FABIO.JournalArticle},
          {expression, DCTERMS.title(), RDF.literal("Old title")},
          {expression, DCTERMS.creator(), old_author},
          {expression, DCTERMS.identifier(), RDF.literal("keep-me")}
        ],
        name: graph_name
      )

    {updated, ^expression, fields} =
      DocumentMetadata.apply_metadata(graph, document, %{
        "kind" => "report",
        "title" => "New title",
        "authors" => ["Ada Example"],
        "year" => "2024"
      })

    assert fields == [:kind, :title, :authors, :year]

    assert RDF.Data.include?(
             updated,
             {expression, RDF.type(), FABIO.ReportDocument}
           )

    assert RDF.Data.include?(
             updated,
             {expression, DCTERMS.title(), RDF.literal("New title")}
           )

    assert RDF.Data.include?(
             updated,
             {expression, RDFS.label(), RDF.literal("New title")}
           )

    assert RDF.Data.include?(
             updated,
             {expression, FABIO.hasPublicationYear(), RDF.literal("2024")}
           )

    assert RDF.Data.include?(
             updated,
             {expression, DCTERMS.identifier(), RDF.literal("keep-me")}
           )

    refute RDF.Data.include?(
             updated,
             {expression, DCTERMS.creator(), old_author}
           )

    foaf_name = FOAF.name()

    assert Enum.any?(Graph.triples(updated), fn
             {agent, ^foaf_name, name} ->
               RDF.Literal.value(name) == "Ada Example" and
                 RDF.Data.include?(
                   updated,
                   {expression, DCTERMS.creator(), agent}
                 )

             _ ->
               false
           end)
  end

  test "cover-only updates do not invent bibliographic metadata" do
    document = ~I<https://example.com/document>
    graph = Graph.new(name: ~I<https://example.com/metadata>)

    {updated, expression, fields} =
      DocumentMetadata.apply_metadata(graph, document, %{
        "cover_image_id" => "IMG123"
      })

    assert updated == graph
    assert expression == nil
    assert fields == []
  end
end
