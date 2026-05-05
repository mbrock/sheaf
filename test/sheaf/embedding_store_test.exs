defmodule Sheaf.Embedding.StoreTest do
  use ExUnit.Case, async: true

  alias Sheaf.Embedding.Store

  setup do
    {:ok, conn} = Store.open(db_path: ":memory:")
    on_exit(fn -> Store.close(conn) end)
    %{conn: conn}
  end

  test "stores run metadata separately from embeddings", %{conn: conn} do
    assert :ok =
             Store.create_run(conn, %{
               iri: "https://sheaf.less.rest/RUN111",
               model: "gemini-embedding-2",
               dimensions: 3,
               target_count: 1
             })

    assert :ok =
             Store.insert_embedding(conn, %{
               iri: "https://sheaf.less.rest/BLOCK1",
               run_iri: "https://sheaf.less.rest/RUN111",
               text_hash: "abc",
               text_chars: 12,
               values: [0.1, 0.2, 0.3]
             })

    assert :ok =
             Store.finish_run(conn, "https://sheaf.less.rest/RUN111", %{
               status: "completed",
               embedded_count: 1,
               skipped_count: 0,
               error_count: 0
             })

    assert {:ok, embedding} =
             Store.latest_embedding(
               conn,
               "https://sheaf.less.rest/BLOCK1",
               "abc",
               "gemini-embedding-2",
               3
             )

    assert embedding.iri == "https://sheaf.less.rest/BLOCK1"
    assert embedding.run_iri == "https://sheaf.less.rest/RUN111"
    assert_in_delta Enum.at(embedding.values, 0), 0.1, 0.00001
  end

  test "tracks reusable hashes across completed runs", %{conn: conn} do
    :ok =
      Store.create_run(conn, %{
        iri: "https://sheaf.less.rest/RUN222",
        model: "gemini-embedding-2",
        dimensions: 768
      })

    :ok =
      Store.insert_embedding(conn, %{
        iri: "https://sheaf.less.rest/BLOCK2",
        run_iri: "https://sheaf.less.rest/RUN222",
        text_hash: "hash2",
        text_chars: 4,
        values: [1.0]
      })

    :ok =
      Store.finish_run(conn, "https://sheaf.less.rest/RUN222", %{
        status: "completed",
        embedded_count: 1,
        skipped_count: 0,
        error_count: 0
      })

    assert MapSet.member?(
             Store.reusable_hashes(conn, "gemini-embedding-2", 768),
             {"https://sheaf.less.rest/BLOCK2", "hash2"}
           )
  end

  test "searches latest embeddings with sqlite-vec", %{conn: conn} do
    :ok =
      Store.create_run(conn, %{
        iri: "https://sheaf.less.rest/RUN333",
        model: "gemini-embedding-2",
        dimensions: 3,
        target_count: 2
      })

    :ok =
      Store.insert_embedding(conn, %{
        iri: "https://sheaf.less.rest/BLOCK3",
        run_iri: "https://sheaf.less.rest/RUN333",
        text_hash: "hash3",
        text_chars: 3,
        values: [1.0, 0.0, 0.0]
      })

    :ok =
      Store.insert_embedding(conn, %{
        iri: "https://sheaf.less.rest/BLOCK4",
        run_iri: "https://sheaf.less.rest/RUN333",
        text_hash: "hash4",
        text_chars: 3,
        values: [0.0, 1.0, 0.0]
      })

    :ok =
      Store.finish_run(conn, "https://sheaf.less.rest/RUN333", %{
        status: "completed",
        embedded_count: 2,
        skipped_count: 0,
        error_count: 0
      })

    assert {:ok, 2} = Store.sync_vector_index(conn, "gemini-embedding-2", 3)

    assert {:ok, [first, second]} =
             Store.search_vectors(conn, [1.0, 0.0, 0.0], "gemini-embedding-2", 3, 2)

    assert first.iri == "https://sheaf.less.rest/BLOCK3"
    assert first.score > second.score
  end

  test "syncing vectors can exclude stale text hashes", %{conn: conn} do
    block = "https://sheaf.less.rest/BLOCK5"

    :ok =
      Store.create_run(conn, %{
        iri: "https://sheaf.less.rest/RUN-OLD",
        model: "gemini-embedding-2",
        dimensions: 3,
        target_count: 1
      })

    :ok =
      Store.insert_embedding(conn, %{
        iri: block,
        run_iri: "https://sheaf.less.rest/RUN-OLD",
        text_hash: "old-hash",
        text_chars: 3,
        values: [1.0, 0.0, 0.0]
      })

    :ok =
      Store.finish_run(conn, "https://sheaf.less.rest/RUN-OLD", %{
        status: "completed",
        embedded_count: 1,
        skipped_count: 0,
        error_count: 0
      })

    :ok =
      Store.create_run(conn, %{
        iri: "https://sheaf.less.rest/RUN-NEW",
        model: "gemini-embedding-2",
        dimensions: 3,
        target_count: 1
      })

    :ok =
      Store.insert_embedding(conn, %{
        iri: block,
        run_iri: "https://sheaf.less.rest/RUN-NEW",
        text_hash: "new-hash",
        text_chars: 3,
        values: [0.0, 1.0, 0.0]
      })

    :ok =
      Store.finish_run(conn, "https://sheaf.less.rest/RUN-NEW", %{
        status: "completed",
        embedded_count: 1,
        skipped_count: 0,
        error_count: 0
      })

    assert {:ok, 1} =
             Store.sync_vector_index(conn, "gemini-embedding-2", 3, nil,
               current_hashes: MapSet.new([{block, "new-hash"}])
             )

    assert {:ok, [hit]} =
             Store.search_vectors(conn, [1.0, 0.0, 0.0], "gemini-embedding-2", 3, 1)

    assert hit.iri == block
    assert hit.run_iri == "https://sheaf.less.rest/RUN-NEW"
  end
end
