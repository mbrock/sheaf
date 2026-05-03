defmodule Sheaf.Assistant.QueryResults do
  @moduledoc """
  Durable Parquet artifacts for assistant spreadsheet query results.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.Files
  require RDF.Graph

  @mime_type "application/vnd.apache.parquet"
  @read_limit 200

  def create(attrs, opts \\ []) when is_map(attrs) do
    try do
      do_create(attrs, opts)
    catch
      :exit, reason -> {:error, {:exit, reason}}
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp do_create(attrs, opts) do
    columns = Map.fetch!(attrs, :columns)
    rows = Map.fetch!(attrs, :rows)
    sql = Map.fetch!(attrs, :sql)
    row_count = length(rows)
    result_iri = Keyword.get_lazy(opts, :result_iri, &Sheaf.mint/0)
    file_iri = Keyword.get_lazy(opts, :file_iri, &Sheaf.mint/0)
    tool_call_iri = Keyword.get_lazy(opts, :tool_call_iri, &Sheaf.mint/0)
    generated_at = Keyword.get_lazy(opts, :generated_at, &now/0)
    filename = filename(result_iri)

    with {:ok, parquet_path} <- write_parquet(columns, rows, filename),
         {:ok, stored_file_iri} <-
           Files.create(
             parquet_path,
             files_create_opts(opts,
               filename: filename,
               file_iri: file_iri,
               mime_type: @mime_type,
               generated_at: generated_at
             )
           ),
         :ok <-
           put_result_graph(
             result_iri,
             result_graph(
               result_iri,
               stored_file_iri,
               tool_call_iri,
               sql,
               columns,
               row_count,
               generated_at,
               opts
             ),
             opts
           ) do
      File.rm(parquet_path)

      {:ok,
       %{
         id: Sheaf.Id.id_from_iri(result_iri),
         iri: to_string(result_iri),
         file_iri: to_string(stored_file_iri),
         row_count: row_count,
         columns: columns,
         mime_type: @mime_type
       }}
    else
      {:error, _reason} = error ->
        error

      other ->
        {:error, {:unexpected_query_result_create_result, other}}
    end
  end

  def read(id_or_iri, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 50) |> clamp_limit()
    offset = opts |> Keyword.get(:offset, 0) |> clamp_offset()

    with {:ok, result_iri} <- normalize_iri(id_or_iri),
         {:ok, metadata} <- metadata(result_iri, opts),
         {:ok, rows} <- read_rows(metadata.path, metadata.columns, offset, limit) do
      {:ok,
       metadata
       |> Map.take([:id, :iri, :file_iri, :sql, :columns, :row_count])
       |> Map.merge(%{
         offset: offset,
         limit: limit,
         rows: rows
       })}
    end
  end

  def metadata(id_or_iri, opts \\ []) do
    with {:ok, result_iri} <- normalize_iri(id_or_iri),
         {:ok, result_graph} <- fetch_graph(result_iri, opts),
         %Description{} = result <- Graph.description(result_graph, result_iri),
         file_iri = first_term(result, Sheaf.NS.DOC.resultFile()),
         true <- match?(%RDF.IRI{}, file_iri) || {:error, :missing_result_file},
         {:ok, file_graph} <- fetch_graph(file_iri, opts),
         %Description{} = file <- Graph.description(file_graph, file_iri),
         {:ok, path} <- Files.local_path(file, opts) do
      {:ok,
       %{
         id: Sheaf.Id.id_from_iri(result_iri),
         iri: to_string(result_iri),
         file_iri: to_string(file_iri),
         path: path,
         sql: first_value(result, Sheaf.NS.DOC.sourceQuery()),
         columns: decode_columns(first_value(result, Sheaf.NS.DOC.columnNameList())),
         row_count: first_value(result, Sheaf.NS.DOC.rowCount()) || 0
       }}
    else
      nil -> {:error, :not_found}
      false -> {:error, :missing_result_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_parquet(columns, rows, filename) do
    path = Path.join(temp_dir(), filename)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, db} <- Duckdbex.open() do
      try do
        with {:ok, conn} <- Duckdbex.connection(db) do
          try do
            with :ok <- ensure_extension(conn, "parquet"),
                 :ok <- create_result_table(conn, columns),
                 :ok <- append_rows(conn, columns, rows),
                 :ok <- exec(conn, "COPY query_result TO #{literal(path)} (FORMAT parquet)") do
              {:ok, path}
            end
          after
            Duckdbex.release(conn)
          end
        end
      after
        Duckdbex.release(db)
      end
    end
  end

  defp create_result_table(conn, columns) do
    column_sql =
      columns
      |> Enum.map_join(", ", fn column -> "#{identifier(column)} VARCHAR" end)
      |> case do
        "" -> "__empty VARCHAR"
        sql -> sql
      end

    exec(conn, "CREATE TABLE query_result (#{column_sql})")
  end

  defp append_rows(_conn, _columns, []), do: :ok

  defp append_rows(conn, columns, rows) do
    with {:ok, appender} <- Duckdbex.appender(conn, "query_result") do
      try do
        rows
        |> Enum.reduce_while(:ok, fn row, :ok ->
          values = Enum.map(columns, &cell(Map.get(row, &1)))

          case Duckdbex.appender_add_row(appender, values) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          :ok -> Duckdbex.appender_flush(appender)
          error -> error
        end
      after
        Duckdbex.appender_close(appender)
      end
    end
  end

  defp read_rows(path, columns, offset, limit) do
    with {:ok, db} <- Duckdbex.open() do
      try do
        with {:ok, conn} <- Duckdbex.connection(db) do
          try do
            sql = "SELECT * FROM read_parquet(#{literal(path)}) LIMIT #{limit} OFFSET #{offset}"

            with :ok <- ensure_extension(conn, "parquet"),
                 {:ok, result} <- Duckdbex.query(conn, sql) do
              try do
                query_columns = Duckdbex.columns(result)

                rows =
                  result
                  |> fetch_limited(limit)
                  |> Enum.map(&row_map(query_columns, &1))

                {:ok, align_columns(rows, columns)}
              after
                Duckdbex.release(result)
              end
            end
          after
            Duckdbex.release(conn)
          end
        end
      after
        Duckdbex.release(db)
      end
    end
  end

  defp result_graph(
         result_iri,
         file_iri,
         tool_call_iri,
         sql,
         columns,
         row_count,
         generated_at,
         opts
       ) do
    session_iri = optional_iri(opts, :session_iri)
    agent_iri = optional_iri(opts, :agent_iri)

    RDF.Graph.build result: result_iri,
                    file: file_iri,
                    tool_call: tool_call_iri,
                    sql: sql,
                    columns: Jason.encode!(columns),
                    row_count: row_count,
                    generated_at: generated_at,
                    session: session_iri,
                    agent: agent_iri do
      @prefix Sheaf.NS.AS
      @prefix Sheaf.NS.DOC
      @prefix Sheaf.NS.PROV
      @prefix RDF.NS.RDFS

      result
      |> a(DOC.QueryResult)
      |> a(PROV.Entity)
      |> RDFS.label("Spreadsheet query result")
      |> DOC.sourceQuery(sql)
      |> DOC.columnNameList(columns)
      |> DOC.rowCount(row_count)
      |> DOC.resultFile(file)
      |> PROV.wasGeneratedBy(tool_call)
      |> PROV.generatedAtTime(generated_at)
      |> AS.context(session)

      tool_call
      |> a(DOC.ToolCall)
      |> a(PROV.Activity)
      |> RDFS.label("Spreadsheet query")
      |> DOC.toolName("query_spreadsheets")
      |> AS.context(session)
      |> AS.attributedTo(agent)
      |> PROV.generated(result)
    end
  end

  defp put_result_graph(result_iri, %Graph{} = graph, opts) do
    put_graph = Keyword.get(opts, :put_graph, &Sheaf.put_graph/2)
    put_graph.(result_iri, graph)
  end

  defp fetch_graph(iri, opts) do
    fetch_graph = Keyword.get(opts, :fetch_graph, &Sheaf.fetch_graph/1)
    fetch_graph.(iri)
  end

  defp files_create_opts(opts, defaults) do
    opts
    |> Keyword.take([:blob_root, :put_graph])
    |> Keyword.merge(defaults)
  end

  defp fetch_limited(result, limit), do: fetch_limited(result, limit, [])

  defp fetch_limited(_result, remaining, rows) when remaining <= 0, do: Enum.reverse(rows)

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

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()

  defp align_columns(rows, columns) do
    Enum.map(rows, fn row -> Map.take(row, columns) end)
  end

  defp cell(nil), do: nil
  defp cell(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp cell(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp cell(%Date{} = value), do: Date.to_iso8601(value)
  defp cell(%Time{} = value), do: Time.to_iso8601(value)
  defp cell(value) when is_binary(value), do: value
  defp cell(value) when is_boolean(value), do: to_string(value)
  defp cell(value) when is_integer(value), do: Integer.to_string(value)
  defp cell(value) when is_float(value), do: Float.to_string(value)
  defp cell(value), do: inspect(value)

  defp normalize_iri(%RDF.IRI{} = iri), do: {:ok, iri}

  defp normalize_iri(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :invalid_query_result_id}
      String.starts_with?(value, ["http://", "https://"]) -> {:ok, RDF.iri(value)}
      true -> {:ok, Sheaf.Id.iri(value)}
    end
  end

  defp normalize_iri(_value), do: {:error, :invalid_query_result_id}

  defp optional_iri(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      %RDF.IRI{} = iri -> iri
      value when is_binary(value) -> normalize_iri(value) |> elem(1)
      _other -> nil
    end
  end

  defp first_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> term_value()
  end

  defp first_term(%Description{} = description, property),
    do: Description.first(description, property)

  defp term_value(nil), do: nil
  defp term_value(term), do: RDF.Term.value(term)

  defp decode_columns(nil), do: []

  defp decode_columns(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, columns} when is_list(columns) -> columns
      _ -> []
    end
  end

  defp decode_columns(_value), do: []

  defp filename(result_iri) do
    "query-result-#{Sheaf.Id.id_from_iri(result_iri)}.parquet"
  end

  defp temp_dir do
    Path.join(System.tmp_dir!(), "sheaf-query-results")
  end

  defp identifier(identifier) do
    ~s("#{String.replace(to_string(identifier), "\"", "\"\"")}")
  end

  defp literal(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@read_limit)
  defp clamp_limit(_limit), do: 50

  defp clamp_offset(offset) when is_integer(offset), do: max(offset, 0)
  defp clamp_offset(_offset), do: 0

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
