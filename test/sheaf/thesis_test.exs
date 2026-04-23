defmodule Sheaf.ThesisTest do
  use ExUnit.Case, async: true

  alias Sheaf.Thesis
  alias Sheaf.NS.Sheaf, as: SheafNS

  @rdf_ns "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

  test "from_rows reconstructs nested blocks in rdf:Seq order" do
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

    rows = [
      triple(thesis, RDF.type(), resolve(SheafNS.Document)),
      triple(thesis, RDF.type(), resolve(SheafNS.Thesis)),
      triple(thesis, SheafNS.title(), RDF.literal("Example Thesis")),
      triple(thesis, SheafNS.children(), root_seq),
      triple(root_seq, membership_iri(2), tail_paragraph),
      triple(root_seq, membership_iri(1), intro),
      triple(intro, RDF.type(), resolve(SheafNS.Section)),
      triple(intro, SheafNS.heading(), RDF.literal("Introduction")),
      triple(intro, SheafNS.children(), intro_seq),
      triple(intro_seq, membership_iri(2), nested_section),
      triple(intro_seq, membership_iri(1), first_paragraph),
      triple(first_paragraph, RDF.type(), resolve(SheafNS.ParagraphBlock)),
      triple(first_paragraph, SheafNS.paragraph(), first_paragraph_revision),
      triple(first_paragraph_revision, RDF.type(), resolve(SheafNS.Paragraph)),
      triple(first_paragraph_revision, SheafNS.text(), RDF.literal("Opening paragraph.")),
      triple(nested_section, RDF.type(), resolve(SheafNS.Section)),
      triple(nested_section, SheafNS.heading(), RDF.literal("Research Questions")),
      triple(nested_section, SheafNS.children(), nested_seq),
      triple(nested_seq, membership_iri(1), nested_paragraph),
      triple(nested_paragraph, RDF.type(), resolve(SheafNS.ParagraphBlock)),
      triple(nested_paragraph, SheafNS.paragraph(), nested_paragraph_revision),
      triple(nested_paragraph_revision, RDF.type(), resolve(SheafNS.Paragraph)),
      triple(nested_paragraph_revision, SheafNS.text(), RDF.literal("Nested paragraph.")),
      triple(tail_paragraph, RDF.type(), resolve(SheafNS.ParagraphBlock)),
      triple(tail_paragraph, SheafNS.paragraph(), tail_paragraph_revision),
      triple(tail_paragraph_revision, RDF.type(), resolve(SheafNS.Paragraph)),
      triple(tail_paragraph_revision, SheafNS.text(), RDF.literal("Trailing paragraph."))
    ]

    document = Thesis.from_rows(rows)

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
