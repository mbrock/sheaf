defmodule Sheaf.ThesisTest do
  use ExUnit.Case, async: true

  alias Sheaf.Thesis
  alias Sheaf.DOC

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
        {thesis, RDF.type(), DOC.Document},
        {thesis, RDF.type(), DOC.Thesis},
        {thesis, DOC.title(), RDF.literal("Example Thesis")},
        {thesis, DOC.children(), root_list},
        {intro, RDF.type(), DOC.Section},
        {intro, DOC.heading(), RDF.literal("Introduction")},
        {intro, DOC.children(), intro_list},
        {first_paragraph, RDF.type(), DOC.ParagraphBlock},
        {first_paragraph, DOC.paragraph(), first_paragraph_revision},
        {first_paragraph_revision, RDF.type(), DOC.Paragraph},
        {first_paragraph_revision, DOC.text(), RDF.literal("Opening paragraph.")},
        {nested_section, RDF.type(), DOC.Section},
        {nested_section, DOC.heading(), RDF.literal("Research Questions")},
        {nested_section, DOC.children(), nested_list},
        {nested_paragraph, RDF.type(), DOC.ParagraphBlock},
        {nested_paragraph, DOC.paragraph(), nested_paragraph_revision},
        {nested_paragraph_revision, RDF.type(), DOC.Paragraph},
        {nested_paragraph_revision, DOC.text(), RDF.literal("Nested paragraph.")},
        {tail_paragraph, RDF.type(), DOC.ParagraphBlock},
        {tail_paragraph, DOC.paragraph(), tail_paragraph_revision},
        {tail_paragraph_revision, RDF.type(), DOC.Paragraph},
        {tail_paragraph_revision, DOC.text(), RDF.literal("Trailing paragraph.")}
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
