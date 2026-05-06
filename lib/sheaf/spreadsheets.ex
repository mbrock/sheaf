defmodule Sheaf.Spreadsheets do
  @moduledoc """
  SQLite sidecar storage for working spreadsheet data.

  Spreadsheet workbooks are operational/tabular data, not document prose. The RDF
  store remains the semantic document graph; this module keeps imported workbook
  sheets in regular SQLite tables that assistant tools can inspect and query.
  """

  require Record

  alias Exqlite.Sqlite3

  Record.defrecord(
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @default_path "var/sheaf-embeddings.sqlite3"

  @type conn :: Sqlite3.db()

  @doc """
  Imports an `.xlsx` workbook into the sidecar database.
  """
  @spec import_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def import_file(path, opts \\ []) when is_binary(path) do
    with {:ok, workbook} <- read_xlsx(path),
         {:ok, conn} <- open(opts) do
      try do
        import_workbook(conn, path, workbook, opts)
      after
        close(conn)
      end
    end
  end

  @doc """
  Lists imported spreadsheets and their sheet tables.
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, conn} <- open(opts) do
      try do
        list_loaded(conn)
      after
        close(conn)
      end
    end
  end

  @doc """
  Searches imported spreadsheet rows with exact-ish LIKE matching.
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

  @doc """
  Runs a read-only SQL query against imported spreadsheet tables.

  The statement runs with SQLite `query_only` enabled and returns at most the
  requested number of rows. This intentionally avoids brittle SQL pre-parsing:
  SQLite decides what is valid, and write attempts fail at execution time.
  """
  @spec query(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(sql, opts \\ []) when is_binary(sql) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()

    with {:ok, conn} <- open(opts) do
      try do
        query_loaded(conn, sql, limit)
      after
        close(conn)
      end
    end
  end

  @doc """
  Opens and migrates the configured sidecar database.
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
         :ok <- Sqlite3.execute(conn, spreadsheets_sql()),
         :ok <- Sqlite3.execute(conn, spreadsheet_sheets_sql()),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE INDEX IF NOT EXISTS spreadsheet_sheets_spreadsheet_idx ON spreadsheet_sheets(spreadsheet_id)"
           ) do
      :ok
    end
  end

  defp import_workbook(conn, path, workbook, opts) do
    stat = File.stat!(path)
    bytes = File.read!(path)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    id = Keyword.get(opts, :id, "xl_" <> String.slice(sha, 0, 12))
    title = Keyword.get(opts, :title, Path.basename(path))
    imported_at = now_iso8601()

    transaction(conn, fn ->
      with :ok <- drop_existing_sheet_tables(conn, id),
           :ok <- delete_spreadsheet(conn, id),
           :ok <-
             insert_spreadsheet(conn, %{
               id: id,
               title: title,
               path: Path.expand(path),
               basename: Path.basename(path),
               file_size: stat.size,
               file_mtime:
                 stat.mtime
                 |> NaiveDateTime.from_erl!()
                 |> NaiveDateTime.to_iso8601(),
               sha256: sha,
               imported_at: imported_at
             }),
           {:ok, sheets} <-
             import_sheets(conn, id, workbook.sheets, imported_at) do
        {:ok,
         %{
           id: id,
           title: title,
           path: Path.expand(path),
           sheets: sheets,
           imported_at: imported_at
         }}
      end
    end)
  end

  defp import_sheets(conn, spreadsheet_id, sheets, imported_at) do
    sheets
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {sheet, index}, {:ok, imported} ->
      table = "ss_#{String.downcase(spreadsheet_id)}_#{index}"

      case import_sheet(
             conn,
             spreadsheet_id,
             table,
             sheet,
             index,
             imported_at
           ) do
        {:ok, summary} -> {:cont, {:ok, [summary | imported]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, imported} -> {:ok, Enum.reverse(imported)}
      error -> error
    end
  end

  defp import_sheet(conn, spreadsheet_id, table, sheet, index, imported_at) do
    rows = sheet.rows |> Enum.reject(&empty_row?/1)
    {headers, data_rows} = headers_and_rows(rows)
    columns = sql_columns(headers)

    with :ok <- create_sheet_table(conn, table, columns),
         :ok <- insert_sheet_rows(conn, table, columns, data_rows),
         :ok <-
           insert_sheet(conn, %{
             spreadsheet_id: spreadsheet_id,
             sheet_index: index,
             name: sheet.name,
             table_name: table,
             row_count: length(data_rows),
             col_count: length(columns),
             headers: columns,
             imported_at: imported_at
           }) do
      {:ok,
       %{
         name: sheet.name,
         table_name: table,
         row_count: length(data_rows),
         col_count: length(columns),
         columns: columns
       }}
    end
  end

  defp headers_and_rows([]), do: {[], []}

  defp headers_and_rows(rows) do
    {header_row, header_index} =
      rows
      |> Enum.take(10)
      |> Enum.with_index()
      |> Enum.max_by(fn {row, index} -> {filled_cells(row), -index} end)

    headers =
      header_row.values
      |> Enum.with_index(1)
      |> Enum.map(fn {value, index} -> header_name(value, index) end)

    {headers, Enum.drop(rows, header_index + 1)}
  end

  defp filled_cells(%{values: values}),
    do: Enum.count(values, &(not blank?(&1)))

  defp header_name(nil, index), do: "column_#{index}"
  defp header_name("", index), do: "column_#{index}"

  defp header_name(value, _index) do
    value
    |> to_string()
    |> String.trim()
  end

  defp sql_columns(headers) do
    headers
    |> Enum.with_index(1)
    |> Enum.map(fn {header, index} ->
      base =
        header
        |> String.downcase()
        |> String.replace(~r/[^[:alnum:]_]+/u, "_")
        |> String.trim("_")
        |> case do
          "" -> "column_#{index}"
          value -> value
        end

      {header, base}
    end)
    |> uniquify_column_names()
    |> Enum.map(fn {header, name} -> %{header: header, name: name} end)
  end

  defp uniquify_column_names(columns) do
    columns
    |> Enum.reduce({[], %{}}, fn {header, base}, {acc, counts} ->
      count = Map.get(counts, base, 0) + 1
      name = if count == 1, do: base, else: "#{base}_#{count}"
      {[{header, name} | acc], Map.put(counts, base, count)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp create_sheet_table(conn, table, columns) do
    user_columns =
      columns
      |> Enum.map(fn %{name: name} -> "#{quote_identifier(name)} TEXT" end)
      |> Enum.join(",\n  ")

    comma = if user_columns == "", do: "", else: ",\n  "

    Sqlite3.execute(
      conn,
      """
      CREATE TABLE #{quote_identifier(table)} (
        __row_number INTEGER NOT NULL,
        __text TEXT NOT NULL#{comma}#{user_columns}
      )
      """
    )
  end

  defp insert_sheet_rows(conn, table, columns, rows) do
    rows
    |> Enum.reduce_while(:ok, fn row, :ok ->
      case insert_sheet_row(conn, table, columns, row) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_sheet_row(conn, table, columns, row) do
    names = ["__row_number", "__text" | Enum.map(columns, & &1.name)]
    placeholders = Enum.map_join(names, ", ", fn _ -> "?" end)

    values =
      columns
      |> Enum.with_index()
      |> Enum.map(fn {_column, index} -> Enum.at(row.values, index) end)

    row_text =
      values
      |> Enum.reject(&blank?/1)
      |> Enum.join(" | ")

    execute(
      conn,
      """
      INSERT INTO #{quote_identifier(table)}
        (#{Enum.map_join(names, ", ", &quote_identifier/1)})
      VALUES (#{placeholders})
      """,
      [row.number, row_text | values]
    )
  end

  defp list_loaded(conn) do
    with {:ok, spreadsheet_rows} <-
           query_rows(
             conn,
             """
             SELECT id, title, path, basename, file_size, file_mtime, sha256, imported_at
             FROM spreadsheets
             ORDER BY imported_at DESC, title ASC
             """,
             []
           ),
         {:ok, sheet_rows} <-
           query_rows(
             conn,
             """
             SELECT spreadsheet_id, sheet_index, name, table_name, row_count, col_count, headers_json, imported_at
             FROM spreadsheet_sheets
             ORDER BY spreadsheet_id ASC, sheet_index ASC
             """,
             []
           ) do
      sheets_by_spreadsheet =
        sheet_rows
        |> Enum.map(&sheet_from_row/1)
        |> Enum.group_by(& &1.spreadsheet_id)

      {:ok,
       Enum.map(spreadsheet_rows, fn row ->
         spreadsheet_from_row(
           row,
           Map.get(sheets_by_spreadsheet, Enum.at(row, 0), [])
         )
       end)}
    end
  end

  defp search_loaded(conn, query_text, opts) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_limit()
    terms = search_terms(query_text)

    if terms == [] do
      {:ok, []}
    else
      with {:ok, spreadsheets} <- list_loaded(conn) do
        spreadsheets
        |> Enum.flat_map(& &1.sheets)
        |> Enum.reduce_while({:ok, []}, fn sheet, {:ok, hits} ->
          case search_sheet(conn, sheet, terms, limit) do
            {:ok, sheet_hits} -> {:cont, {:ok, hits ++ sheet_hits}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, hits} ->
            {:ok,
             hits
             |> Enum.sort_by(
               &{-&1.score, &1.spreadsheet_id, &1.sheet_name, &1.row_number}
             )
             |> Enum.take(limit)}

          error ->
            error
        end
      end
    end
  end

  defp query_loaded(conn, sql, limit) do
    readonly_transaction(conn, fn ->
      sql
      |> String.trim()
      |> String.trim_trailing(";")
      |> query_user_sql(conn, limit)
    end)
  end

  defp search_sheet(conn, sheet, terms, limit) do
    where = Enum.map_join(terms, " AND ", fn _ -> "LOWER(__text) LIKE ?" end)
    params = Enum.map(terms, &("%" <> &1 <> "%")) ++ [limit]

    sql = """
    SELECT * FROM #{quote_identifier(sheet.table_name)}
    WHERE #{where}
    LIMIT ?
    """

    with {:ok, result} <- query_with_columns(conn, sql, params) do
      {:ok,
       Enum.map(result.rows, fn row ->
         %{
           spreadsheet_id: sheet.spreadsheet_id,
           sheet_name: sheet.name,
           table_name: sheet.table_name,
           row_number: Map.fetch!(row, "__row_number"),
           score: length(terms),
           row: Map.drop(row, ["__text"])
         }
       end)}
    end
  end

  defp query_user_sql(sql, conn, limit) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with {:ok, columns} <- Sqlite3.columns(conn, statement),
             {:ok, rows} <- fetch_rows(conn, statement, limit) do
          {:ok,
           %{
             columns: columns,
             rows: Enum.map(rows, &row_map(columns, &1))
           }}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp query_with_columns(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)

        with {:ok, columns} <- Sqlite3.columns(conn, statement),
             {:ok, rows} <- Sqlite3.fetch_all(conn, statement) do
          {:ok,
           %{
             columns: columns,
             rows: Enum.map(rows, &row_map(columns, &1))
           }}
        end
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp fetch_rows(conn, statement, limit),
    do: fetch_rows(conn, statement, limit, [])

  defp fetch_rows(_conn, _statement, 0, rows), do: {:ok, Enum.reverse(rows)}

  defp fetch_rows(conn, statement, remaining, rows) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> fetch_rows(conn, statement, remaining - 1, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      :busy -> {:error, "Database busy"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_xlsx(path) do
    with {:ok, entries} <- :zip.extract(String.to_charlist(path), [:memory]) do
      files =
        Map.new(entries, fn {name, bytes} -> {List.to_string(name), bytes} end)

      with {:ok, workbook} <- parse_xml(Map.fetch!(files, "xl/workbook.xml")),
           {:ok, rels} <-
             parse_xml(Map.fetch!(files, "xl/_rels/workbook.xml.rels")) do
        shared_strings = shared_strings(files)
        relationships = workbook_relationships(rels)

        sheets =
          workbook
          |> elements("sheet")
          |> Enum.map(fn sheet ->
            name = attr(sheet, "name") || "Sheet"
            rid = attr(sheet, "id") || attr(sheet, "r:id")
            target = Map.fetch!(relationships, rid)
            path = sheet_path(target)
            rows = files |> Map.fetch!(path) |> parse_sheet(shared_strings)
            %{name: name, rows: rows}
          end)

        {:ok, %{sheets: sheets}}
      end
    end
  rescue
    error -> {:error, error}
  end

  defp shared_strings(files) do
    case Map.get(files, "xl/sharedStrings.xml") do
      nil ->
        []

      bytes ->
        {:ok, doc} = parse_xml(bytes)

        doc
        |> elements("si")
        |> Enum.map(&text_content/1)
    end
  end

  defp workbook_relationships(rels) do
    rels
    |> elements("Relationship")
    |> Map.new(fn rel -> {attr(rel, "Id"), attr(rel, "Target")} end)
  end

  defp sheet_path("/" <> target), do: String.trim_leading(target, "/")
  defp sheet_path("xl/" <> _ = target), do: target
  defp sheet_path(target), do: Path.join("xl", target)

  defp parse_sheet(bytes, shared_strings) do
    {:ok, doc} = parse_xml(bytes)

    doc
    |> elements("row")
    |> Enum.map(&row_from_element(&1, shared_strings))
  end

  defp row_from_element(row, shared_strings) do
    cells = elements(row, "c")

    values_by_index =
      Map.new(cells, fn cell ->
        {cell_index(attr(cell, "r")), cell_value(cell, shared_strings)}
      end)

    max_index = values_by_index |> Map.keys() |> Enum.max(fn -> 0 end)

    %{
      number: attr(row, "r") |> parse_integer(),
      values: Enum.map(1..max_index//1, &Map.get(values_by_index, &1))
    }
  end

  defp cell_value(cell, shared_strings) do
    type = attr(cell, "t")

    value =
      case type do
        "inlineStr" ->
          cell |> elements("is") |> Enum.map_join(&text_content/1)

        "s" ->
          shared_strings
          |> Enum.at(cell |> first_child_text("v") |> parse_integer())

        _ ->
          first_child_text(cell, "v") || first_child_text(cell, "t")
      end

    normalize_cell_value(value)
  end

  defp normalize_cell_value(nil), do: nil

  defp normalize_cell_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp parse_xml(bytes) when is_binary(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> :xmerl_scan.string(quiet: true)
    |> elem(0)
    |> then(&{:ok, &1})
  end

  defp elements(root, name) do
    root
    |> all_elements()
    |> Enum.filter(&(local_name(xmlElement(&1, :name)) == name))
  end

  defp all_elements(element) do
    children =
      element
      |> xmlElement(:content)
      |> Enum.filter(&xml_element?/1)

    [element | Enum.flat_map(children, &all_elements/1)]
  end

  defp xml_element?(value) when Record.is_record(value, :xmlElement), do: true
  defp xml_element?(_value), do: false

  defp attr(element, name) do
    element
    |> xmlElement(:attributes)
    |> Enum.find_value(fn attribute ->
      if local_name(xmlAttribute(attribute, :name)) == name do
        attribute |> xmlAttribute(:value) |> to_string()
      end
    end)
  end

  defp first_child_text(element, name) do
    element
    |> elements(name)
    |> List.first()
    |> case do
      nil -> nil
      child -> text_content(child)
    end
  end

  defp text_content(nil), do: ""

  defp text_content(value) when Record.is_record(value, :xmlText) do
    value |> xmlText(:value) |> to_string()
  end

  defp text_content(value) when Record.is_record(value, :xmlElement) do
    value
    |> xmlElement(:content)
    |> Enum.map_join(fn
      child when Record.is_record(child, :xmlText) -> text_content(child)
      child when Record.is_record(child, :xmlElement) -> text_content(child)
      _ -> ""
    end)
  end

  defp local_name(name) do
    name
    |> to_string()
    |> String.split(":")
    |> List.last()
  end

  defp cell_index(nil), do: 1

  defp cell_index(reference) do
    reference
    |> String.replace(~r/[^A-Za-z]/, "")
    |> String.upcase()
    |> String.to_charlist()
    |> Enum.reduce(0, fn char, acc -> acc * 26 + (char - ?A + 1) end)
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(""), do: nil

  defp parse_integer(value) do
    case Integer.parse(to_string(value)) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp empty_row?(%{values: values}), do: Enum.all?(values, &blank?/1)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp insert_spreadsheet(conn, attrs) do
    execute(
      conn,
      """
      INSERT INTO spreadsheets
        (id, title, path, basename, file_size, file_mtime, sha256, imported_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        attrs.id,
        attrs.title,
        attrs.path,
        attrs.basename,
        attrs.file_size,
        attrs.file_mtime,
        attrs.sha256,
        attrs.imported_at
      ]
    )
  end

  defp insert_sheet(conn, attrs) do
    execute(
      conn,
      """
      INSERT INTO spreadsheet_sheets
        (spreadsheet_id, sheet_index, name, table_name, row_count, col_count, headers_json, imported_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        attrs.spreadsheet_id,
        attrs.sheet_index,
        attrs.name,
        attrs.table_name,
        attrs.row_count,
        attrs.col_count,
        Jason.encode!(attrs.headers),
        attrs.imported_at
      ]
    )
  end

  defp drop_existing_sheet_tables(conn, spreadsheet_id) do
    with {:ok, rows} <-
           query_rows(
             conn,
             "SELECT table_name FROM spreadsheet_sheets WHERE spreadsheet_id = ?",
             [
               spreadsheet_id
             ]
           ) do
      rows
      |> Enum.reduce_while(:ok, fn [table_name], :ok ->
        case Sqlite3.execute(
               conn,
               "DROP TABLE IF EXISTS #{quote_identifier(table_name)}"
             ) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp delete_spreadsheet(conn, id) do
    execute(conn, "DELETE FROM spreadsheet_sheets WHERE spreadsheet_id = ?", [
      id
    ])
    |> case do
      :ok -> execute(conn, "DELETE FROM spreadsheets WHERE id = ?", [id])
      error -> error
    end
  end

  defp spreadsheet_from_row(row, sheets) do
    %{
      id: Enum.at(row, 0),
      title: Enum.at(row, 1),
      path: Enum.at(row, 2),
      basename: Enum.at(row, 3),
      file_size: Enum.at(row, 4),
      file_mtime: Enum.at(row, 5),
      sha256: Enum.at(row, 6),
      imported_at: Enum.at(row, 7),
      sheets: sheets
    }
  end

  defp sheet_from_row(row) do
    %{
      spreadsheet_id: Enum.at(row, 0),
      sheet_index: Enum.at(row, 1),
      name: Enum.at(row, 2),
      table_name: Enum.at(row, 3),
      row_count: Enum.at(row, 4),
      col_count: Enum.at(row, 5),
      columns: Jason.decode!(Enum.at(row, 6)),
      imported_at: Enum.at(row, 7)
    }
  end

  defp row_map(columns, row) do
    columns
    |> Enum.zip(row)
    |> Map.new()
  end

  defp search_terms(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> Enum.map(fn [term] -> term end)
    |> Enum.uniq()
  end

  defp clamp_limit(limit) when is_integer(limit), do: max(limit, 1)
  defp clamp_limit(_limit), do: 50

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

  defp readonly_transaction(conn, fun) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA query_only = ON"),
         :ok <- Sqlite3.execute(conn, "BEGIN") do
      try do
        fun.()
      after
        _ = Sqlite3.execute(conn, "ROLLBACK")
        _ = Sqlite3.execute(conn, "PRAGMA query_only = OFF")
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

  defp query_rows(conn, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        :ok = Sqlite3.bind(statement, params)
        Sqlite3.fetch_all(conn, statement)
      after
        Sqlite3.release(conn, statement)
      end
    end
  end

  defp quote_identifier(identifier) do
    ~s("#{String.replace(identifier, "\"", "\"\"")}")
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

  defp spreadsheets_sql do
    """
    CREATE TABLE IF NOT EXISTS spreadsheets (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      path TEXT NOT NULL,
      basename TEXT NOT NULL,
      file_size INTEGER NOT NULL,
      file_mtime TEXT,
      sha256 TEXT NOT NULL,
      imported_at TEXT NOT NULL
    )
    """
  end

  defp spreadsheet_sheets_sql do
    """
    CREATE TABLE IF NOT EXISTS spreadsheet_sheets (
      id INTEGER PRIMARY KEY,
      spreadsheet_id TEXT NOT NULL,
      sheet_index INTEGER NOT NULL,
      name TEXT NOT NULL,
      table_name TEXT NOT NULL UNIQUE,
      row_count INTEGER NOT NULL,
      col_count INTEGER NOT NULL,
      headers_json TEXT NOT NULL,
      imported_at TEXT NOT NULL,
      FOREIGN KEY (spreadsheet_id) REFERENCES spreadsheets(id) ON DELETE CASCADE
    )
    """
  end
end
