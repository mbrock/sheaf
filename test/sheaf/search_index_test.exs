defmodule Sheaf.Search.IndexTest do
  use ExUnit.Case, async: true

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

    {:ok, db_path: path}
  end

  test "sync mirrors RDF text units into SQLite FTS", %{db_path: db_path} do
    select = fn label, sparql ->
      assert label in [
               "search text units paragraph select",
               "search text units sourceHtml select",
               "search text units row select"
             ]

      refute sparql =~ "UNION"
      refute sparql =~ "ORDER BY"
      assert sparql =~ "sheaf:excludesDocument"

      cond do
        sparql =~ "sheaf:paragraph" ->
          {:ok,
           %{
             results: [
               %{
                 "iri" => RDF.iri("https://sheaf.less.rest/BLOCK1"),
                 "text" => RDF.literal("Circular economy practices matter."),
                 "doc" => RDF.iri("https://sheaf.less.rest/DOC1")
               }
             ]
           }}

        sparql =~ "sheaf:sourceHtml" ->
          {:ok,
           %{
             results: [
               %{
                 "iri" => RDF.iri("https://sheaf.less.rest/BLOCK2"),
                 "text" => RDF.literal("<p>Repair and maintenance work.</p>"),
                 "doc" => RDF.iri("https://sheaf.less.rest/DOC2")
               }
             ]
           }}

        sparql =~ "sheaf:Row" ->
          {:ok, %{results: []}}
      end
    end

    assert {:ok, %{count: 2, kinds: %{"paragraph" => 1, "sourceHtml" => 1}}} =
             Index.sync(db_path: db_path, select: select)

    assert {:ok, [hit]} = Index.search("circular economy", db_path: db_path)
    assert hit.iri == "https://sheaf.less.rest/BLOCK1"
    assert hit.doc_iri == "https://sheaf.less.rest/DOC1"
    assert hit.kind == "paragraph"
    assert hit.match == :exact
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
