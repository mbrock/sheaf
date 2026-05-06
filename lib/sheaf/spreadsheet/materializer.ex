defmodule Sheaf.Spreadsheet.Materializer do
  @moduledoc """
  Converts XLSX workbook sheets into Parquet files for assistant spreadsheet use.

  XLSX parsing happens here, during explicit import/materialization. Assistant
  sessions consume only the generated Parquet files.
  """

  alias Sheaf.BlobStore

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

  @parquet_mime "application/vnd.apache.parquet"
  @max_metadata_rows 200

  def materialize_file(path, opts \\ []) when is_binary(path) do
    path = Path.expand(path)
    directory = Keyword.get(opts, :directory, Path.dirname(path))
    loaded_at = now_iso8601()

    Tracer.with_span "Sheaf.Spreadsheet.Materializer.materialize_file", %{
      kind: :internal,
      attributes: [
        {"sheaf.spreadsheet.path", path},
        {"sheaf.spreadsheet.directory", Path.expand(directory)}
      ]
    } do
      with {:ok, db} <- Duckdbex.open() do
        try do
          with {:ok, conn} <- Duckdbex.connection(db) do
            try do
              materialize_workbook(conn, path, directory, loaded_at, opts)
            after
              Duckdbex.release(conn)
            end
          end
        after
          Duckdbex.release(db)
        end
      end
    end
  end

  defp materialize_workbook(conn, path, directory, loaded_at, opts) do
    stat = File.stat!(path)
    bytes = File.read!(path)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    file_key = file_key(path, sha)
    id = "xl_" <> String.slice(file_key, 0, 12)
    sheet_names = xlsx_sheet_names(path)

    with :ok <- ensure_extension(conn, "core_functions"),
         :ok <- ensure_extension(conn, "excel"),
         :ok <- ensure_extension(conn, "parquet"),
         {:ok, sheets, sheet_errors} <-
           materialize_sheets(conn, path, id, file_key, sheet_names, opts) do
      if sheets == [] do
        {:error, {:no_readable_sheets, sheet_errors}}
      else
        {:ok,
         %{
           id: id,
           title: relative_path(directory, path),
           path: path,
           basename: Path.basename(path),
           file_size: stat.size,
           file_mtime: mtime(stat),
           sha256: sha,
           loaded_at: loaded_at,
           sheets: sheets,
           sheet_errors: sheet_errors
         }}
      end
    end
  end

  defp materialize_sheets(
         conn,
         path,
         spreadsheet_id,
         file_key,
         sheet_names,
         opts
       ) do
    sheet_names
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {sheet_name, index}, {sheets, errors} ->
      table = table_name(path, file_key, index)

      case materialize_sheet(
             conn,
             path,
             spreadsheet_id,
             table,
             sheet_name,
             index,
             opts
           ) do
        {:ok, sheet} ->
          {[sheet | sheets], errors}

        {:error, reason} ->
          {sheets,
           [
             %{
               path: Path.expand(path),
               sheet: sheet_name,
               sheet_index: index,
               error: reason
             }
             | errors
           ]}
      end
    end)
    |> then(fn {sheets, errors} ->
      {:ok, Enum.reverse(sheets), Enum.reverse(errors)}
    end)
  end

  defp materialize_sheet(
         conn,
         path,
         spreadsheet_id,
         table,
         sheet_name,
         index,
         opts
       ) do
    source = """
    read_xlsx(
      #{literal(path)},
      sheet = #{literal(sheet_name)},
      all_varchar = true,
      normalize_names = true,
      header = true,
      stop_at_empty = false,
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
         :ok <- delete_empty_rows(conn, table, columns),
         :ok <- add_text_column(conn, table, columns),
         {:ok, row_count} <-
           scalar(conn, "SELECT count(*) FROM #{identifier(table)}"),
         {:ok, stored_file} <-
           write_sheet_parquet(conn, table, spreadsheet_id, index, opts) do
      {:ok,
       %{
         spreadsheet_id: spreadsheet_id,
         sheet_index: index,
         name: sheet_name,
         table_name: table,
         row_count: row_count,
         col_count: length(columns),
         columns: columns,
         parquet_file: stored_file
       }}
    end
  end

  defp write_sheet_parquet(conn, table, spreadsheet_id, index, opts) do
    filename = "#{spreadsheet_id}-sheet-#{index}.parquet"

    path =
      Path.join(
        temp_dir(),
        "#{System.unique_integer([:positive])}-#{filename}"
      )

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           exec(
             conn,
             "COPY #{identifier(table)} TO #{literal(path)} (FORMAT parquet)"
           ),
         {:ok, stored_file} <-
           BlobStore.put_file(path,
             root: Keyword.get(opts, :blob_root, configured_blob_root()),
             filename: filename,
             mime_type: @parquet_mime
           ) do
      File.rm(path)
      {:ok, stored_file}
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

  defp delete_empty_rows(_conn, _table, []), do: :ok

  defp delete_empty_rows(conn, table, columns) do
    nonempty_expression =
      columns
      |> Enum.map_join(" OR ", fn %{name: name} ->
        "coalesce(CAST(#{identifier(name)} AS VARCHAR), '') <> ''"
      end)

    exec(
      conn,
      "DELETE FROM #{identifier(table)} WHERE NOT (#{nonempty_expression})"
    )
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
           query_all(
             conn,
             "PRAGMA table_info(#{identifier(table)})",
             @max_metadata_rows
           ) do
      {:ok, Enum.map(result.rows, &Map.fetch!(&1, "name"))}
    end
  end

  defp add_text_column(conn, table, columns) do
    expressions =
      columns
      |> Enum.map(fn %{name: name} ->
        "coalesce(CAST(#{identifier(name)} AS VARCHAR), '')"
      end)
      |> case do
        [] -> literal("")
        expressions -> Enum.join(expressions, ", ")
      end

    with :ok <-
           exec(
             conn,
             "ALTER TABLE #{identifier(table)} ADD COLUMN __text VARCHAR"
           ) do
      exec(
        conn,
        "UPDATE #{identifier(table)} SET __text = concat_ws(#{literal(" | ")}, #{expressions})"
      )
    end
  end

  defp query_all(conn, sql, limit) do
    with {:ok, result} <- Duckdbex.query(conn, sql) do
      try do
        columns = Duckdbex.columns(result)

        rows =
          result |> fetch_limited(limit) |> Enum.map(&row_map(columns, &1))

        {:ok, %{columns: columns, rows: rows}}
      after
        Duckdbex.release(result)
      end
    end
  end

  defp fetch_limited(result, limit), do: fetch_limited(result, limit, [])

  defp fetch_limited(_result, remaining, rows) when remaining <= 0,
    do: Enum.reverse(rows)

  defp fetch_limited(result, remaining, rows) do
    case Duckdbex.fetch_chunk(result) do
      [] ->
        Enum.reverse(rows)

      chunk ->
        {taken, _rest} = Enum.split(chunk, remaining)

        fetch_limited(
          result,
          remaining - length(taken),
          Enum.reverse(taken) ++ rows
        )
    end
  end

  defp exec(conn, sql) do
    with {:ok, result} <- Duckdbex.query(conn, sql) do
      Duckdbex.release(result)
      :ok
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

  defp xlsx_sheet_names(path) do
    with {:ok, entries} <- :zip.extract(String.to_charlist(path), [:memory]),
         {_, bytes} <-
           Enum.find(entries, fn {name, _bytes} ->
             List.to_string(name) == "xl/workbook.xml"
           end),
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

  defp table_name(path, file_key, index) do
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

    "xlsx_#{slug}_#{String.slice(file_key, 0, 8)}_#{index}"
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

  defp file_key(path, sha) do
    :crypto.hash(:sha256, Path.expand(path) <> "\0" <> sha)
    |> Base.encode16(case: :lower)
  end

  defp relative_path(directory, path) do
    directory = directory |> Path.expand() |> Path.split()
    path = path |> Path.expand() |> Path.split()

    case Enum.split(path, length(directory)) do
      {^directory, rest} -> Path.join(rest)
      _ -> Path.basename(Path.join(path))
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

  defp temp_dir do
    Path.join(System.tmp_dir!(), "sheaf-spreadsheet-materializer")
  end

  defp configured_blob_root do
    :sheaf
    |> Application.get_env(BlobStore, [])
    |> Keyword.get(:root, "priv/blobs")
  end
end
