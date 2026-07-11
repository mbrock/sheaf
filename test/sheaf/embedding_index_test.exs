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
    row = RDF.iri("https://sheaf.less.rest/ROW1")
    para = RDF.iri("https://sheaf.less.rest/PARA1")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, Sheaf.NS.FABIO.isRepresentationOf(),
                    RDF.iri("https://sheaf.less.rest/EXPR1")},
                   {RDF.iri("https://sheaf.less.rest/EXPR1"),
                    Sheaf.NS.DCTERMS.title(), "Metadata title"}
                 ],
                 name: Sheaf.Repo.metadata_graph()
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {block1, Sheaf.NS.DOC.paragraph(), para},
                   {para, Sheaf.NS.DOC.text(), "Paragraph text."},
                   {block2, Sheaf.NS.DOC.sourceHtml(), "<p>PDF text.</p>"},
                   {row, Sheaf.NS.DOC.text(), "Coded spreadsheet row."},
                   {row, Sheaf.NS.DOC.spreadsheetRow(), 42}
                 ],
                 name: doc
               )
             )

    assert {:ok, units} =
             Index.text_units(
               model: "gemini-embedding-2",
               output_dimensionality: 768
             )

    units_by_iri = Map.new(units, &{&1.iri, &1})
    paragraph = Map.fetch!(units_by_iri, to_string(block1))
    source = Map.fetch!(units_by_iri, to_string(block2))
    row_unit = Map.fetch!(units_by_iri, to_string(row))

    assert paragraph.kind == "paragraph"
    assert paragraph.doc_title == "Metadata title"
    assert source.text == "<p>PDF text.</p>"
    assert source.doc_title == "Metadata title"
    assert row_unit.kind == "row"
    assert row_unit.spreadsheet_row == 42
    assert String.length(source.text_hash) == 64
  end

  test "can restrict text unit kinds" do
    doc = RDF.iri("https://sheaf.less.rest/DOC-KINDS")
    paragraph = RDF.iri("https://sheaf.less.rest/BLOCK-KINDS-PARA")
    paragraph_value = RDF.iri("https://sheaf.less.rest/PARA-KINDS")
    source = RDF.iri("https://sheaf.less.rest/BLOCK-KINDS-SOURCE")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {paragraph, Sheaf.NS.DOC.paragraph(), paragraph_value},
                   {paragraph_value, Sheaf.NS.DOC.text(), "Paragraph text."},
                   {source, Sheaf.NS.DOC.sourceHtml(), "<p>Source text.</p>"}
                 ],
                 name: doc
               )
             )

    assert {:ok, units} = Index.text_units(kinds: ["sourceHtml"])
    assert Enum.all?(units, &(&1.kind == "sourceHtml"))
    assert Enum.any?(units, &(&1.iri == to_string(source)))
    refute Enum.any?(units, &(&1.iri == to_string(paragraph)))
  end

  test "builds precise and contextual vectors for a stable citation IRI" do
    iri = "https://sheaf.less.rest/BLOCK-CONTEXT"

    [precise, contextual] =
      Index.units_from_rows(
        [
          %{
            "iri" => RDF.iri(iri),
            "kind" => RDF.literal("sourceHtml"),
            "text" => RDF.literal("<p>The focal result.</p>"),
            "searchText" => "The focal result.",
            "doc" => RDF.iri("https://sheaf.less.rest/DOC-CONTEXT"),
            "docTitle" => RDF.literal("Contextual Retrieval"),
            "breadcrumbs" => ["Contextual Retrieval", "Evaluation"],
            "previous" => %{"text" => "The experimental setup."},
            "following" => %{"text" => "The result is discussed."}
          }
        ],
        model: "text-embedding-3-large",
        output_dimensionality: 768,
        source: "test-context-v1"
      )

    assert precise.iri == iri
    assert precise.embedding_variant == :precise
    assert precise.embedding_text == "The focal result."

    assert contextual.iri == iri <> "#sheaf-context"
    assert contextual.citation_iri == iri
    assert contextual.embedding_variant == :context

    assert contextual.embedding_text =~
             "Section: Contextual Retrieval > Evaluation"

    assert contextual.embedding_text =~ "Previous: The experimental setup."
    assert contextual.embedding_text =~ "Passage: The focal result."
    assert contextual.embedding_text =~ "Next: The result is discussed."
    refute contextual.text_hash == precise.text_hash
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

    assert {:ok, plan} =
             Index.plan(
               db_path: db_path,
               model: model,
               output_dimensionality: dimensions,
               source: source,
               kinds: ["paragraph"],
               sample: 1000
             )

    assert plan.target_count >= 2
    assert plan.reusable_count >= 1
    assert plan.missing_count >= 1
    assert plan.missing_kinds["paragraph"] >= 1
    assert Enum.any?(plan.sample, &(&1.iri == missing_iri))
    refute Enum.any?(plan.sample, &(&1.iri == reusable_iri))
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

  test "exact search hydrates document titles from the metadata graph" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-title-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    doc = RDF.iri("https://sheaf.less.rest/DOC-TITLE")
    expression = RDF.iri("https://sheaf.less.rest/EXPR-TITLE")
    block_iri = "https://sheaf.less.rest/BLOCK-TITLE"

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {RDF.iri(block_iri), Sheaf.NS.DOC.sourceHtml(),
                    "Title hydration phrase."}
                 ],
                 name: doc
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, Sheaf.NS.FABIO.isRepresentationOf(), expression},
                   {expression, RDF.type(), Sheaf.NS.FABIO.Book},
                   {expression, Sheaf.NS.DCTERMS.title(),
                    "Metadata Graph Book"}
                 ],
                 name: Sheaf.Repo.metadata_graph()
               )
             )

    {:ok, conn} = SearchIndex.open(db_path: db_path)

    try do
      assert {:ok, %{count: 1}} =
               SearchIndex.rebuild(conn, [
                 %{
                   iri: block_iri,
                   doc_iri: to_string(doc),
                   kind: "sourceHtml",
                   text: "Title hydration phrase."
                 }
               ])
    after
      SearchIndex.close(conn)
    end

    assert {:ok, [hit]} =
             Index.exact_search("hydration", db_path: db_path)

    assert hit.doc_title == "Metadata Graph Book"
    assert hit.doc_kind == :literature
  end

  test "semantic search skips short fragments while exact search can return them" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-semantic-fragments-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    model = "gemini-embedding-2"
    dimensions = 3
    source = "test-source"
    run_iri = "https://sheaf.less.rest/RUN-SEMANTIC-FRAGMENTS"

    doc = RDF.iri("https://sheaf.less.rest/DOC-SEMANTIC-FRAGMENTS")
    short = "https://sheaf.less.rest/BLOCK-SHORT-FRAGMENT"
    long_one = "https://sheaf.less.rest/BLOCK-LONG-ONE"
    long_two = "https://sheaf.less.rest/BLOCK-LONG-TWO"

    long_text_one =
      "This longer passage mentions tigers while offering enough surrounding prose to be useful as a semantic search result for readers."

    long_text_two =
      "Another substantial paragraph discusses tigers in relation to historical examples and gives enough context for assistant citation in ordinary research conversations."

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {doc, RDF.type(), Sheaf.NS.DOC.Document},
                   {RDF.iri(short), Sheaf.NS.DOC.sourceHtml(),
                    "TURKEY TOLSON"},
                   {RDF.iri(long_one), Sheaf.NS.DOC.sourceHtml(),
                    long_text_one},
                   {RDF.iri(long_two), Sheaf.NS.DOC.sourceHtml(),
                    long_text_two}
                 ],
                 name: doc
               )
             )

    {:ok, search_conn} = SearchIndex.open(db_path: db_path)

    try do
      assert {:ok, %{count: 3}} =
               SearchIndex.rebuild(search_conn, [
                 %{
                   iri: short,
                   doc_iri: to_string(doc),
                   kind: "sourceHtml",
                   text: "TURKEY TOLSON"
                 },
                 %{
                   iri: long_one,
                   doc_iri: to_string(doc),
                   kind: "sourceHtml",
                   text: long_text_one
                 },
                 %{
                   iri: long_two,
                   doc_iri: to_string(doc),
                   kind: "sourceHtml",
                   text: long_text_two
                 }
               ])
    after
      SearchIndex.close(search_conn)
    end

    {:ok, store_conn} = Store.open(db_path: db_path)

    try do
      :ok =
        Store.create_run(store_conn, %{
          iri: run_iri,
          model: model,
          dimensions: dimensions,
          source: source,
          status: "completed",
          target_count: 3,
          embedded_count: 3
        })

      for {iri, text, values} <- [
            {short, "TURKEY TOLSON", [1.0, 0.0, 0.0]},
            {long_one, long_text_one, [0.9, 0.1, 0.0]},
            {long_two, long_text_two, [0.8, 0.2, 0.0]}
          ] do
        :ok =
          Store.insert_embedding(store_conn, %{
            iri: iri,
            run_iri: run_iri,
            text_hash: Index.text_hash(text, model, dimensions, source),
            text_chars: String.length(text),
            values: values
          })
      end

      assert {:ok, 3} =
               Store.sync_vector_index(
                 store_conn,
                 model,
                 dimensions,
                 source
               )
    after
      Store.close(store_conn)
    end

    assert {:ok, [%{iri: ^short, match: :exact}]} =
             Index.exact_search("TURKEY TOLSON", db_path: db_path)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"

      Req.Test.json(conn, %{
        "embedding" => %{"values" => [1.0, 0.0, 0.0]}
      })
    end)

    assert {:ok, semantic_hits} =
             Index.search("tigers",
               db_path: db_path,
               model: model,
               output_dimensionality: dimensions,
               source: source,
               exact_limit: 0,
               limit: 2,
               candidate_limit: 1,
               max_candidate_limit: 4,
               api_key: "secret",
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert Enum.map(semantic_hits, & &1.iri) == [long_one, long_two]
    assert Enum.all?(semantic_hits, &(&1.match == :semantic))
  end

  test "exact search can filter RDF hits by document kind" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "sheaf-embedding-kind-#{System.unique_integer([:positive])}.sqlite3"
      )

    on_exit(fn ->
      File.rm(db_path)
      File.rm(db_path <> "-shm")
      File.rm(db_path <> "-wal")
    end)

    thesis = RDF.iri("https://sheaf.less.rest/THESIS")
    paper = RDF.iri("https://sheaf.less.rest/PAPER")
    spreadsheet = RDF.iri("https://sheaf.less.rest/SHEET1")
    paragraph_block = RDF.iri("https://sheaf.less.rest/PARA-BLOCK")
    paragraph = RDF.iri("https://sheaf.less.rest/PARA-TEXT")
    paper_block = RDF.iri("https://sheaf.less.rest/PAPER-BLOCK")
    row = RDF.iri("https://sheaf.less.rest/ROW-BLOCK")

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {thesis, RDF.type(), Sheaf.NS.DOC.Thesis},
                   {paragraph_block, Sheaf.NS.DOC.paragraph(), paragraph},
                   {paragraph, Sheaf.NS.DOC.text(),
                    "Shared search phrase in thesis."}
                 ],
                 name: thesis
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {paper, RDF.type(), Sheaf.NS.DOC.Paper},
                   {paper_block, Sheaf.NS.DOC.sourceHtml(),
                    "Shared search phrase in literature."}
                 ],
                 name: paper
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {spreadsheet, RDF.type(), Sheaf.NS.DOC.Spreadsheet},
                   {row, Sheaf.NS.DOC.text(),
                    "Shared search phrase in coded row."},
                   {row, Sheaf.NS.DOC.spreadsheetRow(), 12}
                 ],
                 name: spreadsheet
               )
             )

    assert {:ok, _summary} = SearchIndex.sync(db_path: db_path)

    assert {:ok, [hit]} =
             Index.exact_search("shared search phrase",
               db_path: db_path,
               document_kind: "spreadsheet"
             )

    assert hit.iri == "https://sheaf.less.rest/ROW-BLOCK"
    assert hit.doc_kind == :spreadsheet

    assert {:ok, [hit]} =
             Index.exact_search("shared search phrase",
               db_path: db_path,
               document_kind: "literature"
             )

    assert hit.iri == "https://sheaf.less.rest/PAPER-BLOCK"
    assert hit.doc_kind == :literature
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
                   {RDF.iri(included_block), Sheaf.NS.DOC.sourceHtml(),
                    "<p>Text.</p>"}
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
                   {RDF.iri(excluded_block), Sheaf.NS.DOC.sourceHtml(),
                    "<p>Text.</p>"}
                 ],
                 name: excluded_doc
               )
             )

    assert :ok =
             Sheaf.Repo.assert(
               RDF.Graph.new(
                 [
                   {RDF.iri("https://less.rest/sheaf/workspace"),
                    Sheaf.NS.DOC.excludesDocument(), excluded_doc}
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
