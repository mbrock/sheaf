defmodule SheafWeb.DocumentLiveTest do
  use ExUnit.Case, async: false

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

  test "saves a plain paragraph edit as a new active revision" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-live-edit-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    Sheaf.Documents.clear_cache()

    on_exit(fn ->
      Sheaf.Documents.clear_cache()
    end)

    thesis = Id.iri("DLV001")
    root_list = Id.iri("DLVL01")
    paragraph = Id.iri("DLVP01")
    revision = Id.iri("DLVR01")

    graph =
      RDF.Graph.new(
        [
          {thesis, RDF.type(), DOC.Document},
          {thesis, RDFS.label(), RDF.literal("Editable thesis")},
          {thesis, DOC.children(), root_list},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.paragraph(), revision},
          {revision, RDF.type(), DOC.Paragraph},
          {revision, DOC.text(), RDF.literal("Old paragraph.")}
        ],
        name: thesis
      )
      |> then(fn graph -> RDF.list([paragraph], graph: graph, head: root_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        document_id: "DLV001",
        graph: graph,
        root: thesis,
        editing_block_id: "DLVP01",
        selected_block_id: nil,
        references_by_block: %{},
        tags_by_block: %{},
        refresh_search_indexes?: false
      }
    }

    socket = DocumentLive.save_paragraph_edit(socket, "DLVP01", "New paragraph.")

    assert socket.assigns.editing_block_id == nil
    assert socket.assigns.selected_block_id == "DLVP01"
    assert Sheaf.Document.paragraph_text(socket.assigns.graph, paragraph) == "New paragraph."
  end

  test "saves a section label edit" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-live-section-edit-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    Sheaf.Documents.clear_cache()

    on_exit(fn ->
      Sheaf.Documents.clear_cache()
    end)

    thesis = Id.iri("DLS001")
    root_list = Id.iri("DLSL01")
    section = Id.iri("DLSS01")

    graph =
      RDF.Graph.new(
        [
          {thesis, RDF.type(), DOC.Document},
          {thesis, RDFS.label(), RDF.literal("Editable sections")},
          {thesis, DOC.children(), root_list},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Old heading")}
        ],
        name: thesis
      )
      |> then(fn graph -> RDF.list([section], graph: graph, head: root_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        document_id: "DLS001",
        graph: graph,
        root: thesis,
        editing_block_id: "DLSS01",
        selected_block_id: nil,
        references_by_block: %{},
        tags_by_block: %{},
        refresh_search_indexes?: false
      }
    }

    socket = DocumentLive.save_paragraph_edit(socket, "DLSS01", "New heading")

    assert socket.assigns.editing_block_id == nil
    assert socket.assigns.selected_block_id == "DLSS01"
    assert Sheaf.Document.heading(socket.assigns.graph, section) == "New heading"
  end

  test "saves a markup paragraph edit" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-live-markup-edit-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    Sheaf.Documents.clear_cache()

    on_exit(fn ->
      Sheaf.Documents.clear_cache()
    end)

    thesis = Id.iri("DLM001")
    root_list = Id.iri("DLML01")
    paragraph = Id.iri("DLMP01")
    revision = Id.iri("DLMR01")

    graph =
      RDF.Graph.new(
        [
          {thesis, RDF.type(), DOC.Document},
          {thesis, RDFS.label(), RDF.literal("Editable markup")},
          {thesis, DOC.children(), root_list},
          {paragraph, RDF.type(), DOC.ParagraphBlock},
          {paragraph, DOC.markup(), RDF.literal("<em>Old paragraph.</em>")},
          {paragraph, DOC.paragraph(), revision},
          {revision, RDF.type(), DOC.Paragraph},
          {revision, DOC.text(), RDF.literal("Old paragraph.")}
        ],
        name: thesis
      )
      |> then(fn graph -> RDF.list([paragraph], graph: graph, head: root_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        document_id: "DLM001",
        graph: graph,
        root: thesis,
        editing_block_id: "DLMP01",
        selected_block_id: nil,
        references_by_block: %{},
        tags_by_block: %{},
        refresh_search_indexes?: false
      }
    }

    socket =
      DocumentLive.save_paragraph_markup_edit(
        socket,
        "DLMP01",
        "<strong>New</strong> <mark>paragraph</mark>."
      )

    assert socket.assigns.editing_block_id == nil
    assert socket.assigns.selected_block_id == "DLMP01"

    assert Sheaf.Document.paragraph_markup(socket.assigns.graph, paragraph) ==
             "<strong>New</strong> <mark>paragraph</mark>."

    assert Sheaf.Document.paragraph_text(socket.assigns.graph, paragraph) == "New paragraph."
  end

  test "deletes a selected paragraph block" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-live-delete-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    Sheaf.Documents.clear_cache()

    on_exit(fn ->
      Sheaf.Documents.clear_cache()
    end)

    thesis = Id.iri("DLD001")
    root_list = Id.iri("DLDL01")
    first = Id.iri("DLDP01")
    first_revision = Id.iri("DLDR01")
    second = Id.iri("DLDP02")
    second_revision = Id.iri("DLDR02")

    graph =
      RDF.Graph.new(
        [
          {thesis, RDF.type(), DOC.Document},
          {thesis, RDFS.label(), RDF.literal("Deletable thesis")},
          {thesis, DOC.children(), root_list},
          {first, RDF.type(), DOC.ParagraphBlock},
          {first, DOC.paragraph(), first_revision},
          {first_revision, RDF.type(), DOC.Paragraph},
          {first_revision, DOC.text(), RDF.literal("Delete me.")},
          {second, RDF.type(), DOC.ParagraphBlock},
          {second, DOC.paragraph(), second_revision},
          {second_revision, RDF.type(), DOC.Paragraph},
          {second_revision, DOC.text(), RDF.literal("Keep me.")}
        ],
        name: thesis
      )
      |> then(fn graph -> RDF.list([first, second], graph: graph, head: root_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        document_id: "DLD001",
        graph: graph,
        root: thesis,
        editing_block_id: nil,
        selected_block_id: "DLDP01",
        references_by_block: %{},
        tags_by_block: %{},
        refresh_search_indexes?: false
      }
    }

    socket = DocumentLive.delete_document_block(socket, "DLDP01")

    assert socket.assigns.editing_block_id == nil
    assert socket.assigns.selected_block_id == nil
    assert Sheaf.Document.children(socket.assigns.graph, thesis) == [second]
    assert Sheaf.Document.block_type(socket.assigns.graph, first) == nil
    assert Sheaf.Document.paragraph_text(socket.assigns.graph, second) == "Keep me."
  end

  test "creates a new paragraph block below the selected block and starts editing it" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-live-insert-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    Sheaf.Documents.clear_cache()

    on_exit(fn ->
      Sheaf.Documents.clear_cache()
    end)

    thesis = Id.iri("DLI001")
    root_list = Id.iri("DLIL01")
    first = Id.iri("DLIP01")
    first_revision = Id.iri("DLIR01")
    second = Id.iri("DLIP02")
    second_revision = Id.iri("DLIR02")

    graph =
      RDF.Graph.new(
        [
          {thesis, RDF.type(), DOC.Document},
          {thesis, RDFS.label(), RDF.literal("Insertable thesis")},
          {thesis, DOC.children(), root_list},
          {first, RDF.type(), DOC.ParagraphBlock},
          {first, DOC.paragraph(), first_revision},
          {first_revision, RDF.type(), DOC.Paragraph},
          {first_revision, DOC.text(), RDF.literal("First.")},
          {second, RDF.type(), DOC.ParagraphBlock},
          {second, DOC.paragraph(), second_revision},
          {second_revision, RDF.type(), DOC.Paragraph},
          {second_revision, DOC.text(), RDF.literal("Second.")}
        ],
        name: thesis
      )
      |> then(fn graph -> RDF.list([first, second], graph: graph, head: root_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        document_id: "DLI001",
        graph: graph,
        root: thesis,
        editing_block_id: nil,
        selected_block_id: "DLIP01",
        references_by_block: %{},
        tags_by_block: %{},
        refresh_search_indexes?: false
      }
    }

    socket = DocumentLive.insert_document_block_after(socket, "DLIP01")
    inserted = Id.iri(socket.assigns.selected_block_id)

    assert socket.assigns.editing_block_id == socket.assigns.selected_block_id
    assert Sheaf.Document.children(socket.assigns.graph, thesis) == [first, inserted, second]
    assert Sheaf.Document.paragraph_text(socket.assigns.graph, inserted) == ""
  end

  test "moves blocks only within their current sibling list" do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-live-move-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    Sheaf.Documents.clear_cache()

    on_exit(fn ->
      Sheaf.Documents.clear_cache()
    end)

    thesis = Id.iri("DLM001")
    root_list = Id.iri("DLML01")
    intro_section = Id.iri("DLMS00")
    intro_list = Id.iri("DLML00")
    intro_paragraph = Id.iri("DLMP00")
    intro_revision = Id.iri("DLMR00")
    section = Id.iri("DLMS01")
    section_list = Id.iri("DLML02")
    first = Id.iri("DLMP01")
    first_revision = Id.iri("DLMR01")
    second = Id.iri("DLMP02")
    second_revision = Id.iri("DLMR02")
    outside = Id.iri("DLMP03")
    outside_revision = Id.iri("DLMR03")

    graph =
      RDF.Graph.new(
        [
          {thesis, RDF.type(), DOC.Document},
          {thesis, RDFS.label(), RDF.literal("Movable thesis")},
          {thesis, DOC.children(), root_list},
          {intro_section, RDF.type(), DOC.Section},
          {intro_section, RDFS.label(), RDF.literal("Intro")},
          {intro_section, DOC.children(), intro_list},
          {intro_paragraph, RDF.type(), DOC.ParagraphBlock},
          {intro_paragraph, DOC.paragraph(), intro_revision},
          {intro_revision, RDF.type(), DOC.Paragraph},
          {intro_revision, DOC.text(), RDF.literal("Intro.")},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Section")},
          {section, DOC.children(), section_list},
          {first, RDF.type(), DOC.ParagraphBlock},
          {first, DOC.paragraph(), first_revision},
          {first_revision, RDF.type(), DOC.Paragraph},
          {first_revision, DOC.text(), RDF.literal("First.")},
          {second, RDF.type(), DOC.ParagraphBlock},
          {second, DOC.paragraph(), second_revision},
          {second_revision, RDF.type(), DOC.Paragraph},
          {second_revision, DOC.text(), RDF.literal("Second.")},
          {outside, RDF.type(), DOC.ParagraphBlock},
          {outside, DOC.paragraph(), outside_revision},
          {outside_revision, RDF.type(), DOC.Paragraph},
          {outside_revision, DOC.text(), RDF.literal("Outside.")}
        ],
        name: thesis
      )
      |> then(fn graph ->
        RDF.list([intro_section, section, outside], graph: graph, head: root_list).graph
      end)
      |> then(fn graph ->
        RDF.list([intro_paragraph], graph: graph, head: intro_list).graph
      end)
      |> then(fn graph -> RDF.list([first, second], graph: graph, head: section_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        document_id: "DLM001",
        graph: graph,
        root: thesis,
        editing_block_id: nil,
        selected_block_id: "DLMP01",
        references_by_block: %{},
        tags_by_block: %{},
        refresh_search_indexes?: false
      }
    }

    socket = DocumentLive.assign_document_view(socket, graph, thesis, %{})
    socket = DocumentLive.move_document_block(socket, "DLMP01", "up")

    assert Sheaf.Document.children(socket.assigns.graph, section) == [first, second]

    assert Sheaf.Document.children(socket.assigns.graph, thesis) == [
             intro_section,
             section,
             outside
           ]

    socket = DocumentLive.move_document_block(socket, "DLMP02", "up")

    assert socket.assigns.selected_block_id == "DLMP02"
    assert Sheaf.Document.children(socket.assigns.graph, section) == [second, first]

    assert Sheaf.Document.children(socket.assigns.graph, thesis) == [
             intro_section,
             section,
             outside
           ]
  end
end
