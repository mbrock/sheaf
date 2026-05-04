defmodule Sheaf.Assistant.QueryResults do
  @moduledoc """
  Durable Parquet artifacts for assistant spreadsheet query results.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.{BlobStore, Files}
  alias Sheaf.NS.{AS, CSVW, DCAT, DCTERMS, DOC, FABIO, PROV}
  require RDF.Graph

  @mime_type "application/vnd.apache.parquet"

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
    query_iri = Keyword.get_lazy(opts, :query_iri, &Sheaf.mint/0)
    execution_iri = Keyword.get_lazy(opts, :execution_iri, &Sheaf.mint/0)
    association_iri = Keyword.get_lazy(opts, :association_iri, &RDF.bnode/0)
    generated_at = Keyword.get_lazy(opts, :generated_at, &now/0)
    filename = filename(result_iri)

    with {:ok, parquet_path} <- write_parquet(columns, rows, filename),
         {:ok, stored_file} <-
           BlobStore.put_file(
             parquet_path,
             blob_opts(opts,
               filename: filename,
               mime_type: @mime_type,
               generated_at: generated_at
             )
           ),
         :ok <-
           persist_result_graph(
             result_graph(
               result_iri,
               file_iri,
               query_iri,
               execution_iri,
               association_iri,
               stored_file,
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
         file_iri: to_string(file_iri),
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
         {:ok, graph} <- workspace_graph(opts),
         %Description{} = result <- Graph.description(graph, result_iri),
         file_iri = first_term(result, DCAT.distribution()),
         true <- match?(%RDF.IRI{}, file_iri) || {:error, :missing_result_file},
         %Description{} = file <- Graph.description(graph, file_iri),
         {:ok, path} <- Files.local_path(file, opts) do
      {:ok,
       %{
         id: Sheaf.Id.id_from_iri(result_iri),
         iri: to_string(result_iri),
         file_iri: to_string(file_iri),
         path: path,
         sql: result_sql(graph, result),
         columns: decode_columns(first_value(result, DOC.columnNameList())),
         row_count: first_value(result, DOC.rowCount()) || 0
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
         query_iri,
         execution_iri,
         association_iri,
         stored_file,
         sql,
         columns,
         row_count,
         generated_at,
         opts
       ) do
    session_iri = optional_iri(opts, :session_iri)
    agent_iri = optional_iri(opts, :agent_iri)

    Graph.new(name: Sheaf.Workspace.graph())
    |> add(file_iri, RDF.type(), DCAT.Distribution)
    |> add(file_iri, RDF.type(), FABIO.ComputerFile)
    |> add(file_iri, RDF.type(), PROV.Entity)
    |> add(file_iri, RDF.NS.RDFS.label(), stored_file.original_filename)
    |> add(file_iri, DCTERMS.title(), stored_file.original_filename)
    |> add(file_iri, DCTERMS.identifier(), stored_file.storage_key)
    |> add(file_iri, DCAT.mediaType(), @mime_type)
    |> add(file_iri, DCAT.byteSize(), stored_file.byte_size)
    |> add(file_iri, DOC.sha256(), stored_file.hash)
    |> add(file_iri, DOC.originalFilename(), stored_file.original_filename)
    |> add(file_iri, PROV.wasGeneratedBy(), execution_iri)
    |> add(file_iri, PROV.generatedAtTime(), generated_at)
    |> add(query_iri, RDF.type(), DOC.SpreadsheetQuery)
    |> add(query_iri, RDF.type(), PROV.Plan)
    |> add(query_iri, RDF.NS.RDFS.label(), "Spreadsheet query plan")
    |> add(query_iri, RDF.NS.RDF.value(), sql)
    |> add(query_iri, DCTERMS.format(), "text/sql")
    |> add(query_iri, DOC.sourceQuery(), sql)
    |> add(execution_iri, RDF.type(), DOC.SpreadsheetQueryExecution)
    |> add(execution_iri, RDF.type(), DOC.ToolCall)
    |> add(execution_iri, RDF.type(), PROV.Activity)
    |> add(execution_iri, RDF.NS.RDFS.label(), "Spreadsheet query execution")
    |> add(execution_iri, DOC.toolName(), "query_spreadsheets")
    |> add(execution_iri, PROV.used(), query_iri)
    |> add(execution_iri, PROV.generated(), result_iri)
    |> add(execution_iri, PROV.generated(), file_iri)
    |> add(execution_iri, PROV.qualifiedAssociation(), association_iri)
    |> add(execution_iri, PROV.wasInformedBy(), session_iri)
    |> add(execution_iri, AS.context(), session_iri)
    |> add(execution_iri, AS.attributedTo(), agent_iri)
    |> add(association_iri, RDF.type(), PROV.Association)
    |> add(association_iri, PROV.agent(), agent_iri)
    |> add(association_iri, PROV.hadPlan(), query_iri)
    |> add(result_iri, RDF.type(), DOC.SpreadsheetQueryResult)
    |> add(result_iri, RDF.type(), DOC.QueryResult)
    |> add(result_iri, RDF.type(), DCAT.Dataset)
    |> add(result_iri, RDF.type(), PROV.Entity)
    |> add(result_iri, RDF.NS.RDFS.label(), "Spreadsheet query result")
    |> add(result_iri, DCTERMS.title(), "Spreadsheet query result")
    |> add(result_iri, DCAT.distribution(), file_iri)
    |> add(result_iri, DOC.rowCount(), row_count)
    |> add(result_iri, DOC.columnNameList(), Jason.encode!(columns))
    |> add(result_iri, PROV.wasGeneratedBy(), execution_iri)
    |> add(result_iri, PROV.generatedAtTime(), generated_at)
    |> add(result_iri, AS.context(), session_iri)
    |> add_result_schema(result_iri, columns)
  end

  defp add_result_schema(graph, result_iri, columns) do
    table_iri = RDF.iri(to_string(result_iri) <> "/table")
    schema_iri = RDF.iri(to_string(table_iri) <> "/schema")

    graph
    |> add(result_iri, CSVW.table(), table_iri)
    |> add(table_iri, RDF.type(), CSVW.Table)
    |> add(table_iri, CSVW.tableSchema(), schema_iri)
    |> add(schema_iri, RDF.type(), CSVW.Schema)
    |> then(fn graph ->
      columns
      |> Enum.with_index(1)
      |> Enum.reduce(graph, fn {column, index}, graph ->
        column_iri = RDF.iri(to_string(table_iri) <> "/column/#{index}")

        graph
        |> add(schema_iri, CSVW.column(), column_iri)
        |> add(column_iri, RDF.type(), CSVW.Column)
        |> add(column_iri, CSVW.name(), column)
        |> add(column_iri, CSVW.title(), column)
        |> add(column_iri, CSVW.datatype(), RDF.NS.XSD.string())
        |> add(column_iri, DOC.columnIndex(), index)
      end)
    end)
  end

  defp persist_result_graph(%Graph{} = graph, opts) do
    graph = Graph.change_name(graph, Sheaf.Workspace.graph())
    persist = Keyword.get(opts, :persist, &Sheaf.Repo.assert/1)

    case persist.(graph) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_persist_result, other}}
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

  defp blob_opts(opts, defaults) do
    opts
    |> Keyword.take([:blob_root])
    |> Keyword.new(fn {:blob_root, root} -> {:root, root} end)
    |> Keyword.merge(Keyword.take(defaults, [:filename, :mime_type]))
  end

  defp add(graph, _subject, _predicate, nil), do: graph
  defp add(graph, subject, predicate, object), do: Graph.add(graph, {subject, predicate, object})

  defp cell(nil), do: nil
  defp cell(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp cell(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp cell(%Date{} = value), do: Date.to_iso8601(value)
  defp cell(%Time{} = value), do: Time.to_iso8601(value)
  defp cell(value) when is_binary(value), do: value
  defp cell(value) when is_boolean(value), do: to_string(value)
  defp cell(value) when is_integer(value), do: Integer.to_string(value)
  defp cell(value) when is_float(value), do: Float.to_string(value) |> String.replace_suffix(".0", "")
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
      nil ->
        nil

      %RDF.IRI{} = iri ->
        iri

      value when is_binary(value) ->
        case normalize_iri(value) do
          {:ok, iri} -> iri
          {:error, _reason} -> nil
        end

      _other ->
        nil
    end
  end

  defp result_sql(graph, %Description{} = result) do
    with %RDF.IRI{} = execution_iri <- first_term(result, PROV.wasGeneratedBy()),
         %Description{} = execution <- Graph.description(graph, execution_iri),
         %RDF.IRI{} = query_iri <- query_plan_iri(graph, execution),
         %Description{} = query <- Graph.description(graph, query_iri) do
      first_value(query, DOC.sourceQuery()) || first_value(query, RDF.NS.RDF.value())
    else
      _ -> nil
    end
  end

  defp query_plan_iri(graph, %Description{} = execution) do
    execution
    |> Description.get(PROV.used(), [])
    |> Enum.find(fn iri ->
      case Graph.description(graph, iri) do
        %Description{} = description ->
          Description.include?(description, {RDF.type(), DOC.SpreadsheetQuery})

        nil ->
          false
      end
    end)
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

  defp clamp_limit(limit) when is_integer(limit), do: max(limit, 1)
  defp clamp_limit(_limit), do: 50

  defp clamp_offset(offset) when is_integer(offset), do: max(offset, 0)
  defp clamp_offset(_offset), do: 0

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
