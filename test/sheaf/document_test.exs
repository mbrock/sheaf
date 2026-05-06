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

    first_paragraph_revision =
      RDF.IRI.new!("https://example.com/sheaf/PV1111")

    nested_section = RDF.IRI.new!("https://example.com/sheaf/SEC222")
    nested_list = RDF.IRI.new!("https://example.com/sheaf/LST222")
    nested_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR222")

    nested_paragraph_revision =
      RDF.IRI.new!("https://example.com/sheaf/PV2222")

    tail_paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR333")
    tail_paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV3333")
    row = RDF.IRI.new!("https://example.com/sheaf/ROW444")

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
        {first_paragraph_revision, DOC.text(),
         RDF.literal("Opening paragraph.")},
        {nested_section, RDF.type(), DOC.Section},
        {nested_section, RDFS.label(), RDF.literal("Research Questions")},
        {nested_section, DOC.children(), nested_list},
        {nested_paragraph, RDF.type(), DOC.ParagraphBlock},
        {nested_paragraph, DOC.paragraph(), nested_paragraph_revision},
        {nested_paragraph_revision, RDF.type(), DOC.Paragraph},
        {nested_paragraph_revision, DOC.text(),
         RDF.literal("Nested paragraph.")},
        {tail_paragraph, RDF.type(), DOC.ParagraphBlock},
        {tail_paragraph, DOC.paragraph(), tail_paragraph_revision},
        {tail_paragraph_revision, RDF.type(), DOC.Paragraph},
        {tail_paragraph_revision, DOC.text(),
         RDF.literal("Trailing paragraph.")},
        {row, RDF.type(), DOC.Row},
        {row, DOC.text(), RDF.literal("Spreadsheet row text.")}
      ])
      |> then(fn graph ->
        RDF.list([intro, tail_paragraph, row], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([first_paragraph, nested_section],
          graph: graph,
          head: intro_list
        ).graph
      end)
      |> then(fn graph ->
        RDF.list([nested_paragraph], graph: graph, head: nested_list).graph
      end)

    assert Document.title(graph, thesis) == "Example Thesis"
    assert Document.kind(graph, thesis) == :thesis

    assert [^intro, ^tail_paragraph, ^row] = Document.children(graph, thesis)
    assert Document.block_type(graph, intro) == :section
    assert Document.heading(graph, intro) == "Introduction"
    assert Document.block_type(graph, tail_paragraph) == :paragraph

    assert Document.paragraph_text(graph, tail_paragraph) ==
             "Trailing paragraph."

    assert Document.block_type(graph, row) == :row
    assert Document.text(graph, row) == "Spreadsheet row text."

    assert [^first_paragraph, ^nested_section] =
             Document.children(graph, intro)

    assert Document.block_type(graph, first_paragraph) == :paragraph

    assert Document.paragraph_text(graph, first_paragraph) ==
             "Opening paragraph."

    assert Document.block_type(graph, nested_section) == :section
    assert Document.heading(graph, nested_section) == "Research Questions"

    assert [^nested_paragraph] = Document.children(graph, nested_section)

    assert Document.paragraph_text(graph, nested_paragraph) ==
             "Nested paragraph."

    assert [
             %{id: "SEC111", type: :section, text: "Introduction"},
             %{id: "PAR111", type: :paragraph, text: "Opening paragraph."},
             %{id: "SEC222", type: :section, text: "Research Questions"},
             %{id: "PAR222", type: :paragraph, text: "Nested paragraph."},
             %{id: "PAR333", type: :paragraph, text: "Trailing paragraph."},
             %{id: "ROW444", type: :row, text: "Spreadsheet row text."}
           ] = Document.text_chunks(graph, thesis)

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

  test "returns sanitized inline paragraph markup when present" do
    block = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    paragraph = RDF.IRI.new!("https://example.com/sheaf/PV1111")

    graph =
      RDF.Graph.new([
        {block, RDF.type(), DOC.ParagraphBlock},
        {block, DOC.paragraph(), paragraph},
        {block, DOC.markup(),
         RDF.literal(
           ~S"""
           Plain <strong onclick="bad()">strong</strong> <em>em</em> <mark>mark</mark> <a href="https://example.com/?a=1&b=2" onclick="bad()">link</a> <sup data-footnote="12" onclick="bad()"></sup> <sup data-footnote="ABCD23"></sup> <script>alert("x")</script>
           """
           |> String.trim()
         )},
        {paragraph, RDF.type(), DOC.Paragraph},
        {paragraph, DOC.text(), RDF.literal("Plain strong em mark link.")}
      ])

    assert Document.paragraph_markup(graph, block) ==
             ~S"""
             Plain <strong>strong</strong> <em>em</em> <mark>mark</mark> <a href="https://example.com/?a=1&amp;b=2">link</a> <span data-footnote="12">[12]</span> <span data-footnote="ABCD23">[ABCD23]</span> &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;
             """
             |> String.trim()
  end

  test "returns nil paragraph markup when only plain text is present" do
    block = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    paragraph = RDF.IRI.new!("https://example.com/sheaf/PV1111")

    graph =
      RDF.Graph.new([
        {block, RDF.type(), DOC.ParagraphBlock},
        {block, DOC.paragraph(), paragraph},
        {paragraph, RDF.type(), DOC.Paragraph},
        {paragraph, DOC.text(), RDF.literal("Plain paragraph.")}
      ])

    assert Document.paragraph_markup(graph, block) == nil
  end

  test "returns paragraph footnotes in source order" do
    block = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    second = RDF.IRI.new!("https://example.com/sheaf/FN2222")
    first = RDF.IRI.new!("https://example.com/sheaf/FN1111")

    graph =
      RDF.Graph.new([
        {block, DOC.hasFootnote(), second},
        {block, DOC.hasFootnote(), first},
        {second, DOC.sourceKey(), RDF.literal("word/footnotes.xml#2")},
        {second, DOC.text(), RDF.literal("Second footnote.")},
        {first, DOC.sourceKey(), RDF.literal("word/footnotes.xml#1")},
        {first, DOC.text(), RDF.literal("First footnote.")},
        {first, DOC.markup(), RDF.literal(~s(<em>First</em> footnote.))}
      ])

    assert [
             %{
               id: "FN1111",
               source_key: "word/footnotes.xml#1",
               text: "First footnote."
             },
             %{
               id: "FN2222",
               source_key: "word/footnotes.xml#2",
               text: "Second footnote."
             }
           ] = Document.footnotes(graph, block)

    assert [%{markup: "<em>First</em> footnote."}, %{markup: nil}] =
             Document.footnotes(graph, block)
  end

  test "renders a structured document as LaTeX" do
    thesis = RDF.IRI.new!("https://example.com/sheaf/DOC123")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LST123")
    section = RDF.IRI.new!("https://example.com/sheaf/SEC111")
    section_list = RDF.IRI.new!("https://example.com/sheaf/LST111")
    paragraph = RDF.IRI.new!("https://example.com/sheaf/PAR111")
    paragraph_revision = RDF.IRI.new!("https://example.com/sheaf/PV1111")
    footnote = RDF.IRI.new!("https://example.com/sheaf/FN1111")

    graph =
      RDF.Graph.new([
        {thesis, RDF.type(), DOC.Document},
        {thesis, RDF.type(), DOC.Thesis},
        {thesis, RDFS.label(), RDF.literal("Things & Practices")},
        {thesis, DOC.children(), root_list},
        {section, RDF.type(), DOC.Section},
        {section, RDFS.label(), RDF.literal("Introduction")},
        {section, DOC.children(), section_list},
        {paragraph, RDF.type(), DOC.ParagraphBlock},
        {paragraph, DOC.paragraph(), paragraph_revision},
        {paragraph, DOC.markup(),
         RDF.literal(
           ~s(Things <em>move</em> &amp; matter <span data-footnote="1">[1]</span>.)
         )},
        {paragraph, DOC.hasFootnote(), footnote},
        {paragraph_revision, RDF.type(), DOC.Paragraph},
        {paragraph_revision, DOC.text(),
         RDF.literal("Things move and matter.")},
        {footnote, DOC.sourceKey(), RDF.literal("word/footnotes.xml#1")},
        {footnote, DOC.text(), RDF.literal("A grounded note & detail.")}
      ])
      |> then(fn graph ->
        RDF.list([section], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([paragraph], graph: graph, head: section_list).graph
      end)

    expression = RDF.IRI.new!("https://example.com/sheaf/WORK123")
    author = RDF.IRI.new!("https://example.com/sheaf/AUTHOR1")
    university = RDF.IRI.new!("https://example.com/sheaf/ORG1")
    school = RDF.IRI.new!("https://example.com/sheaf/ORG2")
    supervisor = RDF.IRI.new!("https://example.com/sheaf/SUP1")

    metadata_graph =
      RDF.Graph.new([
        {thesis, Sheaf.NS.FABIO.isRepresentationOf(), expression},
        {expression, Sheaf.NS.DCTERMS.title(), RDF.literal("Metadata Title")},
        {expression, Sheaf.NS.DCTERMS.creator(), author},
        {author, Sheaf.NS.FOAF.name(), RDF.literal("Ieva Lange")},
        {expression, DOC.awardingInstitution(), university},
        {university, Sheaf.NS.FOAF.name(), RDF.literal("Tallinn University")},
        {expression, DOC.academicUnit(), school},
        {school, Sheaf.NS.FOAF.name(), RDF.literal("School of Humanities")},
        {expression, DOC.thesisDegreeText(), RDF.literal("MA Thesis")},
        {expression, DOC.academicSupervisor(), supervisor},
        {supervisor, Sheaf.NS.FOAF.name(),
         RDF.literal("Maarja Kaaristo, PhD")},
        {expression, DOC.submissionPlace(), RDF.literal("Tallinn")},
        {expression, Sheaf.NS.FABIO.hasPublicationYear(),
         RDF.literal("2026")},
        {expression, DOC.authorshipDeclaration(),
         RDF.literal("I hereby confirm authorship.")},
        {expression, DOC.declarationDate(), RDF.literal("05.05.2026.")}
      ])

    latex =
      Sheaf.Document.LaTeX.render(graph, thesis,
        metadata_graph: metadata_graph
      )

    assert latex =~ "\\documentclass[12pt,a4paper,oneside]{report}"
    assert latex =~ "\\IfFileExists{"
    assert latex =~ "/priv/static/fonts/Times New Roman.ttf"
    assert latex =~ "UprightFont={Times New Roman.ttf}"
    assert latex =~ "BoldFont={Times New Roman Bold.ttf}"
    assert latex =~ "\\onehalfspacing"
    assert latex =~ "\\setlength{\\parindent}{1.27cm}"
    assert latex =~ "\\titleformat{\\chapter}"
    assert latex =~ "\\begin{titlepage}"
    assert latex =~ "\\title{Metadata Title}"
    assert latex =~ "Tallinn University"
    assert latex =~ "School of Humanities"
    assert latex =~ "Ieva Lange"
    assert latex =~ "MA Thesis"
    assert latex =~ "Supervisor: Maarja Kaaristo, PhD"
    assert latex =~ "Tallinn 2026"
    assert latex =~ "I hereby confirm authorship."
    assert latex =~ "Ieva Lange 05.05.2026."
    assert latex =~ "\\chapter{Introduction}"

    assert latex =~
             "Things \\emph{move} \\& matter \\footnote{A grounded note \\& detail.}."
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
        {body_block, DOC.sourceHtml(),
         RDF.literal("<p>Body &amp; argument.</p>")}
      ])
      |> then(fn graph ->
        RDF.list([title_block, body_section], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([body_block], graph: graph, head: body_list).graph
      end)

    assert [
             %{
               id: "BLKTITLE",
               source_page: 1,
               source_type: "Text",
               text: title
             },
             %{id: "SEC1", type: :section, text: "Introduction"},
             %{id: "BLKBODY", text: "Body & argument."}
           ] = Document.text_chunks(graph, paper)

    assert title == "Example Paper DOI: 10.1177/1749975520923521."

    assert Document.text_preview(graph, paper, chars: 32) ==
             "Example Paper DOI: 10.1177/17499"

    assert Document.doi_candidates(graph, paper, chars: 200) == [
             "10.1177/1749975520923521"
           ]
  end

  test "samples first source pages for bibliographic text and only includes last pages when requested" do
    paper = RDF.IRI.new!("https://example.com/sheaf/PAPER1")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LSTROOT")

    blocks =
      for page <- 1..10 do
        RDF.IRI.new!("https://example.com/sheaf/BLK#{page}")
      end

    graph =
      blocks
      |> Enum.with_index(1)
      |> Enum.reduce(
        RDF.Graph.new([
          {paper, RDF.type(), DOC.Document},
          {paper, RDF.type(), DOC.Paper},
          {paper, DOC.children(), root_list}
        ]),
        fn {block, page}, graph ->
          text =
            if page == 10,
              do: "Page 10 DOI 10.1000/LAST.",
              else: "Page #{page}"

          graph
          |> RDF.Graph.add({block, RDF.type(), DOC.ExtractedBlock})
          |> RDF.Graph.add({block, DOC.sourcePage(), RDF.literal(page)})
          |> RDF.Graph.add(
            {block, DOC.sourceHtml(), RDF.literal("<p>#{text}</p>")}
          )
        end
      )
      |> then(fn graph ->
        RDF.list(blocks, graph: graph, head: root_list).graph
      end)

    assert Document.bibliographic_text(graph, paper, first_pages: 2) ==
             "Page 1\n\nPage 2"

    assert Document.bibliographic_text(graph, paper,
             first_pages: 2,
             last_pages: 2
           ) ==
             "Page 1\n\nPage 2\n\nPage 9\n\nPage 10 DOI 10.1000/LAST."

    assert Document.doi_candidates(graph, paper, first_pages: 1) == []

    assert Document.doi_candidates(graph, paper,
             first_pages: 1,
             last_pages: 1
           ) == [
             "10.1000/last"
           ]
  end

  test "samples first chunks when source pages are absent and only includes last chunks when requested" do
    paper = RDF.IRI.new!("https://example.com/sheaf/PAPER1")
    root_list = RDF.IRI.new!("https://example.com/sheaf/LSTROOT")

    blocks =
      for index <- 1..5 do
        RDF.IRI.new!("https://example.com/sheaf/BLK#{index}")
      end

    graph =
      blocks
      |> Enum.with_index(1)
      |> Enum.reduce(
        RDF.Graph.new([
          {paper, RDF.type(), DOC.Document},
          {paper, RDF.type(), DOC.Paper},
          {paper, DOC.children(), root_list}
        ]),
        fn {block, index}, graph ->
          graph
          |> RDF.Graph.add({block, RDF.type(), DOC.ExtractedBlock})
          |> RDF.Graph.add(
            {block, DOC.sourceHtml(), RDF.literal("<p>Chunk #{index}</p>")}
          )
        end
      )
      |> then(fn graph ->
        RDF.list(blocks, graph: graph, head: root_list).graph
      end)

    assert Document.bibliographic_text(graph, paper, first_chunks: 2) ==
             "Chunk 1\n\nChunk 2"

    assert Document.bibliographic_text(graph, paper,
             first_chunks: 2,
             last_chunks: 2
           ) ==
             "Chunk 1\n\nChunk 2\n\nChunk 4\n\nChunk 5"
  end
end
