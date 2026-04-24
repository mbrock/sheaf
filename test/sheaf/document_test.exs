defmodule Sheaf.DocumentTest do
  use ExUnit.Case, async: true

  alias Sheaf.Document
  alias RDF.NS.RDFS
  alias Sheaf.NS.DOC

  test "navigates nested document blocks in RDF list order" do
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
        {thesis, RDFS.label(), RDF.literal("Example Thesis")},
        {thesis, DOC.children(), root_list},
        {intro, RDF.type(), DOC.Section},
        {intro, RDFS.label(), RDF.literal("Introduction")},
        {intro, DOC.children(), intro_list},
        {first_paragraph, RDF.type(), DOC.ParagraphBlock},
        {first_paragraph, DOC.paragraph(), first_paragraph_revision},
        {first_paragraph_revision, RDF.type(), DOC.Paragraph},
        {first_paragraph_revision, DOC.text(), RDF.literal("Opening paragraph.")},
        {nested_section, RDF.type(), DOC.Section},
        {nested_section, RDFS.label(), RDF.literal("Research Questions")},
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

    assert Document.title(graph, thesis) == "Example Thesis"
    assert Document.kind(graph, thesis) == :thesis

    assert [^intro, ^tail_paragraph] = Document.children(graph, thesis)
    assert Document.block_type(graph, intro) == :section
    assert Document.heading(graph, intro) == "Introduction"
    assert Document.block_type(graph, tail_paragraph) == :paragraph
    assert Document.paragraph_text(graph, tail_paragraph) == "Trailing paragraph."

    assert [^first_paragraph, ^nested_section] = Document.children(graph, intro)
    assert Document.block_type(graph, first_paragraph) == :paragraph
    assert Document.paragraph_text(graph, first_paragraph) == "Opening paragraph."
    assert Document.block_type(graph, nested_section) == :section
    assert Document.heading(graph, nested_section) == "Research Questions"

    assert [^nested_paragraph] = Document.children(graph, nested_section)
    assert Document.paragraph_text(graph, nested_paragraph) == "Nested paragraph."

    assert [
             %{
               id: "SEC111",
               title: "Introduction",
               number: [1],
               children: [
                 %{
                   id: "SEC222",
                   title: "Research Questions",
                   number: [1, 1],
                   children: []
                 }
               ]
             }
           ] = Document.toc(graph, thesis)
  end

  test "returns ordered readable text chunks and DOI candidates for imported papers" do
    paper = RDF.IRI.new!("https://example.com/sheaf/PAPER1")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LSTROOT")
    title_block = RDF.IRI.new!("https://example.com/sheaf/BLKTITLE")
    body_section = RDF.IRI.new!("https://example.com/sheaf/SEC1")
    body_list = RDF.IRI.new!("https://example.com/sheaf/LSTSEC1")
    body_block = RDF.IRI.new!("https://example.com/sheaf/BLKBODY")

    graph =
      RDF.Graph.new([
        {paper, RDF.type(), DOC.Document},
        {paper, RDF.type(), DOC.Paper},
        {paper, DOC.children(), root_list},
        {title_block, RDF.type(), DOC.ExtractedBlock},
        {title_block, DOC.sourceBlockType(), RDF.literal("Text")},
        {title_block, DOC.sourcePage(), RDF.literal(1)},
        {title_block, DOC.sourceHtml(),
         RDF.literal("<p>Example Paper DOI: 10.1177/1749975520923521.</p>")},
        {body_section, RDF.type(), DOC.Section},
        {body_section, RDFS.label(), RDF.literal("Introduction")},
        {body_section, DOC.children(), body_list},
        {body_block, RDF.type(), DOC.ExtractedBlock},
        {body_block, DOC.sourceBlockType(), RDF.literal("Text")},
        {body_block, DOC.sourceHtml(), RDF.literal("<p>Body &amp; argument.</p>")}
      ])
      |> then(fn graph ->
        RDF.list([title_block, body_section], graph: graph, head: root_list).graph
      end)
      |> then(fn graph -> RDF.list([body_block], graph: graph, head: body_list).graph end)

    assert [
             %{id: "BLKTITLE", source_page: 1, source_type: "Text", text: title},
             %{id: "SEC1", type: :section, text: "Introduction"},
             %{id: "BLKBODY", text: "Body & argument."}
           ] = Document.text_chunks(graph, paper)

    assert title == "Example Paper DOI: 10.1177/1749975520923521."
    assert Document.text_preview(graph, paper, chars: 32) == "Example Paper DOI: 10.1177/17499"
    assert Document.doi_candidates(graph, paper, chars: 200) == ["10.1177/1749975520923521"]
  end
end
