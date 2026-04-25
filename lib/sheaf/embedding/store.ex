defmodule Sheaf.Embedding.Store do
  @moduledoc """
  SQLite storage for derived embedding vectors.

  RDF remains the source of truth. This database stores run metadata and vector
  blobs keyed by the RDF IRI that was embedded.
  """

  alias Exqlite.Sqlite3

  @default_path "var/sheaf-embeddings.sqlite3"
  @valid_read_statuses ["completed", "partial"]

  @type conn :: Sqlite3.db()

  @doc """
  Opens and migrates the configured embeddings database.
  """
  @spec open(keyword()) :: {:ok, conn()} | {:error, term()}
  def open(opts \\ []) do
    path = path(opts)

    with :ok <- ensure_parent_dir(path),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- load_vector_extension(conn),
         :ok <- migrate(conn) do
      {:ok, conn}
    end
  end

  @spec close(conn()) :: :ok | {:error, term()}
  def close(conn), do: Sqlite3.close(conn)

  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:path, @default_path)

    Keyword.get(opts, :db_path, configured)
  end

  @spec migrate(conn()) :: :ok | {:error, term()}
  def migrate(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys = ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL"),
         :ok <- Sqlite3.execute(conn, runs_sql()),
         :ok <- Sqlite3.execute(conn, embeddings_sql()),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS embeddings_iri_idx ON embeddings(iri)"
           ),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS embeddings_run_idx ON embeddings(run_iri)"
           ),
         :ok <- Sqlite3.execute(conn, vector_items_sql()),
         :ok <- ensure_vector_items_source_column(conn),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS embedding_vector_items_source_idx ON embedding_vector_items(model, dimensions, source)"
           ) do
      :ok
    end
  end

  @doc """
  Inserts a run row.
  """
  @spec create_run(conn(), map()) :: :ok | {:error, term()}
  def create_run(conn, attrs) do
    execute(
      conn,
      """
      INSERT INTO embedding_runs
        (iri, model, dimensions, source, status, target_count, embedded_count,
         skipped_count, error_count, started_at, metadata_json)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        attrs.iri,
        attrs.model,
        attrs.dimensions,
        Map.get(attrs, :source, "text_units"),
        Map.get(attrs, :status, "running"),
        Map.get(attrs, :target_count, 0),
        Map.get(attrs, :embedded_count, 0),
        Map.get(attrs, :skipped_count, 0),
        Map.get(attrs, :error_count, 0),
        Map.get(attrs, :started_at, now_iso8601()),
        Jason.encode!(Map.get(attrs, :metadata, %{}))
      ]
    )
  end

  @doc """
  Finalizes run counters and status.
  """
  @spec finish_run(conn(), String.t(), map()) :: :ok | {:error, term()}
  def finish_run(conn, run_iri, attrs) do
    execute(
      conn,
      """
      UPDATE embedding_runs
      SET status = ?,
          embedded_count = ?,
          skipped_count = ?,
          error_count = ?,
          finished_at = ?,
          metadata_json = ?
      WHERE iri = ?
      """,
      [
        Map.fetch!(attrs, :status),
        Map.get(attrs, :embedded_count, 0),
        Map.get(attrs, :skipped_count, 0),
        Map.get(attrs, :error_count, 0),
        Map.get(attrs, :finished_at, now_iso8601()),
        Jason.encode!(Map.get(attrs, :metadata, %{})),
        run_iri
      ]
    )
  end

  @doc """
  Returns one embedding run row by IRI.
  """
  @spec get_run(conn(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_run(conn, run_iri) do
    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT iri, model, dimensions, source, status, target_count,
                    embedded_count, skipped_count, error_count, started_at,
                    finished_at, metadata_json
             FROM embedding_runs
             WHERE iri = ?
             LIMIT 1
             """,
             [run_iri]
           ) do
      case rows do
        [] ->
          {:ok, nil}

        [
          [
            iri,
            model,
            dimensions,
            source,
            status,
            target_count,
            embedded_count,
            skipped_count,
            error_count,
            started_at,
            finished_at,
            metadata_json
          ]
        ] ->
          {:ok,
           %{
             iri: iri,
             model: model,
             dimensions: dimensions,
             source: source,
             status: status,
             target_count: target_count,
             embedded_count: embedded_count,
             skipped_count: skipped_count,
             error_count: error_count,
             started_at: started_at,
             finished_at: finished_at,
             metadata: decode_metadata(metadata_json)
           }}
      end
    end
  end

  @doc """
  Updates non-terminal run bookkeeping without setting `finished_at`.
  """
  @spec update_run(conn(), String.t(), map()) :: :ok | {:error, term()}
  def update_run(conn, run_iri, attrs) do
    execute(
      conn,
      """
      UPDATE embedding_runs
      SET status = ?,
          embedded_count = ?,
          skipped_count = ?,
          error_count = ?,
          metadata_json = ?
      WHERE iri = ?
      """,
      [
        Map.get(attrs, :status, "running"),
        Map.get(attrs, :embedded_count, 0),
        Map.get(attrs, :skipped_count, 0),
        Map.get(attrs, :error_count, 0),
        Jason.encode!(Map.get(attrs, :metadata, %{})),
        run_iri
      ]
    )
  end

  @doc """
  Inserts one embedding row for a run.
  """
  @spec insert_embedding(conn(), map()) :: :ok | {:error, term()}
  def insert_embedding(conn, attrs) do
    execute(
      conn,
      """
      INSERT OR REPLACE INTO embeddings
        (iri, run_iri, text_hash, text_chars, embedding, inserted_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        attrs.iri,
        attrs.run_iri,
        attrs.text_hash,
        attrs.text_chars,
        {:blob, encode_vector(attrs.values)},
        Map.get(attrs, :inserted_at, now_iso8601())
      ]
    )
  end

  @doc """
  Returns `{iri, text_hash}` pairs already available for a model/dimensions.
  """
  @spec reusable_hashes(conn(), String.t(), pos_integer(), String.t() | nil) :: MapSet.t()
  def reusable_hashes(conn, model, dimensions, source \\ nil) do
    {:ok, rows} =
      query(
        conn,
        """
        SELECT DISTINCT e.iri, e.text_hash
        FROM embeddings e
        JOIN embedding_runs r ON r.iri = e.run_iri
        WHERE r.model = ?
          AND r.dimensions = ?
          AND (? IS NULL OR r.source = ?)
          AND r.status IN ('completed', 'partial')
        """,
        [model, dimensions, source, source]
      )

    rows
    |> Enum.map(fn [iri, text_hash] -> {iri, text_hash} end)
    |> MapSet.new()
  end

  @doc """
  Returns the newest matching embedding for `iri` and `text_hash`.
  """
  @spec latest_embedding(conn(), String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def latest_embedding(conn, iri, text_hash, model, dimensions, source \\ nil) do
    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT e.iri, e.run_iri, e.text_hash, e.text_chars, e.embedding
             FROM embeddings e
             JOIN embedding_runs r ON r.iri = e.run_iri
             WHERE e.iri = ?
               AND e.text_hash = ?
               AND r.model = ?
               AND r.dimensions = ?
               AND (? IS NULL OR r.source = ?)
               AND r.status IN ('completed', 'partial')
             ORDER BY COALESCE(r.finished_at, r.started_at) DESC, e.inserted_at DESC
             LIMIT 1
             """,
             [iri, text_hash, model, dimensions, source, source]
           ) do
      case rows do
        [] ->
          {:ok, nil}

        [[iri, run_iri, text_hash, text_chars, blob]] ->
          {:ok,
           %{
             iri: iri,
             run_iri: run_iri,
             text_hash: text_hash,
             text_chars: text_chars,
             values: decode_vector(blob)
           }}
      end
    end
  end

  @doc """
  Returns the newest embedding rows for a model/dimensions by `iri` and hash.

  If several completed or partial runs embedded the same current text, the most
  recently finished run wins. Rows remain physically attached to their original
  run; this is only a read view over the derived cache.
  """
  @spec latest_embeddings(conn(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def latest_embeddings(conn, model, dimensions, source \\ nil) do
    with {:ok, rows} <-
           latest_embedding_rows(conn, model, dimensions, source) do
      {:ok,
       Enum.map(rows, fn [iri, run_iri, text_hash, text_chars, blob] ->
         %{
           iri: iri,
           run_iri: run_iri,
           text_hash: text_hash,
           text_chars: text_chars,
           values: decode_vector(blob)
         }
       end)}
    end
  end

  @doc """
  Rebuilds the sqlite-vec search table for the latest embeddings of a model.
  """
  @spec sync_vector_index(conn(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_vector_index(conn, model, dimensions, source \\ nil) do
    with :ok <- ensure_vector_table(conn, dimensions),
         {:ok, rows} <- latest_embedding_rows(conn, model, dimensions, source) do
      transaction(conn, fn ->
        with :ok <- delete_vector_index(conn, model, dimensions, source) do
          insert_vector_rows(conn, model, dimensions, source, rows)
        end
      end)
    end
  end

  @doc """
  Returns nearest embeddings using sqlite-vec cosine distance.
  """
  @spec search_vectors(
          conn(),
          [float()],
          String.t(),
          pos_integer(),
          pos_integer(),
          String.t() | nil
        ) ::
          {:ok, [map()]} | {:error, term()}
  def search_vectors(conn, query_values, model, dimensions, limit, source \\ nil) do
    with :ok <- ensure_vector_table(conn, dimensions),
         {:ok, count} <- vector_index_count(conn, model, dimensions, source),
         {:ok, _count} <- maybe_sync_vector_index(conn, model, dimensions, source, count),
         {:ok, rows} <-
           query(
             conn,
             """
             SELECT i.iri, i.run_iri, v.distance
             FROM #{vector_table_name(dimensions)} v
             JOIN embedding_vector_items i ON i.rowid = v.rowid
             WHERE v.embedding MATCH ?
               AND k = ?
               AND i.model = ?
               AND i.dimensions = ?
               AND (? IS NULL OR i.source = ?)
             ORDER BY v.distance
             """,
             [{:blob, encode_vector(query_values)}, limit, model, dimensions, source, source]
           ) do
      {:ok,
       Enum.map(rows, fn [iri, run_iri, distance] ->
         %{iri: iri, run_iri: run_iri, score: 1.0 - distance, distance: distance}
       end)}
    end
  end

  @doc false
  def encode_vector(values) when is_list(values) do
    for value <- values, into: <<>>, do: <<value * 1.0::little-float-32>>
  end

  @doc false
  def decode_vector(binary) when is_binary(binary) do
    for <<value::little-float-32 <- binary>>, do: value
  end

  defp latest_embedding_rows(conn, model, dimensions, source) do
    query(
      conn,
      """
      SELECT iri, run_iri, text_hash, text_chars, embedding
      FROM (
        SELECT e.iri,
               e.run_iri,
               e.text_hash,
               e.text_chars,
               e.embedding,
               ROW_NUMBER() OVER (
                 PARTITION BY e.iri, e.text_hash
                 ORDER BY COALESCE(r.finished_at, r.started_at) DESC, e.inserted_at DESC
               ) AS row_number
        FROM embeddings e
        JOIN embedding_runs r ON r.iri = e.run_iri
        WHERE r.model = ?
          AND r.dimensions = ?
          AND (? IS NULL OR r.source = ?)
          AND r.status IN ('completed', 'partial')
      )
      WHERE row_number = 1
      """,
      [model, dimensions, source, source]
    )
  end

  defp load_vector_extension(conn) do
    path = SqliteVec.path()

    with :ok <- Sqlite3.enable_load_extension(conn, true) do
      try do
        load_extension(conn, path)
      after
        Sqlite3.enable_load_extension(conn, false)
      end
    end
  end

  defp load_extension(conn, path) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "SELECT load_extension(?)") do
      try do
        :ok = Sqlite3.bind(statement, [path])

        case Sqlite3.step(conn, statement) do
          {:row, _row} -> :ok
          :done -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp ensure_vector_table(conn, dimensions) do
    Sqlite3.execute(
      conn,
      """
      CREATE VIRTUAL TABLE IF NOT EXISTS #{vector_table_name(dimensions)}
      USING vec0(embedding float[#{dimensions}] distance_metric=cosine)
      """
    )
  end

  defp vector_table_name(dimensions) when is_integer(dimensions) and dimensions > 0 do
    "embedding_vec_#{dimensions}"
  end

  defp vector_index_count(conn, model, dimensions, source) do
    with {:ok, [[count]]} <-
           query(
             conn,
             """
             SELECT COUNT(*)
             FROM embedding_vector_items
             WHERE model = ?
               AND dimensions = ?
               AND (? IS NULL OR source = ?)
             """,
             [model, dimensions, source, source]
           ) do
      {:ok, count}
    end
  end

  defp maybe_sync_vector_index(conn, model, dimensions, source, 0),
    do: sync_vector_index(conn, model, dimensions, source)

  defp maybe_sync_vector_index(_conn, _model, _dimensions, _source, count), do: {:ok, count}

  defp delete_vector_index(conn, model, dimensions, source) do
    table = vector_table_name(dimensions)

    with {:ok, rowids} <-
           query(
             conn,
             "SELECT rowid FROM embedding_vector_items WHERE model = ? AND dimensions = ? AND (? IS NULL OR source = ?)",
             [model, dimensions, source, source]
           ),
         :ok <- delete_vector_rows(conn, table, rowids) do
      execute(
        conn,
        "DELETE FROM embedding_vector_items WHERE model = ? AND dimensions = ? AND (? IS NULL OR source = ?)",
        [model, dimensions, source, source]
      )
    end
  end

  defp delete_vector_rows(conn, table, rowids) do
    Enum.reduce_while(rowids, :ok, fn [rowid], :ok ->
      case execute(conn, "DELETE FROM #{table} WHERE rowid = ?", [rowid]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_vector_rows(conn, model, dimensions, source, rows) do
    table = vector_table_name(dimensions)

    rows
    |> Enum.reduce_while({:ok, 0}, fn [iri, run_iri, text_hash, text_chars, blob], {:ok, count} ->
      case insert_vector_row(
             conn,
             table,
             model,
             dimensions,
             iri,
             run_iri,
             text_hash,
             text_chars,
             blob,
             source
           ) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_vector_row(
         conn,
         table,
         model,
         dimensions,
         iri,
         run_iri,
         text_hash,
         text_chars,
         blob,
         source
       ) do
    with :ok <-
           execute(
             conn,
             """
             INSERT INTO embedding_vector_items
               (iri, run_iri, text_hash, model, dimensions, text_chars, source)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             """,
             [iri, run_iri, text_hash, model, dimensions, text_chars, source]
           ),
         {:ok, [[rowid]]} <- query(conn, "SELECT last_insert_rowid()", []) do
      execute(conn, "INSERT INTO #{table}(rowid, embedding) VALUES (?, ?)", [
        rowid,
        {:blob, blob}
      ])
    end
  end

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        {:ok, _count} = ok ->
          case Sqlite3.execute(conn, "COMMIT") do
            :ok -> ok
            {:error, reason} -> {:error, reason}
          end

        :ok ->
          case Sqlite3.execute(conn, "COMMIT") do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          _ = Sqlite3.execute(conn, "ROLLBACK")
          {:error, reason}
      end
    end
  end

  defp execute(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)

        case Sqlite3.step(conn, statement) do
          :done -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, other}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp query(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)
        Sqlite3.fetch_all(conn, statement)
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp ensure_vector_items_source_column(conn) do
    with {:ok, statement} <- Sqlite3.prepare(conn, "PRAGMA table_info(embedding_vector_items)") do
      try do
        {:ok, rows} = Sqlite3.fetch_all(conn, statement)

        has_source? =
          Enum.any?(rows, fn row ->
            Enum.at(row, 1) == "source"
          end)

        if has_source? do
          :ok
        else
          Sqlite3.execute(conn, "ALTER TABLE embedding_vector_items ADD COLUMN source TEXT")
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp ensure_parent_dir(":memory:"), do: :ok

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp decode_metadata(nil), do: %{}
  defp decode_metadata(""), do: %{}
  defp decode_metadata(json), do: Jason.decode!(json)

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp runs_sql do
    statuses = ["running", "completed", "partial", "failed"] ++ @valid_read_statuses
    status_check = statuses |> Enum.uniq() |> Enum.map(&"'#{&1}'") |> Enum.join(", ")

    """
    CREATE TABLE IF NOT EXISTS embedding_runs (
      iri TEXT PRIMARY KEY,
      model TEXT NOT NULL,
      dimensions INTEGER NOT NULL,
      source TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN (#{status_check})),
      target_count INTEGER NOT NULL DEFAULT 0,
      embedded_count INTEGER NOT NULL DEFAULT 0,
      skipped_count INTEGER NOT NULL DEFAULT 0,
      error_count INTEGER NOT NULL DEFAULT 0,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}'
    )
    """
  end

  defp embeddings_sql do
    """
    CREATE TABLE IF NOT EXISTS embeddings (
      iri TEXT NOT NULL,
      run_iri TEXT NOT NULL,
      text_hash TEXT NOT NULL,
      text_chars INTEGER NOT NULL,
      embedding BLOB NOT NULL,
      inserted_at TEXT NOT NULL,
      PRIMARY KEY (run_iri, iri),
      FOREIGN KEY (run_iri) REFERENCES embedding_runs(iri) ON DELETE CASCADE
    )
    """
  end

  defp vector_items_sql do
    """
    CREATE TABLE IF NOT EXISTS embedding_vector_items (
      rowid INTEGER PRIMARY KEY,
      iri TEXT NOT NULL,
      run_iri TEXT NOT NULL,
      text_hash TEXT NOT NULL,
      model TEXT NOT NULL,
      dimensions INTEGER NOT NULL,
      text_chars INTEGER NOT NULL,
      source TEXT
    )
    """
  end
end
