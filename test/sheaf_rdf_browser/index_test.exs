defmodule SheafRDFBrowser.IndexTest do
  use ExUnit.Case, async: true

  alias RDF.Serialization
  alias SheafRDFBrowser.Index

  test "prefers labels from the term's own ontology graph over data graph labels" do
    dataset =
      """
      <https://less.rest/sheaf/Document> <http://www.w3.org/2000/01/rdf-schema#label> "document"@en <https://less.rest/sheaf/> .
      <https://less.rest/sheaf/Document> <http://www.w3.org/2000/01/rdf-schema#label> "Document" <https://sheaf.less.rest/42YBLA> .
      """
      |> String.split("\n", trim: true)
      |> Stream.map(&(&1 <> "\n"))
      |> Serialization.read_stream!(media_type: "application/n-quads")

    index = Index.build(dataset)

    assert Index.display_term(index, "https://less.rest/sheaf/Document").label == "document"
  end

  test "property rows include only properties used as predicates" do
    dataset =
      """
      <https://less.rest/sheaf/unused> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/1999/02/22-rdf-syntax-ns#Property> <https://less.rest/sheaf/> .
      <https://less.rest/sheaf/unused> <http://www.w3.org/2000/01/rdf-schema#label> "unused property"@en <https://less.rest/sheaf/> .
      <https://less.rest/sheaf/used> <http://www.w3.org/2000/01/rdf-schema#label> "used property"@en <https://less.rest/sheaf/> .
      """
      |> String.split("\n", trim: true)
      |> Stream.map(&(&1 <> "\n"))
      |> Serialization.read_stream!(media_type: "application/n-quads")

    properties =
      dataset
      |> Index.build()
      |> Index.with_predicate_counts(%{"https://less.rest/sheaf/used" => 12})
      |> Index.property_rows()

    ids = Enum.map(properties, & &1.id)

    assert "https://less.rest/sheaf/used" in ids
    assert Enum.find(properties, &(&1.id == "https://less.rest/sheaf/used")).count == 12
    refute "https://less.rest/sheaf/unused" in ids
  end

  test "display terms expose unknown namespaces separately from local names" do
    term = "https://example.test/vocab/SomeClass"
    display = Index.display_term(Index.empty(), term)

    assert display.name == "SomeClass"
    assert display.namespace == "https://example.test/vocab/"
    assert display.prefix == nil
  end
end
