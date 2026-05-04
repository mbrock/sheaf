defmodule SheafWeb.DocumentLiveTest do
  use ExUnit.Case, async: true

  alias RDF.NS.RDFS
  alias Sheaf.Id
  alias Sheaf.NS.DOC
  alias SheafWeb.DocumentLive

  test "numbers paragraphs within their surrounding section" do
    thesis = RDF.IRI.new!("https://example.com/sheaf/DOC123")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LST123")
    first_section = RDF.IRI.new!("https://example.com/sheaf/SEC111")
    first_section_list = RDF.IRI.new!("https://example.com/sheaf/LST111")
    first_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    first_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV1111")
    nested_section = RDF.IRI.new!("https://example.com/sheaf/SEC222")
    nested_section_list = RDF.IRI.new!("https://example.com/sheaf/LST222")
    nested_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR222")
    nested_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV2222")
    second_section = RDF.IRI.new!("https://example.com/sheaf/SEC333")
    second_section_list = RDF.IRI.new!("https://example.com/sheaf/LST333")
    second_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR333")
    second_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV3333")
    root_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR444")
    root_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV4444")

    graph =
      RDF.Graph.new([
        {thesis, RDF.type(), DOC.Document},
        {thesis, RDFS.label(), RDF.literal("Example Thesis")},
        {thesis, DOC.children(), root_list},
        {first_section, RDF.type(), DOC.Section},
        {first_section, RDFS.label(), RDF.literal("First")},
        {first_section, DOC.children(), first_section_list},
        {first_paragraph, RDF.type(), DOC.ParagraphBlock},
        {first_paragraph, DOC.paragraph(), first_paragraph_revision},
        {first_paragraph_revision, RDF.type(), DOC.Paragraph},
        {first_paragraph_revision, DOC.text(), RDF.literal("First paragraph.")},
        {nested_section, RDF.type(), DOC.Section},
        {nested_section, RDFS.label(), RDF.literal("Nested")},
        {nested_section, DOC.children(), nested_section_list},
        {nested_paragraph, RDF.type(), DOC.ParagraphBlock},
        {nested_paragraph, DOC.paragraph(), nested_paragraph_revision},
        {nested_paragraph_revision, RDF.type(), DOC.Paragraph},
        {nested_paragraph_revision, DOC.text(), RDF.literal("Nested paragraph.")},
        {second_section, RDF.type(), DOC.Section},
        {second_section, RDFS.label(), RDF.literal("Second")},
        {second_section, DOC.children(), second_section_list},
        {second_paragraph, RDF.type(), DOC.ParagraphBlock},
        {second_paragraph, DOC.paragraph(), second_paragraph_revision},
        {second_paragraph_revision, RDF.type(), DOC.Paragraph},
        {second_paragraph_revision, DOC.text(), RDF.literal("Second paragraph.")},
        {root_paragraph, RDF.type(), DOC.ParagraphBlock},
        {root_paragraph, DOC.paragraph(), root_paragraph_revision},
        {root_paragraph_revision, RDF.type(), DOC.Paragraph},
        {root_paragraph_revision, DOC.text(), RDF.literal("Root paragraph.")}
      ])
      |> then(fn graph ->
        RDF.list([first_section, root_paragraph, second_section], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([first_paragraph, nested_section], graph: graph, head: first_section_list).graph
      end)
      |> then(fn graph ->
        RDF.list([nested_paragraph], graph: graph, head: nested_section_list).graph
      end)
      |> then(fn graph ->
        RDF.list([second_paragraph], graph: graph, head: second_section_list).graph
      end)

    [
      %{
        type: :document,
        children: [
          %{type: :section, number: [1], children: first_children},
          %{type: :paragraph, number: 1},
          %{type: :section, number: [2], children: second_children}
        ]
      }
    ] = DocumentLive.document_blocks(graph, thesis)

    [
      %{type: :paragraph, number: 1},
      %{type: :section, number: [1, 1], children: [%{type: :paragraph, number: 1}]}
    ] = first_children

    [%{type: :paragraph, number: 1}] = second_children
  end

  test "keeps extracted blocks in document order" do
    paper = RDF.IRI.new!("https://example.com/sheaf/DOC123")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LST123")
    section = RDF.IRI.new!("https://example.com/sheaf/SEC111")
    section_list = RDF.IRI.new!("https://example.com/sheaf/LST111")
    block = RDF.IRI.new!("https://example.com/sheaf/BLK111")
    picture = RDF.IRI.new!("https://example.com/sheaf/PIC111")
    paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV1111")

    graph =
      RDF.Graph.new([
        {paper, RDF.type(), DOC.Document},
        {paper, RDF.type(), DOC.Paper},
        {paper, RDFS.label(), RDF.literal("Example Paper")},
        {paper, DOC.children(), root_list},
        {section, RDF.type(), DOC.Section},
        {section, RDFS.label(), RDF.literal("Introduction")},
        {section, DOC.children(), section_list},
        {block, RDF.type(), DOC.ExtractedBlock},
        {block, DOC.sourceBlockType(), RDF.literal("Text")},
        {block, DOC.sourceHtml(), RDF.literal("<p>Extracted text.</p>")},
        {picture, RDF.type(), DOC.ExtractedBlock},
        {picture, DOC.sourceBlockType(), RDF.literal("Picture")},
        {picture, DOC.sourceHtml(), RDF.literal("<p><img src=\"figure.png\"></p>")},
        {paragraph, RDF.type(), DOC.ParagraphBlock},
        {paragraph, DOC.paragraph(), paragraph_revision},
        {paragraph_revision, RDF.type(), DOC.Paragraph},
        {paragraph_revision, DOC.text(), RDF.literal("Paragraph text.")}
      ])
      |> then(fn graph -> RDF.list([section], graph: graph, head: root_list).graph end)
      |> then(fn graph ->
        RDF.list([block, picture, paragraph], graph: graph, head: section_list).graph
      end)

    [
      %{
        type: :document,
        children: [
          %{
            type: :section,
            children: [
              %{type: :extracted, source_type: "Text", number: 1},
              %{type: :extracted, source_type: "Picture"} = picture_block,
              %{type: :paragraph, number: 2}
            ]
          }
        ]
      }
    ] = DocumentLive.document_blocks(graph, paper)

    refute Map.has_key?(picture_block, :number)
  end

  test "aggregates paragraph tags into section toc entries" do
    thesis = RDF.IRI.new!("https://example.com/sheaf/DOC123")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LST123")
    section = RDF.IRI.new!("https://example.com/sheaf/SEC111")
    section_list = RDF.IRI.new!("https://example.com/sheaf/LST111")
    paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV1111")

    graph =
      RDF.Graph.new([
        {thesis, RDF.type(), DOC.Document},
        {thesis, DOC.children(), root_list},
        {section, RDF.type(), DOC.Section},
        {section, RDFS.label(), RDF.literal("Tagged section")},
        {section, DOC.children(), section_list},
        {paragraph, RDF.type(), DOC.ParagraphBlock},
        {paragraph, DOC.paragraph(), paragraph_revision},
        {paragraph_revision, RDF.type(), DOC.Paragraph},
        {paragraph_revision, DOC.text(), RDF.literal("Needs evidence.")}
      ])
      |> then(fn graph -> RDF.list([section], graph: graph, head: root_list).graph end)
      |> then(fn graph -> RDF.list([paragraph], graph: graph, head: section_list).graph end)

    [entry] =
      graph
      |> Sheaf.Document.toc(thesis)
      |> DocumentLive.tagged_toc_entries(graph, %{
        Id.id_from_iri(paragraph) => [
          %{name: "needs_evidence", label: "needs evidence"},
          %{name: "fragment", label: "fragment"}
        ]
      })

    assert entry.tags == [
             %{name: "needs_evidence", label: "needs evidence"},
             %{name: "fragment", label: "fragment"}
           ]
  end
end
