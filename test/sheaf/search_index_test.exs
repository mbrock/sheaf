defmodule Sheaf.Search.IndexTest do
  use ExUnit.Case, async: false

  alias Sheaf.Search.Index

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-search-index-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> "-shm")
      File.rm(path <> "-wal")
    end)

    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-search-repo-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})

    {:ok, db_path: path}
  end

  test "sync mirrors RDF text units into SQLite FTS", %{db_path: db_path} do
    doc1 = RDF.iri("https://sheaf.less.rest/DOC1")
    doc2 = RDF.iri("https://sheaf.less.rest/DOC2")
    block1 = RDF.iri("https://sheaf.less.rest/BLOCK1")
    block2 = RDF.iri("https://sheaf.less.rest/BLOCK2")
    row = RDF.iri("https://sheaf.less.rest/ROW1")
    para = RDF.iri("https://sheaf.less.rest/PARA1")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc1, RDF.type(), Sheaf.NS.DOC.Document},
                   {block1, Sheaf.NS.DOC.paragraph(), para},
                   {para, Sheaf.NS.DOC.text(), "Circular economy practices matter."}
                 ],
                 name: doc1
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc2, RDF.type(), Sheaf.NS.DOC.Document},
                   {block2, Sheaf.NS.DOC.sourceHtml(), "<p>Repair and maintenance work.</p>"},
                   {row, Sheaf.NS.DOC.text(), "Coded row about giving things away."},
                   {row, Sheaf.NS.DOC.spreadsheetRow(), 7}
                 ],
                 name: doc2
               )
             )

    assert {:ok, %{count: 3, kinds: %{"paragraph" => 1, "sourceHtml" => 1, "row" => 1}}} =
             Index.sync(db_path: db_path)

    assert {:ok, [hit]} = Index.search("circular economy", db_path: db_path)
    assert hit.iri == "https://sheaf.less.rest/BLOCK1"
    assert hit.doc_iri == "https://sheaf.less.rest/DOC1"
    assert hit.kind == "paragraph"
    assert hit.match == :exact

    assert {:ok, [row_hit]} = Index.search("giving things", db_path: db_path)
    assert row_hit.iri == "https://sheaf.less.rest/ROW1"
    assert row_hit.kind == "row"
    assert row_hit.spreadsheet_row == 7

    assert {:ok, units} = Index.units_by_iris([row_hit.iri], db_path: db_path)
    assert %{spreadsheet_row: 7, text: "Coded row about giving things away."} = units[row_hit.iri]
  end

  test "sync mirrors research notes into SQLite FTS", %{db_path: db_path} do
    note = Sheaf.Id.iri("NOTE01")
    session = Sheaf.Id.iri("SESS01")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {note, RDF.type(), Sheaf.NS.AS.Note},
                   {note, RDF.type(), Sheaf.NS.DOC.ResearchNote},
                   {note, RDF.NS.RDFS.label(), "Repair note"},
                   {note, Sheaf.NS.AS.context(), session},
                   {note, Sheaf.NS.AS.content(), "Research note about maintenance cultures."},
                   {session, RDF.type(), Sheaf.NS.DOC.AssistantConversation}
                 ],
                 name: Sheaf.Repo.workspace_graph()
               )
             )

    assert {:ok, %{kinds: %{"note" => 1}}} = Index.sync(db_path: db_path)

    assert {:ok, hits} = Index.search("maintenance cultures", db_path: db_path)
    assert hit = Enum.find(hits, &(&1.iri == to_string(note)))
    assert hit.iri == to_string(note)
    assert hit.kind == "note"
    assert hit.doc_title == "Repair note"
  end

  test "sync ignores unlinked document blocks when a graph has children", %{db_path: db_path} do
    doc = RDF.iri("https://sheaf.less.rest/DOC1")
    root_list = RDF.iri("https://sheaf.less.rest/LIST1")
    linked_block = RDF.iri("https://sheaf.less.rest/LINKED")
    linked_paragraph = RDF.iri("https://sheaf.less.rest/LINKED-P")
    orphan_block = RDF.iri("https://sheaf.less.rest/ORPHAN")
    orphan_paragraph = RDF.iri("https://sheaf.less.rest/ORPHAN-P")

    graph =
      RDF.Graph.new(
        [
          {doc, RDF.type(), Sheaf.NS.DOC.Document},
          {doc, Sheaf.NS.DOC.children(), root_list},
          {linked_block, Sheaf.NS.DOC.paragraph(), linked_paragraph},
          {linked_paragraph, Sheaf.NS.DOC.text(), "Current reachable chapter text."},
          {orphan_block, Sheaf.NS.DOC.paragraph(), orphan_paragraph},
          {orphan_paragraph, Sheaf.NS.DOC.text(), "Stale zephyrword chapter text."}
        ],
        name: doc
      )
      |> then(fn graph -> RDF.list([linked_block], graph: graph, head: root_list).graph end)

    assert :ok = Sheaf.Repo.assert(graph)

    assert {:ok, summary} = Index.sync(db_path: db_path)
    assert summary.count >= 1

    assert {:ok, [hit]} = Index.search("reachable chapter", db_path: db_path)
    assert hit.iri == "https://sheaf.less.rest/LINKED"

    assert {:ok, []} = Index.search("zephyrword", db_path: db_path)
  end

  test "search respects kind and document filters", %{db_path: db_path} do
    {:ok, conn} = Index.open(db_path: db_path)
    doc1 = Sheaf.Id.iri("DOC1") |> to_string()
    doc2 = Sheaf.Id.iri("DOC2") |> to_string()

    try do
      assert {:ok, %{count: 3}} =
               Index.rebuild(conn, [
                 %{
                   iri: "https://sheaf.less.rest/BLOCK1",
                   doc_iri: doc1,
                   kind: "paragraph",
                   text: "Shared repair infrastructure"
                 },
                 %{
                   iri: "https://sheaf.less.rest/BLOCK2",
                   doc_iri: doc2,
                   kind: "paragraph",
                   text: "Shared repair infrastructure"
                 },
                 %{
                   iri: "https://sheaf.less.rest/ROW1",
                   doc_iri: doc1,
                   kind: "row",
                   text: "Shared repair infrastructure"
                 }
               ])

      assert {:ok, [hit]} =
               Index.search_loaded(conn, "repair",
                 document_id: "DOC1",
                 kinds: ["paragraph"]
               )

      assert hit.iri == "https://sheaf.less.rest/BLOCK1"
    after
      Index.close(conn)
    end
  end

  test "scores multi-term exact matches by coverage instead of flattening", %{db_path: db_path} do
    {:ok, conn} = Index.open(db_path: db_path)
    doc = Sheaf.Id.iri("DOC1") |> to_string()

    try do
      assert {:ok, %{count: 4}} =
               Index.rebuild(conn, [
                 %{
                   iri: "https://sheaf.less.rest/BLOCK1",
                   doc_iri: doc,
                   kind: "paragraph",
                   text: "Meaning sustaining participation depends on shared routines."
                 },
                 %{
                   iri: "https://sheaf.less.rest/BLOCK2",
                   doc_iri: doc,
                   kind: "paragraph",
                   text: "Meaning and participation are discussed without the middle term."
                 },
                 %{
                   iri: "https://sheaf.less.rest/BLOCK3",
                   doc_iri: doc,
                   kind: "paragraph",
                   text: "Participation appears by itself."
                 },
                 %{
                   iri: "https://sheaf.less.rest/BLOCK4",
                   doc_iri: doc,
                   kind: "paragraph",
                   text: "Sustaining sustaining participation through participation."
                 }
               ])

      assert {:ok, hits} =
               Index.search_loaded(conn, "meaning sustaining participation",
                 document_id: "DOC1",
                 kinds: ["paragraph"],
                 limit: 4
               )

      scores = Enum.map(hits, & &1.score)

      assert List.first(hits).iri == "https://sheaf.less.rest/BLOCK1"
      assert Enum.uniq(scores) != [0.95]
      assert Enum.sort(scores, :desc) == scores
    after
      Index.close(conn)
    end
  end
end
