defmodule Sheaf.Search.Index do
  @moduledoc """
  SQLite-backed full-text mirror for searchable RDF text units.

  RDF remains the source of truth. This module owns a derived sidecar table
  that can be rebuilt from Quadlog and queried with SQLite FTS5.
  """

  require Logger

  alias Exqlite.Sqlite3
  alias Sheaf.{Embedding, Id}

  @default_path "var/sheaf-embeddings.sqlite3"
  @log_every 5_000
  @valid_kinds ~w(paragraph sourceHtml row)

  @type conn :: Sqlite3.db()

  @doc """
  Rebuilds the search mirror from current RDF text units.
  """
  @spec sync(keyword()) :: {:ok, map()} | {:error, term()}
  def sync(opts \\ []) do
    db_path = path(opts)
    Logger.info("Search sync: reading RDF text units from Quadlog")

    with {:ok, units} <- text_units(opts),
         {:ok, conn} <- open(opts) do
      Logger.info(
        "Search sync: loaded #{length(units)} text units#{kind_summary(Enum.frequencies_by(units, & &1.kind))}"
      )

      Logger.info("Search sync: rebuilding SQLite mirror at #{db_path}")

      try do
        with {:ok, summary} <- rebuild(conn, units) do
          Logger.info("Search sync: complete, #{summary.count} rows indexed")
          {:ok, Map.put(summary, :db_path, db_path)}
        end
      after
        close(conn)
      end
    end
  end

  @doc """
  Fetches searchable text units from the current RDF dataset.
  """
  @spec text_units(keyword()) :: {:ok, [map()]} | {:error, term()}
  def text_units(opts \\ []) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()

    with {:ok, rows} <- Sheaf.TextUnits.fetch_rows(kinds: kinds) do
      units =
        rows
        |> Enum.map(&unit_from_row(&1))
        |> Enum.reject(&reject_unit?/1)
        |> maybe_limit_units(opts)

      {:ok, units}
    end
  end

  @doc """
  Opens and migrates the sidecar SQLite database.
  """
  @spec open(keyword()) :: {:ok, conn()} | {:error, term()}
  def open(opts \\ []) do
    db_path = path(opts)

    with :ok <- ensure_parent_dir(db_path),
         {:ok, conn} <- Sqlite3.open(db_path),
         :ok <- migrate(conn) do
      {:ok, conn}
    end
  end

  @spec close(conn()) :: :ok | {:error, term()}
  def close(conn), do: Sqlite3.close(conn)

  @doc """
  Returns the configured sidecar database path.
  """
  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:path)

    fallback =
      :sheaf
      |> Application.get_env(Embedding.Store, [])
      |> Keyword.get(:path, @default_path)

    Keyword.get(opts, :db_path, configured || fallback)
  end

  @doc """
  Ensures the search tables exist.
  """
  @spec migrate(conn()) :: :ok | {:error, term()}
  def migrate(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys = ON"),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL"),
         :ok <- Sqlite3.execute(conn, search_text_units_sql()),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS search_text_units_doc_idx ON search_text_units(doc_iri)"
           ),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS search_text_units_kind_idx ON search_text_units(kind)"
           ),
         :ok <- ensure_metadata_columns(conn) do
      Sqlite3.execute(conn, search_text_units_fts_sql())
    end
  end

  @doc """
  Replaces all mirrored text rows and rebuilds the FTS index.
  """
  @spec rebuild(conn(), [map()]) :: {:ok, map()} | {:error, term()}
  def rebuild(conn, units) when is_list(units) do
    synced_at = now_iso8601()
    total = length(units)

    transaction(conn, fn ->
      Logger.info("Search sync: clearing old search rows")

      with :ok <- execute(conn, "DELETE FROM search_text_units", []),
           _ <- Logger.info("Search sync: inserting #{total} search rows"),
           :ok <- insert_units(conn, units, synced_at),
           _ <- Logger.info("Search sync: rebuilding FTS index"),
           :ok <- rebuild_fts(conn) do
        {:ok,
         %{
           count: length(units),
           kinds: Enum.frequencies_by(units, & &1.kind),
           synced_at: synced_at
         }}
      end
    end)
  end

  @doc """
  Searches the sidecar FTS table.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)

    if query == "" do
      {:ok, []}
    else
      with {:ok, conn} <- open(opts) do
        try do
          search_loaded(conn, query, opts)
        after
          close(conn)
        end
      end
    end
  end

  @doc false
  def search_loaded(conn, query, opts \\ []) when is_binary(query) do
    limit = Keyword.get(opts, :limit, 20)
    candidate_limit = Keyword.get(opts, :candidate_limit, max(limit * 10, 500))
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()
    document_id = Keyword.get(opts, :document_id)
    phrase = String.downcase(String.trim(query))

    {where, params} =
      fts_expression(query)
      |> add_document_filter(document_id)

    sql = """
    SELECT u.iri, u.doc_iri, u.kind, u.text, u.text_hash, u.source_page,
           u.source_block_type, u.spreadsheet_row, u.spreadsheet_source,
           u.code_category_title,
           bm25(search_text_units_fts) AS rank,
           instr(lower(u.text), ?) > 0 AS exact_match
    FROM search_text_units_fts
    JOIN search_text_units u ON u.rowid = search_text_units_fts.rowid
    WHERE #{where}
    ORDER BY exact_match DESC, rank ASC, u.iri ASC
    LIMIT ?
    """

    with {:ok, rows} <- query(conn, sql, [phrase] ++ params ++ [candidate_limit]) do
      {:ok,
       rows
       |> Enum.map(&row_to_result/1)
       |> Enum.filter(&(&1.kind in kinds))
       |> Enum.take(limit)}
    end
  end

  @doc """
  Returns mirrored text units by IRI from the sidecar table.
  """
  @spec units_by_iris([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def units_by_iris(iris, opts \\ []) when is_list(iris) do
    iris = iris |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if iris == [] do
      {:ok, %{}}
    else
      with {:ok, conn} <- open(opts) do
        try do
          units_by_iris_loaded(conn, iris)
        after
          close(conn)
        end
      end
    end
  end

  @doc false
  def units_by_iris_loaded(conn, iris) when is_list(iris) do
    placeholders = iris |> Enum.map(fn _ -> "?" end) |> Enum.join(", ")

    sql = """
    SELECT iri, doc_iri, kind, text, text_hash, source_page, source_block_type,
           spreadsheet_row, spreadsheet_source, code_category_title
    FROM search_text_units
    WHERE iri IN (#{placeholders})
    """

    with {:ok, rows} <- query(conn, sql, iris) do
      rows
      |> Enum.map(&unit_row/1)
      |> Map.new(&{&1.iri, &1})
      |> then(&{:ok, &1})
    end
  end

  defp add_document_filter({conditions, params}, nil),
    do: {Enum.join(conditions, " AND "), params}

  defp add_document_filter({conditions, params}, ""), do: {Enum.join(conditions, " AND "), params}

  defp add_document_filter({conditions, params}, document_id) do
    {Enum.join(conditions ++ ["u.doc_iri = ?"], " AND "),
     params ++ [document_id |> Id.iri() |> to_string()]}
  end

  defp fts_expression(query) do
    terms = search_terms(query)
    phrase = quote_fts(query)

    expression =
      case terms do
        [] -> phrase
        terms -> ([phrase] ++ Enum.map(terms, &quote_fts/1)) |> Enum.join(" OR ")
      end

    {["search_text_units_fts MATCH ?"], [expression]}
  end

  defp search_terms(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> Enum.map(fn [term] -> term end)
    |> Enum.uniq()
  end

  defp quote_fts(value) do
    escaped =
      value
      |> String.trim()
      |> String.replace("\"", "\"\"")

    "\"" <> escaped <> "\""
  end

  defp row_to_result(row) do
    [rank, exact_match] = Enum.slice(row, 10, 2)
    lexical_score = lexical_score(rank, exact_match)

    row
    |> Enum.take(10)
    |> unit_row()
    |> Map.merge(%{
      score: lexical_score,
      lexical_score: lexical_score,
      semantic_score: nil,
      match: :exact,
      run_iri: nil
    })
  end

  defp unit_row([
         iri,
         doc_iri,
         kind,
         text,
         text_hash,
         source_page,
         source_block_type,
         spreadsheet_row,
         spreadsheet_source,
         code_category_title
       ]) do
    %{
      iri: iri,
      doc_iri: doc_iri,
      kind: kind,
      text: text,
      text_hash: text_hash,
      source_page: source_page,
      source_block_type: source_block_type,
      spreadsheet_row: spreadsheet_row,
      spreadsheet_source: spreadsheet_source,
      code_category_title: code_category_title
    }
  end

  defp lexical_score(_rank, exact_match) when exact_match in [1, true], do: 0.98
  defp lexical_score(rank, _exact_match) when is_number(rank), do: min(0.95, 0.72 + abs(rank))
  defp lexical_score(_rank, _exact_match), do: 0.75

  defp insert_units(conn, units, synced_at) do
    total = length(units)

    units
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {unit, index}, :ok ->
      case insert_unit(conn, unit, synced_at) do
        :ok ->
          log_insert_progress(index, total)
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp log_insert_progress(index, total) do
    if rem(index, @log_every) == 0 or index == total do
      Logger.info("Search sync: inserted #{index}/#{total} search rows")
    end
  end

  defp kind_summary(kinds) when map_size(kinds) == 0, do: ""

  defp kind_summary(kinds) do
    kinds
    |> Enum.sort()
    |> Enum.map(fn {kind, count} -> "#{kind}=#{count}" end)
    |> Enum.join(" ")
    |> then(&(" (" <> &1 <> ")"))
  end

  defp unit_from_row(row) do
    %{
      iri: row |> Map.fetch!("iri") |> term_value(),
      doc_iri: row |> Map.get("doc") |> term_value(),
      kind: row |> Map.fetch!("kind") |> term_value(),
      text: row |> Map.fetch!("text") |> term_value(),
      source_page: row |> Map.get("sourcePage") |> integer_value(),
      source_block_type: row |> Map.get("sourceBlockType") |> term_value(),
      spreadsheet_row: row |> Map.get("spreadsheetRow") |> integer_value(),
      spreadsheet_source: row |> Map.get("spreadsheetSource") |> term_value(),
      code_category_title: row |> Map.get("codeCategoryTitle") |> term_value()
    }
  end

  defp reject_unit?(%{text: text}) when text in [nil, ""], do: true
  defp reject_unit?(%{kind: "sourceHtml", text: text}), do: source_html_noise?(text)
  defp reject_unit?(_unit), do: false

  defp source_html_noise?(text) when is_binary(text) do
    String.contains?(text, ";base64,") or String.contains?(text, "data:image/")
  end

  defp source_html_noise?(_text), do: false

  defp maybe_limit_units(units, opts) do
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> Enum.take(units, limit)
      _ -> units
    end
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()

  defp integer_value(nil), do: nil
  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(%RDF.Literal{} = literal) do
    literal
    |> RDF.Literal.value()
    |> integer_value()
  end

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp insert_unit(conn, unit, synced_at) do
    execute(
      conn,
      """
      INSERT INTO search_text_units
        (iri, doc_iri, kind, text, text_hash, source_page, source_block_type,
         spreadsheet_row, spreadsheet_source, code_category_title, synced_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        Map.fetch!(unit, :iri),
        Map.get(unit, :doc_iri),
        Map.fetch!(unit, :kind),
        Map.fetch!(unit, :text),
        text_hash(Map.fetch!(unit, :text)),
        Map.get(unit, :source_page),
        Map.get(unit, :source_block_type),
        Map.get(unit, :spreadsheet_row),
        Map.get(unit, :spreadsheet_source),
        Map.get(unit, :code_category_title),
        synced_at
      ]
    )
  end

  defp ensure_metadata_columns(conn) do
    with {:ok, columns} <- table_columns(conn, "search_text_units") do
      [
        {"source_page", "INTEGER"},
        {"source_block_type", "TEXT"},
        {"spreadsheet_row", "INTEGER"},
        {"spreadsheet_source", "TEXT"},
        {"code_category_title", "TEXT"}
      ]
      |> Enum.reduce_while(:ok, fn {column, type}, :ok ->
        if MapSet.member?(columns, column) do
          {:cont, :ok}
        else
          case Sqlite3.execute(conn, "ALTER TABLE search_text_units ADD COLUMN #{column} #{type}") do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
      end)
    end
  end

  defp table_columns(conn, table) do
    with {:ok, rows} <- query(conn, "PRAGMA table_info(#{table})", []) do
      rows
      |> Enum.map(fn [_cid, name, _type, _notnull, _default, _pk] -> name end)
      |> MapSet.new()
      |> then(&{:ok, &1})
    end
  end

  defp text_hash(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp rebuild_fts(conn) do
    execute(
      conn,
      "INSERT INTO search_text_units_fts(search_text_units_fts) VALUES ('rebuild')",
      []
    )
  end

  defp transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        {:ok, _summary} = ok ->
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

  defp ensure_parent_dir(":memory:"), do: :ok

  defp ensure_parent_dir(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp search_text_units_sql do
    """
    CREATE TABLE IF NOT EXISTS search_text_units (
      iri TEXT PRIMARY KEY,
      doc_iri TEXT,
      kind TEXT NOT NULL,
      text TEXT NOT NULL,
      text_hash TEXT NOT NULL,
      source_page INTEGER,
      source_block_type TEXT,
      spreadsheet_row INTEGER,
      spreadsheet_source TEXT,
      code_category_title TEXT,
      synced_at TEXT NOT NULL
    )
    """
  end

  defp search_text_units_fts_sql do
    """
    CREATE VIRTUAL TABLE IF NOT EXISTS search_text_units_fts
    USING fts5(text, content='search_text_units', content_rowid='rowid')
    """
  end
end
