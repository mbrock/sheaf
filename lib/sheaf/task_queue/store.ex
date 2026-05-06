defmodule Sheaf.TaskQueue.Store do
  @moduledoc """
  SQLite storage for small durable task batches.

  RDF stays the semantic source of truth. This store keeps operational state:
  batches, per-task retries, locks, cached inputs/results, and errors.
  """

  alias Exqlite.Sqlite3

  @default_path "var/sheaf-embeddings.sqlite3"
  @statuses [
    "pending",
    "running",
    "completed",
    "partial",
    "failed",
    "canceled"
  ]

  @type conn :: Sqlite3.db()

  @spec open(keyword()) :: {:ok, conn()} | {:error, term()}
  def open(opts \\ []) do
    path = path(opts)

    with :ok <- ensure_parent_dir(path),
         {:ok, conn} <- Sqlite3.open(path),
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
      |> Keyword.get(:path)

    fallback =
      :sheaf
      |> Application.get_env(Sheaf.Embedding.Store, [])
      |> Keyword.get(:path, @default_path)

    Keyword.get(opts, :db_path, configured || fallback)
  end

  @spec migrate(conn()) :: :ok | {:error, term()}
  def migrate(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys = ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL"),
         :ok <- Sqlite3.execute(conn, batches_sql()),
         :ok <- Sqlite3.execute(conn, tasks_sql()),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS tasks_status_idx ON tasks(queue, status, run_after, priority)"
           ),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS tasks_batch_idx ON tasks(batch_id)"
           ) do
      :ok
    end
  end

  @spec create_batch(conn(), map(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def create_batch(conn, attrs, tasks)
      when is_map(attrs) and is_list(tasks) do
    batch_iri = Map.fetch!(attrs, :iri)
    now = now_iso8601()

    transaction(conn, fn ->
      with :ok <-
             execute(
               conn,
               """
               INSERT INTO task_batches
                 (iri, queue, kind, status, target_count, input_json, inserted_at, updated_at)
               VALUES (?, ?, ?, 'pending', ?, ?, ?, ?)
               ON CONFLICT(iri) DO UPDATE SET
                 queue = excluded.queue,
                 kind = excluded.kind,
                 target_count = excluded.target_count,
                 input_json = excluded.input_json,
                 updated_at = excluded.updated_at
               """,
               [
                 batch_iri,
                 Map.fetch!(attrs, :queue),
                 Map.fetch!(attrs, :kind),
                 length(tasks),
                 encode_json(Map.get(attrs, :input, %{})),
                 now,
                 now
               ]
             ),
           {:ok, batch} <- get_batch(conn, batch_iri),
           :ok <- insert_tasks(conn, batch.id, attrs, tasks, now) do
        {:ok, batch}
      end
    end)
  end

  @spec create_task(conn(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def create_task(conn, batch_iri, attrs, task)
      when is_binary(batch_iri) and is_map(attrs) and is_map(task) do
    now = now_iso8601()

    transaction(conn, fn ->
      with {:ok, batch} when not is_nil(batch) <- get_batch(conn, batch_iri),
           :ok <- insert_tasks(conn, batch.id, attrs, [task], now),
           :ok <-
             execute(
               conn,
               """
               UPDATE task_batches
               SET target_count = (SELECT COUNT(*) FROM tasks WHERE batch_id = ?),
                   updated_at = ?,
                   finished_at = NULL,
                   status = CASE WHEN status IN ('completed', 'partial', 'failed', 'canceled') THEN 'running' ELSE status END
               WHERE id = ?
               """,
               [batch.id, now, batch.id]
             ) do
        get_task_by_unique_key(conn, Map.fetch!(task, :unique_key))
      else
        {:ok, nil} -> {:error, :missing_batch}
        error -> error
      end
    end)
  end

  @spec get_batch(conn(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def get_batch(conn, iri) do
    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT id, iri, queue, kind, status, target_count, completed_count,
                    failed_count, skipped_count, input_json, result_json, error_json,
                    inserted_at, updated_at, started_at, finished_at
             FROM task_batches
             WHERE iri = ?
             LIMIT 1
             """,
             [iri]
           ) do
      {:ok, rows |> Enum.map(&batch_row/1) |> List.first()}
    end
  end

  @spec list_batches(conn(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_batches(conn, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    query(
      conn,
      """
      SELECT id, iri, queue, kind, status, target_count, completed_count,
             failed_count, skipped_count, input_json, result_json, error_json,
             inserted_at, updated_at, started_at, finished_at
      FROM task_batches
      ORDER BY id DESC
      LIMIT ?
      """,
      [limit]
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &batch_row/1)}
      error -> error
    end
  end

  @spec list_tasks(conn(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_tasks(conn, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    {where, params} =
      if status do
        {"WHERE t.status = ?", [to_string(status)]}
      else
        {"", []}
      end

    query(
      conn,
      """
      SELECT t.id, t.batch_id, b.iri, t.iri, t.queue, t.kind, t.status, t.priority,
             t.subject_iri, t.identifier, t.unique_key, t.attempts, t.max_attempts,
             t.run_after, t.locked_by, t.locked_until, t.input_json, t.result_json,
             t.error_json, t.inserted_at, t.updated_at, t.started_at, t.finished_at
      FROM tasks t
      JOIN task_batches b ON b.id = t.batch_id
      #{where}
      ORDER BY t.id DESC
      LIMIT ?
      """,
      params ++ [limit]
    )
    |> case do
      {:ok, rows} -> {:ok, Enum.map(rows, &task_row/1)}
      error -> error
    end
  end

  @spec claim_task(conn(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def claim_task(conn, opts \\ []) do
    queue = Keyword.get(opts, :queue, "metadata")
    kind = Keyword.get(opts, :kind)
    worker = Keyword.get(opts, :worker, default_worker())
    lease_seconds = Keyword.get(opts, :lease_seconds, 300)
    now = now_iso8601()

    locked_until =
      DateTime.utc_now()
      |> DateTime.add(lease_seconds, :second)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    transaction(conn, fn ->
      with {:ok, [task | _]} <-
             query(
               conn,
               """
               SELECT t.id, t.batch_id, b.iri, t.iri, t.queue, t.kind, t.status, t.priority,
                      t.subject_iri, t.identifier, t.unique_key, t.attempts, t.max_attempts,
                      t.run_after, t.locked_by, t.locked_until, t.input_json, t.result_json,
                      t.error_json, t.inserted_at, t.updated_at, t.started_at, t.finished_at
               FROM tasks t
               JOIN task_batches b ON b.id = t.batch_id
               WHERE t.queue = ?
                 AND (? IS NULL OR t.kind = ?)
                 AND t.status = 'pending'
                 AND (t.run_after IS NULL OR t.run_after <= ?)
               ORDER BY t.priority DESC, t.id ASC
               LIMIT 1
               """,
               [queue, kind, kind, now]
             ) do
        task = task_row(task)

        with :ok <-
               execute(
                 conn,
                 """
                 UPDATE tasks
                 SET status = 'running',
                     attempts = attempts + 1,
                     locked_by = ?,
                     locked_until = ?,
                     started_at = COALESCE(started_at, ?),
                     updated_at = ?
                 WHERE id = ? AND status = 'pending'
                 """,
                 [worker, locked_until, now, now, task.id]
               ),
             :ok <- mark_batch_running(conn, task.batch_id, now),
             {:ok, [claimed]} <- query_claimed_task(conn, task.id) do
          {:ok, task_row(claimed)}
        end
      else
        {:ok, []} -> {:ok, nil}
        error -> error
      end
    end)
  end

  @spec complete_task(conn(), integer(), map()) :: :ok | {:error, term()}
  def complete_task(conn, task_id, result \\ %{}) do
    now = now_iso8601()

    transaction(conn, fn ->
      with {:ok, [task]} <- query_claimed_task(conn, task_id),
           task = task_row(task),
           :ok <-
             execute(
               conn,
               """
               UPDATE tasks
               SET status = 'completed',
                   result_json = ?,
                   error_json = NULL,
                   locked_by = NULL,
                   locked_until = NULL,
                   updated_at = ?,
                   finished_at = ?
               WHERE id = ?
               """,
               [encode_json(result), now, now, task_id]
             ),
           :ok <- refresh_batch_counts(conn, task.batch_id) do
        :ok
      end
    end)
  end

  @spec fail_task(conn(), integer(), term(), keyword()) ::
          :ok | {:error, term()}
  def fail_task(conn, task_id, reason, opts \\ []) do
    now = now_iso8601()

    transaction(conn, fn ->
      with {:ok, [row]} <- query_claimed_task(conn, task_id) do
        task = task_row(row)
        terminal? = task.attempts >= task.max_attempts
        status = if terminal?, do: "failed", else: "pending"

        run_after =
          if terminal?, do: nil, else: backoff_time(task.attempts, opts)

        with :ok <-
               execute(
                 conn,
                 """
                 UPDATE tasks
                 SET status = ?,
                     run_after = ?,
                     error_json = ?,
                     locked_by = NULL,
                     locked_until = NULL,
                     updated_at = ?,
                     finished_at = CASE WHEN ? = 'failed' THEN ? ELSE finished_at END
                 WHERE id = ?
                 """,
                 [
                   status,
                   run_after,
                   encode_json(error_payload(reason)),
                   now,
                   status,
                   now,
                   task_id
                 ]
               ),
             :ok <- refresh_batch_counts(conn, task.batch_id) do
          :ok
        end
      end
    end)
  end

  defp insert_tasks(conn, batch_id, attrs, tasks, now) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      values = [
        batch_id,
        Map.get(task, :iri),
        Map.fetch!(attrs, :queue),
        Map.fetch!(task, :kind),
        Map.get(task, :priority, 0),
        Map.get(task, :subject_iri),
        Map.get(task, :identifier),
        Map.fetch!(task, :unique_key),
        Map.get(task, :max_attempts, 3),
        Map.get(task, :run_after),
        encode_json(Map.get(task, :input, %{})),
        now,
        now
      ]

      case execute(conn, insert_task_sql(), values) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_task_sql do
    """
    INSERT INTO tasks
      (batch_id, iri, queue, kind, priority, subject_iri, identifier, unique_key,
       max_attempts, run_after, input_json, inserted_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(unique_key) DO UPDATE SET
      batch_id = excluded.batch_id,
      priority = excluded.priority,
      input_json = excluded.input_json,
      updated_at = excluded.updated_at
    """
  end

  defp mark_batch_running(conn, batch_id, now) do
    execute(
      conn,
      """
      UPDATE task_batches
      SET status = 'running',
          started_at = COALESCE(started_at, ?),
          updated_at = ?
      WHERE id = ? AND status = 'pending'
      """,
      [now, now, batch_id]
    )
  end

  defp refresh_batch_counts(conn, batch_id) do
    now = now_iso8601()

    with {:ok, rows} <-
           query(
             conn,
             """
             SELECT
               SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END),
               SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END),
               SUM(CASE WHEN status = 'canceled' THEN 1 ELSE 0 END),
               COUNT(*),
               SUM(CASE WHEN status IN ('pending', 'running') THEN 1 ELSE 0 END)
             FROM tasks
             WHERE batch_id = ?
             """,
             [batch_id]
           ) do
      [[completed, failed, skipped, total, open]] = rows
      completed = completed || 0
      failed = failed || 0
      skipped = skipped || 0
      open = open || 0

      status =
        cond do
          open > 0 -> "running"
          failed > 0 and completed > 0 -> "partial"
          failed > 0 -> "failed"
          skipped > 0 and completed == 0 -> "canceled"
          total == 0 -> "completed"
          true -> "completed"
        end

      execute(
        conn,
        """
        UPDATE task_batches
        SET status = ?,
            completed_count = ?,
            failed_count = ?,
            skipped_count = ?,
            updated_at = ?,
            finished_at = CASE WHEN ? IN ('completed', 'partial', 'failed', 'canceled') THEN ? ELSE finished_at END
        WHERE id = ?
        """,
        [status, completed, failed, skipped, now, status, now, batch_id]
      )
    end
  end

  defp query_claimed_task(conn, task_id) do
    query(
      conn,
      """
      SELECT t.id, t.batch_id, b.iri, t.iri, t.queue, t.kind, t.status, t.priority,
             t.subject_iri, t.identifier, t.unique_key, t.attempts, t.max_attempts,
             t.run_after, t.locked_by, t.locked_until, t.input_json, t.result_json,
             t.error_json, t.inserted_at, t.updated_at, t.started_at, t.finished_at
      FROM tasks t
      JOIN task_batches b ON b.id = t.batch_id
      WHERE t.id = ?
      LIMIT 1
      """,
      [task_id]
    )
  end

  defp get_task_by_unique_key(conn, unique_key) do
    with {:ok, [row]} <-
           query(
             conn,
             """
             SELECT t.id, t.batch_id, b.iri, t.iri, t.queue, t.kind, t.status, t.priority,
                    t.subject_iri, t.identifier, t.unique_key, t.attempts, t.max_attempts,
                    t.run_after, t.locked_by, t.locked_until, t.input_json, t.result_json,
                    t.error_json, t.inserted_at, t.updated_at, t.started_at, t.finished_at
             FROM tasks t
             JOIN task_batches b ON b.id = t.batch_id
             WHERE t.unique_key = ?
             LIMIT 1
             """,
             [unique_key]
           ) do
      {:ok, task_row(row)}
    end
  end

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        {:ok, _} = ok -> commit(conn, ok)
        :ok -> commit(conn, :ok)
        {:error, reason} -> rollback(conn, reason)
      end
    end
  end

  defp commit(conn, value) do
    case Sqlite3.execute(conn, "COMMIT") do
      :ok -> value
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback(conn, reason) do
    _ = Sqlite3.execute(conn, "ROLLBACK")
    {:error, reason}
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

  defp batch_row([
         id,
         iri,
         queue,
         kind,
         status,
         target_count,
         completed_count,
         failed_count,
         skipped_count,
         input_json,
         result_json,
         error_json,
         inserted_at,
         updated_at,
         started_at,
         finished_at
       ]) do
    %{
      id: id,
      iri: iri,
      queue: queue,
      kind: kind,
      status: status,
      target_count: target_count,
      completed_count: completed_count,
      failed_count: failed_count,
      skipped_count: skipped_count,
      input: decode_json(input_json),
      result: decode_json(result_json),
      error: decode_json(error_json),
      inserted_at: inserted_at,
      updated_at: updated_at,
      started_at: started_at,
      finished_at: finished_at
    }
  end

  defp task_row([
         id,
         batch_id,
         batch_iri,
         iri,
         queue,
         kind,
         status,
         priority,
         subject_iri,
         identifier,
         unique_key,
         attempts,
         max_attempts,
         run_after,
         locked_by,
         locked_until,
         input_json,
         result_json,
         error_json,
         inserted_at,
         updated_at,
         started_at,
         finished_at
       ]) do
    %{
      id: id,
      batch_id: batch_id,
      batch_iri: batch_iri,
      iri: iri,
      queue: queue,
      kind: kind,
      status: status,
      priority: priority,
      subject_iri: subject_iri,
      identifier: identifier,
      unique_key: unique_key,
      attempts: attempts,
      max_attempts: max_attempts,
      run_after: run_after,
      locked_by: locked_by,
      locked_until: locked_until,
      input: decode_json(input_json),
      result: decode_json(result_json),
      error: decode_json(error_json),
      inserted_at: inserted_at,
      updated_at: updated_at,
      started_at: started_at,
      finished_at: finished_at
    }
  end

  defp backoff_time(attempts, opts) do
    base = Keyword.get(opts, :backoff_seconds, 60)
    seconds = min(base * round(:math.pow(2, max(attempts - 1, 0))), 3600)

    DateTime.utc_now()
    |> DateTime.add(seconds, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp error_payload(reason), do: %{message: inspect(reason)}

  defp encode_json(value), do: Jason.encode!(value || %{})
  defp decode_json(nil), do: %{}
  defp decode_json(""), do: %{}
  defp decode_json(json), do: Jason.decode!(json)

  defp ensure_parent_dir(":memory:"), do: :ok

  defp ensure_parent_dir(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp default_worker do
    [to_string(Node.self()), to_string(System.pid())]
    |> Enum.reject(&(&1 in ["", "nonode@nohost"]))
    |> Enum.join(":")
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp status_check do
    @statuses |> Enum.map(&"'#{&1}'") |> Enum.join(", ")
  end

  defp batches_sql do
    """
    CREATE TABLE IF NOT EXISTS task_batches (
      id INTEGER PRIMARY KEY,
      iri TEXT NOT NULL UNIQUE,
      queue TEXT NOT NULL,
      kind TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN (#{status_check()})),
      target_count INTEGER NOT NULL DEFAULT 0,
      completed_count INTEGER NOT NULL DEFAULT 0,
      failed_count INTEGER NOT NULL DEFAULT 0,
      skipped_count INTEGER NOT NULL DEFAULT 0,
      input_json TEXT NOT NULL DEFAULT '{}',
      result_json TEXT,
      error_json TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT
    )
    """
  end

  defp tasks_sql do
    """
    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY,
      batch_id INTEGER NOT NULL,
      iri TEXT UNIQUE,
      queue TEXT NOT NULL,
      kind TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN (#{status_check()})),
      priority INTEGER NOT NULL DEFAULT 0,
      subject_iri TEXT,
      identifier TEXT,
      unique_key TEXT NOT NULL UNIQUE,
      attempts INTEGER NOT NULL DEFAULT 0,
      max_attempts INTEGER NOT NULL DEFAULT 3,
      run_after TEXT,
      locked_by TEXT,
      locked_until TEXT,
      input_json TEXT NOT NULL DEFAULT '{}',
      result_json TEXT,
      error_json TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      FOREIGN KEY (batch_id) REFERENCES task_batches(id) ON DELETE CASCADE
    )
    """
  end
end
