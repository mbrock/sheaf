defmodule Sheaf.ThesisTest do
  use ExUnit.Case, async: true

  alias Sheaf.Thesis
  alias Sheaf.NS.Sheaf, as: SheafNS

  @rdf_ns "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

  test "from_graph reconstructs nested blocks in rdf:Seq order" do
    thesis = RDF.IRI.new!("https://example.com/sheaf/DOC123")
    root_seq = RDF.IRI.new!("https://example.com/sheaf/SEQ123")
    intro = RDF.IRI.new!("https://example.com/sheaf/SEC111")
    intro_seq = RDF.IRI.new!("https://example.com/sheaf/SEQ111")
    first_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    first_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV1111")
    nested_section = RDF.IRI.new!("https://example.com/sheaf/SEC222")
    nested_seq = RDF.IRI.new!("https://example.com/sheaf/SEQ222")
    nested_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR222")
    nested_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV2222")
    tail_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR333")
    tail_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV3333")

    graph =
      RDF.Graph.new([
        {thesis, RDF.type(), SheafNS.Document},
        {thesis, RDF.type(), SheafNS.Thesis},
        {thesis, SheafNS.title(), RDF.literal("Example Thesis")},
        {thesis, SheafNS.children(), root_seq},
        {root_seq, membership_iri(2), tail_paragraph},
        {root_seq, membership_iri(1), intro},
        {intro, RDF.type(), SheafNS.Section},
        {intro, SheafNS.heading(), RDF.literal("Introduction")},
        {intro, SheafNS.children(), intro_seq},
        {intro_seq, membership_iri(2), nested_section},
        {intro_seq, membership_iri(1), first_paragraph},
        {first_paragraph, RDF.type(), SheafNS.ParagraphBlock},
        {first_paragraph, SheafNS.paragraph(), first_paragraph_revision},
        {first_paragraph_revision, RDF.type(), SheafNS.Paragraph},
        {first_paragraph_revision, SheafNS.text(), RDF.literal("Opening paragraph.")},
        {nested_section, RDF.type(), SheafNS.Section},
        {nested_section, SheafNS.heading(), RDF.literal("Research Questions")},
        {nested_section, SheafNS.children(), nested_seq},
        {nested_seq, membership_iri(1), nested_paragraph},
        {nested_paragraph, RDF.type(), SheafNS.ParagraphBlock},
        {nested_paragraph, SheafNS.paragraph(), nested_paragraph_revision},
        {nested_paragraph_revision, RDF.type(), SheafNS.Paragraph},
        {nested_paragraph_revision, SheafNS.text(), RDF.literal("Nested paragraph.")},
        {tail_paragraph, RDF.type(), SheafNS.ParagraphBlock},
        {tail_paragraph, SheafNS.paragraph(), tail_paragraph_revision},
        {tail_paragraph_revision, RDF.type(), SheafNS.Paragraph},
        {tail_paragraph_revision, SheafNS.text(), RDF.literal("Trailing paragraph.")}
      ])

    document = Thesis.from_graph(graph)

    assert document.title == "Example Thesis"
    assert document.kind == :thesis

    assert [
             %{type: :section, heading: "Introduction"},
             %{type: :paragraph, text: "Trailing paragraph."}
           ] =
             document.children

    [intro_block, trailing_block] = document.children

    assert [
             %{type: :paragraph, text: "Opening paragraph."},
             %{type: :section, heading: "Research Questions"}
           ] =
             intro_block.children

    assert trailing_block.text == "Trailing paragraph."

    assert [%{type: :paragraph, text: "Nested paragraph."}] =
             Enum.at(intro_block.children, 1).children
  end

  defp membership_iri(position) do
    RDF.IRI.new!("#{@rdf_ns}_#{position}")
  end
end
