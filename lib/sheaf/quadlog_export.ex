defmodule Sheaf.QuadlogExport do
  @moduledoc """
  Exports Quadlog snapshots for analytical notebooks.
  """

  @default_sqlite_path "var/sheaf-quadlog.sqlite3"
  @default_parquet_path "var/quadlog-values.parquet"

  def to_parquet(
        sqlite_path \\ @default_sqlite_path,
        parquet_path \\ @default_parquet_path
      ) do
    sqlite_path = Path.expand(sqlite_path)
    parquet_path = Path.expand(parquet_path)

    with :ok <- File.mkdir_p(Path.dirname(parquet_path)),
         {:ok, db} <- open_duckdb(),
         {:ok, conn} <- Adbc.Connection.start_link(database: db) do
      try do
        attach_sqlite!(conn, sqlite_path)
        row_count = count_quads!(conn)
        export_values!(conn, parquet_path)

        {:ok,
         %{
           path: parquet_path,
           rows: row_count,
           bytes: File.stat!(parquet_path).size
         }}
      after
        if Process.alive?(conn), do: GenServer.stop(conn)
        if Process.alive?(db), do: GenServer.stop(db)
      end
    end
  end

  defp open_duckdb do
    Adbc.download_driver!(:duckdb)
    Adbc.Database.start_link(driver: :duckdb)
  end

  defp attach_sqlite!(conn, sqlite_path) do
    escaped = escape_sql_string(sqlite_path)

    Adbc.Connection.query!(conn, "INSTALL sqlite")
    Adbc.Connection.query!(conn, "LOAD sqlite")

    Adbc.Connection.query!(
      conn,
      "ATTACH '#{escaped}' AS quadlog (TYPE sqlite, READ_ONLY)"
    )
  end

  defp count_quads!(conn) do
    conn
    |> Adbc.Connection.query!("SELECT COUNT(*) AS count FROM quadlog.quads")
    |> Adbc.Result.materialize()
    |> scalar!("count")
  end

  defp export_values!(conn, parquet_path) do
    escaped = escape_sql_string(parquet_path)

    Adbc.Connection.query!(conn, """
    COPY (
      SELECT
        q.graph_id,
        g.value AS graph,
        q.subject_id,
        s.value AS subject,
        q.predicate_id,
        p.value AS predicate,
        q.object_id,
        o.kind AS object_kind,
        o.value AS object_value,
        dt.value AS object_datatype,
        o.lang AS object_lang
      FROM quadlog.quads q
      JOIN quadlog.terms g ON g.id = q.graph_id
      JOIN quadlog.terms s ON s.id = q.subject_id
      JOIN quadlog.terms p ON p.id = q.predicate_id
      JOIN quadlog.terms o ON o.id = q.object_id
      LEFT JOIN quadlog.terms dt ON dt.id = o.datatype_id
    ) TO '#{escaped}' (FORMAT PARQUET)
    """)

    :ok
  end

  defp scalar!(materialized, column_name) do
    materialized.data
    |> List.flatten()
    |> Enum.find(fn column -> column.field.name == column_name end)
    |> Adbc.Column.to_list()
    |> List.first()
  end

  defp escape_sql_string(value), do: String.replace(value, "'", "''")
end
