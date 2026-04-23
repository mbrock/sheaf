defmodule Sheaf.GraphMigrationTest do
  use ExUnit.Case, async: true

  alias Sheaf.GraphMigration
  alias Sheaf.NS.Sheaf, as: SheafNS

  @rdf_ns "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

  test "migrate_rows rewrites inline text blocks to paragraph revisions" do
    root_seq = RDF.IRI.new!("https://example.com/sheaf/SEQ123")
    paragraph_block = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    utterance = RDF.IRI.new!("https://example.com/sheaf/UTT111")

    rows = [
      triple(root_seq, membership_iri(1), paragraph_block),
      triple(paragraph_block, RDF.type(), resolve(SheafNS.Paragraph)),
      triple(paragraph_block, SheafNS.text(), RDF.literal("Opening paragraph.")),
      triple(utterance, RDF.type(), resolve(SheafNS.Paragraph)),
      triple(utterance, RDF.type(), resolve(SheafNS.Utterance)),
      triple(utterance, SheafNS.text(), RDF.literal("Spoken text.")),
      triple(utterance, SheafNS.speaker(), RDF.literal("S1"))
    ]

    assert {:ok, result} = GraphMigration.migrate_rows(rows)

    serialized = RDF.NTriples.write_string!(result.graph)

    assert result.migrated_blocks == 2
    assert String.contains?(serialized, "https://less.rest/sheaf/ParagraphBlock")
    assert String.contains?(serialized, "https://less.rest/sheaf/paragraph")
    assert String.contains?(serialized, "http://www.w3.org/ns/prov#Entity")

    refute String.contains?(
             serialized,
             "<https://example.com/sheaf/PAR111> <https://less.rest/sheaf/text>"
           )

    refute String.contains?(
             serialized,
             "<https://example.com/sheaf/UTT111> <https://less.rest/sheaf/text>"
           )
  end

  defp triple(subject, predicate, object) do
    %{"s" => subject, "p" => predicate, "o" => object}
  end

  defp membership_iri(position) do
    RDF.IRI.new!("#{@rdf_ns}_#{position}")
  end

  defp resolve(term) do
    RDF.Namespace.resolve_term!(term)
  end
end
