defmodule Sheaf.Embedding.IndexTest do
  use ExUnit.Case, async: false

  alias Sheaf.Embedding.Index
  alias Sheaf.Embedding.Store
  alias Sheaf.Search.Index, as: SearchIndex

  setup do
    Req.Test.verify_on_exit!()
  end

  test "builds text units from all text-bearing block shapes" do
    test_pid = self()

    select = fn label, sparql ->
      assert label in [
               "embedding text units paragraph select",
               "embedding text units sourceHtml select",
               "embedding text units row select"
             ]

      send(test_pid, {:sparql, sparql})
      assert sparql =~ "sheaf:excludesDocument"
      refute sparql =~ " UNION "

      cond do
        sparql =~ "sheaf:paragraph" ->
          {:ok,
           %{
             results: [
               %{
                 "iri" => RDF.iri("https://sheaf.less.rest/BLOCK1"),
                 "kind" => RDF.literal("paragraph"),
                 "text" => RDF.literal("Paragraph text.")
               }
             ]
           }}

        sparql =~ "sheaf:sourceHtml" ->
          {:ok,
           %{
             results: [
               %{
                 "iri" => RDF.iri("https://sheaf.less.rest/BLOCK2"),
                 "kind" => RDF.literal("sourceHtml"),
                 "text" => RDF.literal("<p>PDF text.</p>")
               }
             ]
           }}

        sparql =~ "sheaf:Row" ->
          {:ok,
           %{
             results: [
               %{
                 "iri" => RDF.iri("https://sheaf.less.rest/ROW1"),
                 "kind" => RDF.literal("row"),
                 "text" => RDF.literal("Spreadsheet text.")
               }
             ]
           }}
      end
    end

    assert {:ok, [paragraph, source, row]} =
             Index.text_units(
               select: select,
               model: "gemini-embedding-2",
               output_dimensionality: 768
             )

    assert paragraph.kind == "paragraph"
    assert source.text == "<p>PDF text.</p>"
    assert row.iri == "https://sheaf.less.rest/ROW1"
    assert String.length(row.text_hash) == 64

    assert_received {:sparql, paragraph_sparql}
    assert_received {:sparql, source_sparql}
    assert_received {:sparql, row_sparql}

    assert paragraph_sparql =~ "sheaf:paragraph"
    assert source_sparql =~ "sheaf:sourceHtml"
    assert row_sparql =~ "sheaf:Row"
  end

  test "can restrict text unit kinds" do
    select = fn label, sparql ->
      assert label == "embedding text units sourceHtml select"
      assert sparql =~ "sheaf:sourceHtml"
      refute sparql =~ "sheaf:paragraph"
      refute sparql =~ "sheaf:Row"

      {:ok, %{results: []}}
    end

    assert {:ok, []} = Index.text_units(kinds: ["sourceHtml"], select: select)
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

    select = fn _label, sparql ->
      cond do
        sparql =~ "sheaf:paragraph" ->
          {:ok,
           %{
             results: [
               text_unit_row(reusable_iri, "paragraph", "Existing text."),
               text_unit_row(missing_iri, "paragraph", "New text.")
             ]
           }}

        sparql =~ "sheaf:sourceHtml" ->
          {:ok, %{results: []}}

        sparql =~ "sheaf:Row" ->
          {:ok, %{results: []}}
      end
    end

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
               source: source,
               select: select
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

    select = fn
      "embedding descriptions select", _sparql -> {:ok, %{results: []}}
      "embedding document metadata select", _sparql -> {:ok, %{results: []}}
    end

    assert {:ok, [%{iri: ^block_iri, match: :exact}]} =
             Index.exact_search("signal", db_path: db_path, select: select)
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

    select = fn _label, sparql ->
      cond do
        sparql =~ "VALUES ?iri" ->
          {:ok,
           %{
             results: [
               description_row(included_block, "DOC-INCLUDED"),
               description_row(excluded_block, "DOC-EXCLUDED")
             ]
           }}

        sparql =~ "SELECT ?doc ?title ?authorName ?excluded" ->
          {:ok,
           %{
             results: [
               metadata_row("DOC-INCLUDED", "Included"),
               metadata_row("DOC-EXCLUDED", "Excluded", excluded?: true)
             ]
           }}
      end
    end

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
               req_options: [plug: {Req.Test, __MODULE__}],
               select: select
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

  defp description_row(block_iri, doc_id) do
    %{
      "iri" => RDF.iri(block_iri),
      "doc" => RDF.iri(Sheaf.Id.iri(doc_id)),
      "s" => RDF.iri(block_iri),
      "p" => Sheaf.NS.DOC.sourceHtml(),
      "o" => RDF.literal("<p>Text.</p>")
    }
  end

  defp text_unit_row(iri, kind, text) do
    %{
      "iri" => RDF.iri(iri),
      "kind" => RDF.literal(kind),
      "text" => RDF.literal(text)
    }
  end

  defp metadata_row(doc_id, title, opts \\ []) do
    row = %{
      "doc" => RDF.iri(Sheaf.Id.iri(doc_id)),
      "title" => RDF.literal(title)
    }

    if Keyword.get(opts, :excluded?, false) do
      Map.put(row, "excluded", RDF.literal("true"))
    else
      row
    end
  end
end
