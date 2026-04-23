defmodule Sheaf.ThesisTest do
  use ExUnit.Case, async: true

  alias Sheaf.Thesis
  alias Sheaf.NS.SHEAF

  test "from_graph reconstructs nested blocks in RDF list order" do
    thesis = RDF.IRI.new!("https://example.com/sheaf/DOC123")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LST123")
    intro = RDF.IRI.new!("https://example.com/sheaf/SEC111")
    intro_list = RDF.IRI.new!("https://example.com/sheaf/LST111")
    first_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    first_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV1111")
    nested_section = RDF.IRI.new!("https://example.com/sheaf/SEC222")
    nested_list = RDF.IRI.new!("https://example.com/sheaf/LST222")
    nested_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR222")
    nested_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV2222")
    tail_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR333")
    tail_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV3333")

    graph =
      RDF.Graph.new([
        {thesis, RDF.type(), SHEAF.Document},
        {thesis, RDF.type(), SHEAF.Thesis},
        {thesis, SHEAF.title(), RDF.literal("Example Thesis")},
        {thesis, SHEAF.children(), root_list},
        {intro, RDF.type(), SHEAF.Section},
        {intro, SHEAF.heading(), RDF.literal("Introduction")},
        {intro, SHEAF.children(), intro_list},
        {first_paragraph, RDF.type(), SHEAF.ParagraphBlock},
        {first_paragraph, SHEAF.paragraph(), first_paragraph_revision},
        {first_paragraph_revision, RDF.type(), SHEAF.Paragraph},
        {first_paragraph_revision, SHEAF.text(), RDF.literal("Opening paragraph.")},
        {nested_section, RDF.type(), SHEAF.Section},
        {nested_section, SHEAF.heading(), RDF.literal("Research Questions")},
        {nested_section, SHEAF.children(), nested_list},
        {nested_paragraph, RDF.type(), SHEAF.ParagraphBlock},
        {nested_paragraph, SHEAF.paragraph(), nested_paragraph_revision},
        {nested_paragraph_revision, RDF.type(), SHEAF.Paragraph},
        {nested_paragraph_revision, SHEAF.text(), RDF.literal("Nested paragraph.")},
        {tail_paragraph, RDF.type(), SHEAF.ParagraphBlock},
        {tail_paragraph, SHEAF.paragraph(), tail_paragraph_revision},
        {tail_paragraph_revision, RDF.type(), SHEAF.Paragraph},
        {tail_paragraph_revision, SHEAF.text(), RDF.literal("Trailing paragraph.")}
      ])
      |> then(fn graph ->
        RDF.list([intro, tail_paragraph], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([first_paragraph, nested_section], graph: graph, head: intro_list).graph
      end)
      |> then(fn graph -> RDF.list([nested_paragraph], graph: graph, head: nested_list).graph end)

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
end
