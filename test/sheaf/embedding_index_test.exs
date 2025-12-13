defmodule Sheaf.Embedding.IndexTest do
  use ExUnit.Case, async: false

  alias Sheaf.Embedding.Index
  alias Sheaf.Embedding.Store
  alias Sheaf.Search.Index, as: SearchIndex

  setup do
    repo_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-repo-#{System.unique_integer([:positive])}.sqlite3"
      )

    start_supervised!({Sheaf.Repo, path: repo_path})
    Req.Test.verify_on_exit!()
  end

  test "builds text units from all text-bearing block shapes" do
    doc = RDF.iri("https://sheaf.less.rest/DOC1")
    block1 = RDF.iri("https://sheaf.less.rest/BLOCK1")
    block2 = RDF.iri("https://sheaf.less.rest/BLOCK2")
    para = RDF.iri("https://sheaf.less.rest/PARA1")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {block1, Sheaf.NS.DOC.paragraph(), para},
                   {para, Sheaf.NS.DOC.text(), "Paragraph text."},
                   {block2, Sheaf.NS.DOC.sourceHtml(), "<p>PDF text.</p>"}
                 ],
                 name: doc
               )
             )

    assert {:ok, [paragraph, source]} =
             Index.text_units(
               model: "gemini-embedding-2",
               output_dimensionality: 768
             )

    assert paragraph.kind == "paragraph"
    assert source.text == "<p>PDF text.</p>"
    assert String.length(source.text_hash) == 64
  end

  test "can restrict text unit kinds" do
    assert {:ok, []} = Index.text_units(kinds: ["sourceHtml"])
  end

  test "plans missing embeddings without embedding them" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-plan-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    model = "text-embedding-3-large"
    dimensions = 2
    source = "test-source"
    reusable_iri = "https://sheaf.less.rest/BLOCK-REUSABLE"
    missing_iri = "https://sheaf.less.rest/BLOCK-MISSING"

    reusable_hash =
      Index.text_hash("Existing text.", model, dimensions, source)

    {:ok, conn} = Store.open(db_path: db_path)

    try do
      :ok =
        Store.create_run(conn, %{
          iri: "https://sheaf.less.rest/RUN-REUSABLE",
          model: model,
          dimensions: dimensions,
          source: source,
          status: "completed",
          target_count: 1,
          embedded_count: 1
        })

      :ok =
        Store.insert_embedding(conn, %{
          iri: reusable_iri,
          run_iri: "https://sheaf.less.rest/RUN-REUSABLE",
          text_hash: reusable_hash,
          text_chars: 14,
          values: [0.1, 0.2]
        })
    after
      Store.close(conn)
    end

    doc = RDF.iri("https://sheaf.less.rest/DOC1")
    reusable = RDF.iri(reusable_iri)
    missing = RDF.iri(missing_iri)
    reusable_para = RDF.iri("https://sheaf.less.rest/PARA-REUSABLE")
    missing_para = RDF.iri("https://sheaf.less.rest/PARA-MISSING")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {reusable, Sheaf.NS.DOC.paragraph(), reusable_para},
                   {reusable_para, Sheaf.NS.DOC.text(), "Existing text."},
                   {missing, Sheaf.NS.DOC.paragraph(), missing_para},
                   {missing_para, Sheaf.NS.DOC.text(), "New text."}
                 ],
                 name: doc
               )
             )

    assert {:ok,
            %{
              target_count: 2,
              reusable_count: 1,
              missing_count: 1,
              missing_kinds: %{"paragraph" => 1},
              sample: [%{iri: ^missing_iri}]
            }} =
             Index.plan(
               db_path: db_path,
               model: model,
               output_dimensionality: dimensions,
               source: source
             )
  end

  test "exact search tolerates stale search rows without hydrated document metadata" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-exact-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    block_iri = "https://sheaf.less.rest/BLOCK-STALE"

    {:ok, conn} = SearchIndex.open(db_path: db_path)

    try do
      assert {:ok, %{count: 1}} =
               SearchIndex.rebuild(conn, [
                 %{
                   iri: block_iri,
                   doc_iri: "https://sheaf.less.rest/DOC-STALE",
                   kind: "paragraph",
                   text: "Signal costs and procurement screening"
                 }
               ])
    after
      SearchIndex.close(conn)
    end

    assert {:ok, [%{iri: ^block_iri, match: :exact}]} =
             Index.exact_search("signal", db_path: db_path)
  end

  test "importing an async batch skips units whose documents are now excluded" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-index-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    run_iri = "https://sheaf.less.rest/RUN-BATCH"
    included_block = "https://sheaf.less.rest/BLOCK-INCLUDED"
    excluded_block = "https://sheaf.less.rest/BLOCK-EXCLUDED"

    {:ok, conn} = Store.open(db_path: db_path)

    try do
      :ok =
        Store.create_run(conn, %{
          iri: run_iri,
          model: "gemini-embedding-2",
          dimensions: 2,
          source: "search-v1",
          status: "running",
          target_count: 2,
          metadata: %{
            batch_name: "batches/test-import",
            batch_units: [
              %{
                iri: included_block,
                text_hash: "hash-included",
                text_chars: 13
              },
              %{
                iri: excluded_block,
                text_hash: "hash-excluded",
                text_chars: 13
              }
            ]
          }
        })
    after
      Store.close(conn)
    end

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1beta/batches/test-import"

      Req.Test.json(conn, %{
        "name" => "batches/test-import",
        "metadata" => %{
          "name" => "batches/test-import",
          "state" => "BATCH_STATE_SUCCEEDED",
          "output" => %{
            "inlinedResponses" => %{
              "inlinedResponses" => [
                %{"response" => %{"embedding" => %{"values" => [1.0, 0.0]}}},
                %{"response" => %{"embedding" => %{"values" => [0.0, 1.0]}}}
              ]
            }
          }
        }
      })
    end)

    included_doc = Sheaf.Id.iri("DOC-INCLUDED")
    excluded_doc = Sheaf.Id.iri("DOC-EXCLUDED")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {included_doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {included_doc, RDF.NS.RDFS.label(), "Included"},
                   {RDF.iri(included_block), Sheaf.NS.DOC.sourceHtml(), "<p>Text.</p>"}
                 ],
                 name: included_doc
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {excluded_doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {excluded_doc, RDF.NS.RDFS.label(), "Excluded"},
                   {RDF.iri(excluded_block), Sheaf.NS.DOC.sourceHtml(), "<p>Text.</p>"}
                 ],
                 name: excluded_doc
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {RDF.iri("https://less.rest/sheaf/workspace"), Sheaf.NS.DOC.excludesDocument(),
                    excluded_doc}
                 ],
                 name: Sheaf.Workspace.graph()
               )
             )

    assert {:ok,
            %{
              status: "completed",
              embedded_count: 1,
              skipped_count: 1,
              error_count: 0
            }} =
             Index.sync(
               db_path: db_path,
               import_run: run_iri,
               api_key: "secret",
               model: "gemini-embedding-2",
               output_dimensionality: 2,
               poll_interval_ms: 0,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    {:ok, conn} = Store.open(db_path: db_path)

    try do
      assert {:ok, %{iri: ^included_block}} =
               Store.latest_embedding(
                 conn,
                 included_block,
                 "hash-included",
                 "gemini-embedding-2",
                 2,
                 "search-v1"
               )

      assert {:ok, nil} =
               Store.latest_embedding(
                 conn,
                 excluded_block,
                 "hash-excluded",
                 "gemini-embedding-2",
                 2,
                 "search-v1"
               )
    after
      Store.close(conn)
    end
  end
end
