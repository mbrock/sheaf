defmodule Sheaf.Assistant.SpreadsheetSession do
  @moduledoc """
  Per-assistant-session DuckDB workspace for spreadsheet files.

  A session loads `.xlsx` files from a configured directory into an in-memory
  DuckDB database, then disables external filesystem access before accepting
  assistant SQL. The loaded workbook tables are disposable process-local state:
  assistant-created tables and views survive within one chat session, but they
  disappear when the session process stops or restarts.
  """

  use GenServer

  require OpenTelemetry.Tracer, as: Tracer
  require Record

  Record.defrecord(
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecord(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @registry Sheaf.Assistant.ChatRegistry
  @default_directory "var/spreadsheets"
  @max_query_rows 200

  defstruct [
    :id,
    :directory,
    :db,
    :conn,
    :loaded_at,
    error: nil,
    spreadsheets: [],
    errors: []
  ]

  @type server :: GenServer.server()

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(id), do: {:via, Registry, {@registry, {:spreadsheet_session, id}}}

  def list(server) do
    GenServer.call(server, :list)
  end

  def available?(server) do
    case list(server) do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  catch
    :exit, _reason -> false
  end

  def query(server, sql, opts \\ []) when is_binary(sql) do
    GenServer.call(server, {:query, sql, opts}, Keyword.get(opts, :timeout, 60_000))
  end

  def search(server, text, opts \\ []) when is_binary(text) do
    GenServer.call(server, {:search, text, opts}, Keyword.get(opts, :timeout, 60_000))
  end

  @impl true
  def init(opts) do
    directory = Keyword.get_lazy(opts, :directory, &configured_directory/0)
    id = Keyword.fetch!(opts, :id)

    state =
      Tracer.with_span "Sheaf.Assistant.SpreadsheetSession.init", %{
        kind: :internal,
        attributes: [
          {"sheaf.assistant.session_id", id},
          {"sheaf.spreadsheet.directory", Path.expand(directory)}
        ]
      } do
        case open_and_load(id, directory) do
          {:ok, state} ->
            Tracer.set_attribute("sheaf.spreadsheet.count", length(state.spreadsheets))
            Tracer.set_attribute("sheaf.spreadsheet.load_error_count", length(state.errors))
            state

          {:error, reason} ->
            Tracer.set_attribute("sheaf.spreadsheet.load_error", inspect(reason))
            %__MODULE__{id: id, directory: directory, error: reason}
        end
      end

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.conn), do: Duckdbex.release(state.conn)
    if is_reference(state.db), do: Duckdbex.release(state.db)
    :ok
  end

  @impl true
  def handle_call(:list, _from, %{error: nil} = state) do
    {:reply, {:ok, state.spreadsheets}, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, {:error, state.error}, state}
  end

  def handle_call({:query, _sql, _opts}, _from, %{error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:query, sql, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()

    result =
      Tracer.with_span "Sheaf.Assistant.SpreadsheetSession.query", %{
        kind: :internal,
        attributes: [
          {"db.system", "duckdb"},
          {"sheaf.assistant.session_id", state.id},
          {"db.statement", sql},
          {"sheaf.query.limit", limit}
        ]
      } do
        case query_loaded(state.conn, sql, limit) do
          {:ok, result} = ok ->
            Tracer.set_attribute("db.response.returned_rows", length(result.rows))
            ok

          {:error, reason} = error ->
            Tracer.set_attribute("sheaf.query.error", inspect(reason))
            error
        end
      end

    {:reply, result, state}
  end

  def handle_call({:search, _text, _opts}, _from, %{error: reason} = state)
      when not is_nil(reason) do
    {:reply, {:error, reason}, state}
  end

  def handle_call({:search, text, opts}, _from, state) do
    limit = opts |> Keyword.get(:limit, 20) |> clamp_limit()

    result =
      Tracer.with_span "Sheaf.Assistant.SpreadsheetSession.search", %{
        kind: :internal,
        attributes: [
          {"db.system", "duckdb"},
          {"sheaf.assistant.session_id", state.id},
          {"sheaf.search.query", text},
          {"sheaf.query.limit", limit}
        ]
      } do
        search_loaded(state, text, limit)
      end

    {:reply, result, state}
  end

  defp open_and_load(id, directory) do
    with {:ok, db} <- Duckdbex.open() do
      case Duckdbex.connection(db) do
        {:ok, conn} -> load_into_connection(id, directory, db, conn)
        {:error, reason} -> release_and_error(db, reason)
      end
    end
  end

  defp load_into_connection(id, directory, db, conn) do
    with :ok <- ensure_extension(conn, "core_functions"),
         :ok <- ensure_extension(conn, "excel"),
         :ok <- create_metadata_tables(conn) do
      loaded_at = now_iso8601()
      files = spreadsheet_files(directory)

      {spreadsheets, errors} =
        Enum.reduce(files, {[], []}, fn path, {spreadsheets, errors} ->
          case load_workbook(conn, directory, path, loaded_at) do
            {:ok, spreadsheet} -> {[spreadsheet | spreadsheets], errors}
            {:error, reason} -> {spreadsheets, [%{path: path, error: reason} | errors]}
          end
        end)

      with :ok <- lock_external_access(conn) do
        {:ok,
         %__MODULE__{
           id: id,
           directory: directory,
           db: db,
           conn: conn,
           loaded_at: loaded_at,
           spreadsheets: Enum.reverse(spreadsheets),
           errors: Enum.reverse(errors)
         }}
      else
        {:error, reason} ->
          Duckdbex.release(conn)
          Duckdbex.release(db)
          {:error, reason}
      end
    else
      {:error, reason} ->
        Duckdbex.release(conn)
        Duckdbex.release(db)
        {:error, reason}
    end
  end

  defp release_and_error(db, reason) do
    Duckdbex.release(db)
    {:error, reason}
  end

  defp ensure_extension(conn, name) do
    case exec(conn, "LOAD #{name}") do
      :ok ->
        :ok

      {:error, _load_reason} ->
        with :ok <- exec(conn, "INSTALL #{name}") do
          exec(conn, "LOAD #{name}")
        end
    end
  end

  defp create_metadata_tables(conn) do
    with :ok <-
           exec(
             conn,
             """
             CREATE TABLE sheaf_spreadsheets (
               id VARCHAR PRIMARY KEY,
               title VARCHAR NOT NULL,
               path VARCHAR NOT NULL,
               basename VARCHAR NOT NULL,
               file_size UBIGINT,
               file_mtime VARCHAR,
               sha256 VARCHAR NOT NULL,
               loaded_at VARCHAR NOT NULL
             )
             """
           ) do
      exec(
        conn,
        """
        CREATE TABLE sheaf_spreadsheet_sheets (
          spreadsheet_id VARCHAR NOT NULL,
          sheet_index INTEGER NOT NULL,
          name VARCHAR NOT NULL,
          table_name VARCHAR NOT NULL,
          row_count UBIGINT NOT NULL,
          col_count UBIGINT NOT NULL,
          headers_json VARCHAR NOT NULL,
          loaded_at VARCHAR NOT NULL
        )
        """
      )
    end
  end

  defp load_workbook(conn, directory, path, loaded_at) do
    stat = File.stat!(path)
    bytes = File.read!(path)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    file_key =
      :crypto.hash(:sha256, Path.expand(path) <> "\0" <> sha) |> Base.encode16(case: :lower)

    id = "xl_" <> String.slice(file_key, 0, 12)
    basename = Path.basename(path)
    title = relative_path(directory, path)
    sheet_names = xlsx_sheet_names(path)

    transaction(conn, fn ->
      with :ok <-
             exec(
               conn,
               """
               INSERT INTO sheaf_spreadsheets
                 (id, title, path, basename, file_size, file_mtime, sha256, loaded_at)
               VALUES
                 (#{literal(id)}, #{literal(title)}, #{literal(Path.expand(path))},
                  #{literal(basename)}, #{stat.size}, #{literal(mtime(stat))},
                  #{literal(sha)}, #{literal(loaded_at)})
               """
             ),
           {:ok, sheets} <- load_sheets(conn, path, id, file_key, sheet_names, loaded_at) do
        {:ok,
         %{
           id: id,
           title: title,
           path: Path.expand(path),
           basename: basename,
           file_size: stat.size,
           file_mtime: mtime(stat),
           sha256: sha,
           loaded_at: loaded_at,
           sheets: sheets
         }}
      end
    end)
  end

  defp load_sheets(conn, path, spreadsheet_id, sha, sheet_names, loaded_at) do
    sheet_names
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {sheet_name, index}, {:ok, sheets} ->
      table = table_name(path, sha, index)

      case load_sheet(conn, path, spreadsheet_id, table, sheet_name, index, loaded_at) do
        {:ok, sheet} -> {:cont, {:ok, [sheet | sheets]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, sheets} -> {:ok, Enum.reverse(sheets)}
      error -> error
    end
  end

  defp load_sheet(conn, path, spreadsheet_id, table, sheet_name, index, loaded_at) do
    source = """
    read_xlsx(
      #{literal(path)},
      sheet = #{literal(sheet_name)},
      all_varchar = true,
      normalize_names = true,
      header = true,
      ignore_errors = true
    )
    """

    with :ok <-
           exec(
             conn,
             """
               CREATE TABLE #{identifier(table)} AS
               SELECT row_number() OVER () AS __row_number, *
               FROM #{source}
             """
           ),
         :ok <- normalize_reserved_columns(conn, table),
         {:ok, columns} <- table_columns(conn, table),
         :ok <- add_text_column(conn, table, columns),
         {:ok, row_count} <- scalar(conn, "SELECT count(*) FROM #{identifier(table)}"),
         :ok <-
           exec(
             conn,
             """
             INSERT INTO sheaf_spreadsheet_sheets
               (spreadsheet_id, sheet_index, name, table_name, row_count, col_count, headers_json, loaded_at)
             VALUES
               (#{literal(spreadsheet_id)}, #{index}, #{literal(sheet_name)},
                #{literal(table)}, #{row_count}, #{length(columns)},
                #{literal(Jason.encode!(columns))}, #{literal(loaded_at)})
             """
           ) do
      {:ok,
       %{
         spreadsheet_id: spreadsheet_id,
         sheet_index: index,
         name: sheet_name,
         table_name: table,
         row_count: row_count,
         col_count: length(columns),
         columns: columns,
         loaded_at: loaded_at
       }}
    end
  end

  defp normalize_reserved_columns(conn, table) do
    with {:ok, names} <- table_column_names(conn, table) do
      if "__text" in names do
        exec(
          conn,
          "ALTER TABLE #{identifier(table)} RENAME COLUMN #{identifier("__text")} TO #{identifier(unique_name("__text_source", names))}"
        )
      else
        :ok
      end
    end
  end

  defp table_columns(conn, table) do
    with {:ok, names} <- table_column_names(conn, table) do
      columns =
        names
        |> Enum.reject(&(&1 in ["__row_number", "__text"]))
        |> Enum.map(&%{name: &1, header: &1})

      {:ok, columns}
    end
  end

  defp table_column_names(conn, table) do
    with {:ok, result} <-
           query_all(conn, "PRAGMA table_info(#{identifier(table)})", @max_query_rows) do
      {:ok, Enum.map(result.rows, &Map.fetch!(&1, "name"))}
    end
  end

  defp add_text_column(conn, table, columns) do
    expressions =
      columns
      |> Enum.map(fn %{name: name} -> "coalesce(CAST(#{identifier(name)} AS VARCHAR), '')" end)
      |> case do
        [] -> literal("")
        expressions -> Enum.join(expressions, ", ")
      end

    with :ok <- exec(conn, "ALTER TABLE #{identifier(table)} ADD COLUMN __text VARCHAR") do
      exec(
        conn,
        "UPDATE #{identifier(table)} SET __text = concat_ws(#{literal(" | ")}, #{expressions})"
      )
    end
  end

  defp lock_external_access(conn) do
    with :ok <- exec(conn, "SET enable_external_access = false") do
      exec(conn, "SET lock_configuration = true")
    end
  end

  defp query_loaded(conn, sql, limit) do
    query_all(conn, String.trim(sql), limit)
  end

  defp query_all(conn, sql, limit) do
    with {:ok, result} <- Duckdbex.query(conn, sql) do
      try do
        columns = Duckdbex.columns(result)
        rows = result |> fetch_limited(limit) |> Enum.map(&row_map(columns, &1))
        {:ok, %{columns: columns, rows: rows}}
      after
        Duckdbex.release(result)
      end
    end
  end

  defp query_all(conn, sql, args, limit) do
    with {:ok, result} <- Duckdbex.query(conn, sql, args) do
      try do
        columns = Duckdbex.columns(result)
        rows = result |> fetch_limited(limit) |> Enum.map(&row_map(columns, &1))
        {:ok, %{columns: columns, rows: rows}}
      after
        Duckdbex.release(result)
      end
    end
  end

  defp search_loaded(_state, query, _limit) when query in ["", nil], do: {:ok, []}

  defp search_loaded(state, query, limit) do
    terms = search_terms(query)

    if terms == [] do
      {:ok, []}
    else
      state.spreadsheets
      |> Enum.flat_map(& &1.sheets)
      |> Enum.reduce_while({:ok, []}, fn sheet, {:ok, hits} ->
        case search_sheet(state.conn, sheet, terms, limit) do
          {:ok, sheet_hits} -> {:cont, {:ok, hits ++ sheet_hits}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, hits} ->
          {:ok,
           hits
           |> Enum.sort_by(&{-&1.score, &1.spreadsheet_id, &1.sheet_name, &1.row_number})
           |> Enum.take(limit)}

        error ->
          error
      end
    end
  end

  defp search_sheet(conn, sheet, terms, limit) do
    where = Enum.map_join(terms, " AND ", fn _ -> "lower(__text) LIKE ?" end)
    params = Enum.map(terms, &("%" <> &1 <> "%"))

    sql = """
    SELECT *
    FROM #{identifier(sheet.table_name)}
    WHERE #{where}
    LIMIT #{limit}
    """

    with {:ok, result} <- query_all(conn, sql, params, limit) do
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

  defp fetch_limited(result, limit), do: fetch_limited(result, limit, [])

  defp fetch_limited(_result, remaining, rows) when remaining <= 0 do
    rows |> Enum.reverse() |> Enum.take(@max_query_rows)
  end

  defp fetch_limited(result, remaining, rows) do
    case Duckdbex.fetch_chunk(result) do
      [] ->
        Enum.reverse(rows)

      chunk ->
        {taken, _rest} = Enum.split(chunk, remaining)
        fetch_limited(result, remaining - length(taken), Enum.reverse(taken) ++ rows)
    end
  end

  defp exec(conn, sql) do
    with {:ok, result} <- Duckdbex.query(conn, sql) do
      Duckdbex.release(result)
      :ok
    end
  end

  defp transaction(conn, fun) do
    with :ok <- exec(conn, "BEGIN TRANSACTION") do
      case fun.() do
        {:ok, _value} = ok ->
          case exec(conn, "COMMIT") do
            :ok -> ok
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          _ = exec(conn, "ROLLBACK")
          {:error, reason}
      end
    end
  end

  defp scalar(conn, sql) do
    case query_all(conn, sql, 1) do
      {:ok, %{rows: [%{"" => value}]}} -> {:ok, value}
      {:ok, %{rows: [row]}} -> {:ok, row |> Map.values() |> List.first()}
      {:ok, %{rows: []}} -> {:error, :no_rows}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

  defp spreadsheet_files(directory) do
    directory = Path.expand(directory)

    if File.dir?(directory) do
      directory
      |> File.ls!()
      |> Enum.map(&Path.join(directory, &1))
      |> Enum.flat_map(fn path ->
        cond do
          File.dir?(path) -> spreadsheet_files(path)
          xlsx?(path) -> [path]
          true -> []
        end
      end)
      |> Enum.sort()
    else
      []
    end
  end

  defp xlsx?(path), do: path |> Path.extname() |> String.downcase() == ".xlsx"

  defp xlsx_sheet_names(path) do
    with {:ok, entries} <- :zip.extract(String.to_charlist(path), [:memory]),
         {_, bytes} <-
           Enum.find(entries, fn {name, _bytes} -> List.to_string(name) == "xl/workbook.xml" end),
         {:ok, doc} <- parse_xml(bytes) do
      doc
      |> elements("sheet")
      |> Enum.map(&(attr(&1, "name") || "Sheet"))
      |> case do
        [] -> ["Sheet1"]
        names -> names
      end
    else
      _ -> ["Sheet1"]
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

  defp local_name(name) do
    name
    |> to_string()
    |> String.split(":")
    |> List.last()
  end

  defp table_name(path, sha, index) do
    slug =
      path
      |> Path.basename()
      |> Path.rootname()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "_")
      |> String.trim("_")
      |> case do
        "" -> "workbook"
        value -> String.slice(value, 0, 32)
      end

    "xlsx_#{slug}_#{String.slice(sha, 0, 8)}_#{index}"
  end

  defp unique_name(base, existing) do
    existing = MapSet.new(existing)

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 ->
        if MapSet.member?(existing, base), do: nil, else: base

      index ->
        name = "#{base}_#{index}"
        if MapSet.member?(existing, name), do: nil, else: name
    end)
  end

  defp relative_path(directory, path) do
    directory = directory |> Path.expand() |> Path.split()
    path = path |> Path.expand() |> Path.split()

    case Enum.split(path, length(directory)) do
      {^directory, rest} -> Path.join(rest)
      _ -> Path.basename(path)
    end
  end

  defp literal(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp literal(nil), do: "NULL"
  defp literal(value), do: value |> to_string() |> literal()

  defp identifier(identifier) do
    ~s("#{String.replace(to_string(identifier), "\"", "\"\"")}")
  end

  defp mtime(stat) do
    stat.mtime
    |> NaiveDateTime.from_erl!()
    |> NaiveDateTime.to_iso8601()
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp search_terms(query) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(query))
    |> Enum.map(fn [term] -> term end)
    |> Enum.uniq()
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_query_rows)
  defp clamp_limit(_limit), do: 50

  defp configured_directory do
    :sheaf
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:directory, @default_directory)
  end
end
