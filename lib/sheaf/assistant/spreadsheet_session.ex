defmodule Sheaf.Assistant.SpreadsheetSession do
  @moduledoc """
  Per-assistant-session DuckDB workspace for materialized spreadsheet sheets.

  Spreadsheet XLSX files are converted to Parquet during explicit import.
  Assistant sessions load those Parquet sheet distributions into an in-memory
  DuckDB database, then disable external filesystem access before accepting SQL.
  """

  use GenServer

  alias RDF.{Description, Graph}
  alias Sheaf.Assistant.QueryResults

  require OpenTelemetry.Tracer, as: Tracer

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
        case open_and_load(id, directory, opts) do
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
        case query_loaded(state, sql, limit, opts) do
          {:ok, result} = ok ->
            Tracer.set_attribute("db.response.returned_rows", length(result.rows))

            Tracer.set_attribute(
              "db.response.row_count",
              Map.get(result, :row_count, length(result.rows))
            )

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

  defp open_and_load(id, directory, opts) do
    with {:ok, db} <- Duckdbex.open() do
      case Duckdbex.connection(db) do
        {:ok, conn} -> load_into_connection(id, directory, db, conn, opts)
        {:error, reason} -> release_and_error(db, reason)
      end
    end
  end

  defp load_into_connection(id, directory, db, conn, opts) do
    with :ok <- ensure_extension(conn, "core_functions"),
         :ok <- ensure_extension(conn, "parquet"),
         :ok <- create_metadata_tables(conn) do
      loaded_at = now_iso8601()
      sources = spreadsheet_sources(directory, opts)

      {spreadsheets, errors} =
        Enum.reduce(sources, {[], []}, fn source, {spreadsheets, errors} ->
          case load_workbook(conn, directory, source, loaded_at) do
            {:ok, spreadsheet, sheet_errors} ->
              {[spreadsheet | spreadsheets], Enum.reverse(sheet_errors) ++ errors}

            {:error, reason} ->
              {spreadsheets, [%{path: source.path, error: reason} | errors]}
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

  defp load_workbook(conn, directory, source, loaded_at) do
    path = source.path || ""
    id = source.id
    basename = source.basename || Path.basename(path)
    title = source.title || relative_path(directory, path)
    sheets = Map.get(source, :sheets, [])

    transaction(conn, fn ->
      with :ok <-
             exec(
               conn,
               """
               INSERT INTO sheaf_spreadsheets
                 (id, title, path, basename, file_size, file_mtime, sha256, loaded_at)
               VALUES
                 (#{literal(id)}, #{literal(title)}, #{literal(Path.expand(path))},
                 #{literal(basename)}, #{source.file_size || "NULL"}, #{literal(source.file_mtime)},
                  #{literal(source.sha256 || "")}, #{literal(loaded_at)})
               """
             ),
           {:ok, sheets, sheet_errors} <-
             load_sheets(conn, id, sheets, loaded_at) do
        if sheets == [] do
          {:error, {:no_readable_sheets, sheet_errors}}
        else
          {:ok,
           {%{
              id: id,
              title: title,
              path: Path.expand(path),
              basename: basename,
              file_size: source.file_size,
              file_mtime: source.file_mtime,
              sha256: source.sha256,
              loaded_at: loaded_at,
              sheets: sheets,
              sheet_errors: sheet_errors
            }, sheet_errors}}
        end
      end
    end)
    |> case do
      {:ok, {spreadsheet, sheet_errors}} -> {:ok, spreadsheet, sheet_errors}
      error -> error
    end
  end

  defp load_sheets(conn, spreadsheet_id, sheet_sources, loaded_at) do
    sheet_sources
    |> Enum.reduce({[], []}, fn sheet, {sheets, errors} ->
      case load_sheet(conn, spreadsheet_id, sheet, loaded_at) do
        {:ok, sheet} ->
          {[sheet | sheets], errors}

        {:error, reason} ->
          {sheets,
           [
             %{
               path: sheet.parquet_path,
               sheet: sheet.name,
               sheet_index: sheet.sheet_index,
               error: reason
             }
             | errors
           ]}
      end
    end)
    |> then(fn {sheets, errors} -> {:ok, Enum.reverse(sheets), Enum.reverse(errors)} end)
  end

  defp load_sheet(conn, spreadsheet_id, sheet, loaded_at) do
    table = sheet.table_name

    with :ok <-
           exec(
             conn,
             """
               CREATE TABLE #{identifier(table)} AS
               SELECT *
               FROM read_parquet(#{literal(sheet.parquet_path)})
             """
           ),
         {:ok, columns} <- table_columns(conn, table),
         {:ok, row_count} <- scalar(conn, "SELECT count(*) FROM #{identifier(table)}"),
         :ok <-
           exec(
             conn,
             """
             INSERT INTO sheaf_spreadsheet_sheets
               (spreadsheet_id, sheet_index, name, table_name, row_count, col_count, headers_json, loaded_at)
             VALUES
               (#{literal(spreadsheet_id)}, #{sheet.sheet_index}, #{literal(sheet.name)},
                #{literal(table)}, #{row_count}, #{length(columns)},
                #{literal(Jason.encode!(columns))}, #{literal(loaded_at)})
             """
           ) do
      {:ok,
       %{
         spreadsheet_id: spreadsheet_id,
         sheet_index: sheet.sheet_index,
         name: sheet.name,
         table_name: table,
         row_count: row_count,
         col_count: length(columns),
         columns: columns,
         loaded_at: loaded_at
       }}
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

  defp lock_external_access(conn) do
    with :ok <- exec(conn, "SET enable_external_access = false") do
      exec(conn, "SET lock_configuration = true")
    end
  end

  defp query_loaded(state, sql, limit, opts) do
    sql = String.trim(sql)

    with {:ok, result} <- Duckdbex.query(state.conn, sql) do
      try do
        columns = Duckdbex.columns(result)
        rows = result |> fetch_all_rows() |> Enum.map(&row_map(columns, &1))
        preview_rows = Enum.take(rows, limit)

        saved = maybe_save_query_result(sql, columns, rows, state, opts)

        {:ok,
         %{
           columns: columns,
           rows: preview_rows,
           row_count: length(rows),
           result_id: saved && saved.id,
           result_iri: saved && saved.iri,
           result_file_iri: saved && saved.file_iri
         }}
      after
        Duckdbex.release(result)
      end
    end
  end

  defp maybe_save_query_result(_sql, [], _rows, _state, _opts), do: nil

  defp maybe_save_query_result(sql, columns, rows, state, opts) do
    if persist_query_result?(opts) do
      save_query_result(sql, columns, rows, state, opts)
    end
  end

  defp persist_query_result?(opts) do
    Keyword.get(
      opts,
      :persist_result?,
      Keyword.has_key?(opts, :query_result_context) or Keyword.has_key?(opts, :query_result_opts)
    )
  end

  defp save_query_result(sql, columns, rows, state, opts) do
    context = Keyword.get(opts, :query_result_context, [])

    query_result_opts =
      [session_id: state.id]
      |> Keyword.merge(if(is_list(context), do: context, else: []))
      |> Keyword.merge(Keyword.get(opts, :query_result_opts, []))

    case QueryResults.create(%{sql: sql, columns: columns, rows: rows}, query_result_opts) do
      {:ok, result} -> result
      {:error, _reason} -> nil
    end
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

  defp fetch_all_rows(result), do: fetch_all_rows(result, [])

  defp fetch_all_rows(result, rows) do
    case Duckdbex.fetch_chunk(result) do
      [] -> Enum.reverse(rows)
      chunk -> fetch_all_rows(result, Enum.reverse(chunk) ++ rows)
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

  defp spreadsheet_sources(directory, opts) do
    workspace_sources(directory, opts)
  end

  defp workspace_sources(_directory, opts) do
    cond do
      Keyword.get(opts, :workspace_sources?, true) == false ->
        []

      Keyword.has_key?(opts, :workspace_graph) ->
        workspace_sources_from_graph(opts)

      is_nil(Process.whereis(Sheaf.Repo)) ->
        []

      true ->
        workspace_sources_from_graph(opts)
    end
  end

  defp workspace_sources_from_graph(opts) do
    with {:ok, graph} <- workspace_graph(opts) do
      graph
      |> RDF.Data.descriptions()
      |> Enum.filter(&Description.include?(&1, {RDF.type(), Sheaf.NS.DOC.SpreadsheetWorkbook}))
      |> Enum.flat_map(&source_from_workbook(graph, &1, opts))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.title)
    else
      _ -> []
    end
  end

  defp workspace_graph(opts) do
    case Keyword.fetch(opts, :workspace_graph) do
      {:ok, graph} ->
        {:ok, graph}

      :error ->
        graph_name = RDF.iri(Sheaf.Workspace.graph())

        with :ok <- Sheaf.Repo.load_once({nil, nil, nil, graph_name}) do
          graph =
            Sheaf.Repo.ask(fn dataset ->
              RDF.Dataset.graph(dataset, graph_name) || Graph.new(name: graph_name)
            end)

          {:ok, graph}
        end
    end
  end

  defp source_from_workbook(graph, %Description{} = workbook, opts) do
    file_iri =
      first_term(workbook, Sheaf.NS.DOC.sourceFile()) ||
        first_term(workbook, Sheaf.NS.DCAT.distribution())

    with %RDF.IRI{} <- file_iri,
         %Description{} = file <- Graph.description(graph, file_iri),
         {:ok, path} <- Sheaf.Files.local_path(file, opts),
         sheets = sheet_sources(graph, workbook, opts),
         true <- sheets != [] do
      [
        %{
          id: Sheaf.Id.id_from_iri(workbook.subject),
          path: Path.expand(path),
          file_size: first_value(file, Sheaf.NS.DCAT.byteSize()),
          file_mtime: nil,
          sha256: first_value(file, Sheaf.NS.DOC.sha256()),
          title:
            first_value(workbook, Sheaf.NS.DCTERMS.title()) ||
              first_value(workbook, RDF.NS.RDFS.label()) ||
              first_value(file, Sheaf.NS.DOC.originalFilename()) ||
              Path.basename(path),
          basename: first_value(file, Sheaf.NS.DOC.originalFilename()) || Path.basename(path),
          sheets: sheets
        }
      ]
    else
      _ -> []
    end
  end

  defp sheet_sources(graph, %Description{} = workbook, opts) do
    workbook
    |> Description.get(Sheaf.NS.CSVW.table(), [])
    |> Enum.map(&Graph.description(graph, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&sheet_source(graph, &1, opts))
    |> Enum.sort_by(& &1.sheet_index)
  end

  defp sheet_source(graph, %Description{} = sheet, opts) do
    with %RDF.IRI{} = parquet_iri <-
           first_term(sheet, Sheaf.NS.DOC.materializedDistribution()),
         %Description{} = parquet <- Graph.description(graph, parquet_iri),
         {:ok, parquet_path} <- Sheaf.Files.local_path(parquet, opts),
         true <- File.regular?(parquet_path) do
      [
        %{
          sheet_index: first_value(sheet, Sheaf.NS.DOC.sheetIndex()),
          name:
            first_value(sheet, Sheaf.NS.CSVW.name()) ||
              first_value(sheet, RDF.NS.RDFS.label()),
          table_name: first_value(sheet, Sheaf.NS.DOC.duckdbTableName()),
          row_count: first_value(sheet, Sheaf.NS.DOC.rowCount()),
          columns: columns_for_sheet(graph, sheet),
          parquet_path: parquet_path
        }
      ]
    else
      _ -> []
    end
  end

  defp columns_for_sheet(graph, %Description{} = sheet) do
    sheet
    |> first_term(Sheaf.NS.CSVW.tableSchema())
    |> then(&if &1, do: Graph.description(graph, &1), else: nil)
    |> case do
      nil ->
        []

      schema ->
        schema
        |> Description.get(Sheaf.NS.CSVW.column(), [])
        |> Enum.map(&Graph.description(graph, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn column ->
          %{
            name: first_value(column, Sheaf.NS.CSVW.name()),
            header:
              first_value(column, Sheaf.NS.CSVW.title()) ||
                first_value(column, Sheaf.NS.CSVW.name()),
            index: first_value(column, Sheaf.NS.DOC.columnIndex())
          }
        end)
        |> Enum.sort_by(&(&1.index || 0))
    end
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

  defp first_term(%Description{} = description, property) do
    Description.first(description, property)
  end

  defp first_value(%Description{} = description, property) do
    description
    |> first_term(property)
    |> case do
      nil -> nil
      term -> RDF.Term.value(term)
    end
  end

  defp configured_directory do
    :sheaf
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:directory, @default_directory)
  end
end
