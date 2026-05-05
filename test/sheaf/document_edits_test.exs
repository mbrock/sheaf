defmodule Sheaf.DocumentEditsTest do
  use ExUnit.Case, async: false

  alias RDF.NS.RDFS
  alias Sheaf.{Document, DocumentEdits, Id}
  alias Sheaf.NS.{DOC, PROV}

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-document-edits-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: path})
    :ok
  end

  test "replaces paragraph text with a new active revision and clears stale markup" do
    doc = Id.iri("DOCT01")
    block = Id.iri("PART01")
    old_revision = Id.iri("REVT01")

    graph =
      RDF.Graph.new(
        [
          {doc, RDF.type(), DOC.Document},
          {block, RDF.type(), DOC.ParagraphBlock},
          {block, DOC.paragraph(), old_revision},
          {block, DOC.markup(), RDF.literal("<em>Old paragraph.</em>")},
          {old_revision, RDF.type(), DOC.Paragraph},
          {old_revision, DOC.text(), RDF.literal("Old paragraph.")}
        ],
        name: doc
      )

    assert :ok = Sheaf.Repo.assert(graph)

    assert {:ok, result} = DocumentEdits.replace_block_text("PART01", "New paragraph.")

    assert result.action == :replace_paragraph_text
    assert result.affected_blocks == ["PART01"]
    assert result.previous_text == "Old paragraph."

    assert {:ok, updated} = Sheaf.fetch_graph(doc)
    assert Document.paragraph_text(updated, block) == "New paragraph."
    assert Document.paragraph_markup(updated, block) == nil
    assert RDF.Data.include?(updated, {old_revision, PROV.wasInvalidatedBy(), nil})
  end

  test "replaces paragraph markup with sanitized markup and a matching text revision" do
    doc = Id.iri("DOCM01")
    block = Id.iri("PARM01")
    old_revision = Id.iri("REVM01")

    graph =
      RDF.Graph.new(
        [
          {doc, RDF.type(), DOC.Document},
          {block, RDF.type(), DOC.ParagraphBlock},
          {block, DOC.paragraph(), old_revision},
          {block, DOC.markup(), RDF.literal("<em>Old paragraph.</em>")},
          {old_revision, RDF.type(), DOC.Paragraph},
          {old_revision, DOC.text(), RDF.literal("Old paragraph.")}
        ],
        name: doc
      )

    assert :ok = Sheaf.Repo.assert(graph)

    assert {:ok, result} =
             DocumentEdits.replace_block_markup(
               "PARM01",
               ~S|<strong>New</strong> <u>paragraph</u><script>bad()</script>.|
             )

    assert result.action == :replace_paragraph_markup

    assert result.markup ==
             "<strong>New</strong> <u>paragraph</u>&lt;script&gt;bad()&lt;/script&gt;."

    assert result.text == "New paragraph bad()."

    assert {:ok, updated} = Sheaf.fetch_graph(doc)
    assert Document.paragraph_markup(updated, block) == result.markup
    assert Document.paragraph_text(updated, block) == "New paragraph bad()."
    assert RDF.Data.include?(updated, {old_revision, PROV.wasInvalidatedBy(), nil})
  end

  test "changes section headings" do
    doc = Id.iri("DOCS01")
    section = Id.iri("SECS01")

    graph =
      RDF.Graph.new(
        [
          {doc, RDF.type(), DOC.Document},
          {section, RDF.type(), DOC.Section},
          {section, RDFS.label(), RDF.literal("Old heading")}
        ],
        name: doc
      )

    assert :ok = Sheaf.Repo.assert(graph)

    assert {:ok, result} = DocumentEdits.replace_block_text("SECS01", "New heading")

    assert result.action == :change_section_heading
    assert result.previous_text == "Old heading"

    assert {:ok, updated} = Sheaf.fetch_graph(doc)
    assert Document.heading(updated, section) == "New heading"
    refute RDF.Data.include?(updated, {section, RDFS.label(), RDF.literal("Old heading")})
  end

  test "moves existing blocks and inserts new paragraph blocks by placement" do
    doc = Id.iri("DOC001")
    root_list = Id.iri("LIST01")
    first_section = Id.iri("SEC001")
    first_list = Id.iri("LIST02")
    second_section = Id.iri("SEC002")
    second_list = Id.iri("LIST03")
    first_paragraph = Id.iri("PAR001")
    first_revision = Id.iri("REV001")
    second_paragraph = Id.iri("PAR002")
    second_revision = Id.iri("REV002")

    graph =
      RDF.Graph.new(
        [
          {doc, RDF.type(), DOC.Document},
          {doc, DOC.children(), root_list},
          {first_section, RDF.type(), DOC.Section},
          {first_section, RDFS.label(), RDF.literal("First")},
          {first_section, DOC.children(), first_list},
          {second_section, RDF.type(), DOC.Section},
          {second_section, RDFS.label(), RDF.literal("Second")},
          {second_section, DOC.children(), second_list},
          {first_paragraph, RDF.type(), DOC.ParagraphBlock},
          {first_paragraph, DOC.paragraph(), first_revision},
          {first_revision, RDF.type(), DOC.Paragraph},
          {first_revision, DOC.text(), RDF.literal("First paragraph.")},
          {second_paragraph, RDF.type(), DOC.ParagraphBlock},
          {second_paragraph, DOC.paragraph(), second_revision},
          {second_revision, RDF.type(), DOC.Paragraph},
          {second_revision, DOC.text(), RDF.literal("Second paragraph.")}
        ],
        name: doc
      )
      |> then(fn graph ->
        RDF.list([first_section, second_section], graph: graph, head: root_list).graph
      end)
      |> then(fn graph -> RDF.list([first_paragraph], graph: graph, head: first_list).graph end)
      |> then(fn graph -> RDF.list([second_paragraph], graph: graph, head: second_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    assert {:ok, move} = DocumentEdits.move_block("PAR001", "PAR002", "after")
    assert move.affected_blocks == ["PAR001"]

    assert {:ok, moved} = Sheaf.fetch_graph(doc)
    assert Document.children(moved, first_section) == []
    assert Document.children(moved, second_section) == [second_paragraph, first_paragraph]

    assert {:ok, insert} =
             DocumentEdits.insert_paragraph("SEC001", "first_child", "Inserted paragraph.")

    inserted = Id.iri(insert.block_id)

    assert {:ok, inserted_graph} = Sheaf.fetch_graph(doc)
    assert Document.children(inserted_graph, first_section) == [inserted]
    assert Document.paragraph_text(inserted_graph, inserted) == "Inserted paragraph."

    assert {:ok, delete} = DocumentEdits.delete_block("SEC002")
    assert delete.action == :delete_block
    assert delete.block_id == "SEC002"
    assert Enum.sort(delete.affected_blocks) == ["PAR001", "PAR002"]

    assert {:ok, deleted_graph} = Sheaf.fetch_graph(doc)
    assert Document.children(deleted_graph, doc) == [first_section]
    assert Document.block_type(deleted_graph, second_section) == nil
    assert Document.block_type(deleted_graph, first_paragraph) == nil
    assert Document.block_type(deleted_graph, second_paragraph) == nil
    refute RDF.Data.include?(deleted_graph, {first_paragraph, DOC.paragraph(), first_revision})
    refute RDF.Data.include?(deleted_graph, {first_revision, RDF.type(), DOC.Paragraph})
    refute RDF.Data.include?(deleted_graph, {second_revision, RDF.type(), DOC.Paragraph})
  end
end
