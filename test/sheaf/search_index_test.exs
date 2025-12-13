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
end
