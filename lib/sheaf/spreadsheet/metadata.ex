defmodule Sheaf.Spreadsheet.Metadata do
  @moduledoc """
  Workspace-graph metadata for XLSX files available to spreadsheet tools.

  This records workbook, sheet, schema, column, and source file metadata. It does
  not import spreadsheet rows into RDF; row data stays in the XLSX file and in
  per-assistant DuckDB sessions.
  """

  alias RDF.{Description, Graph}
  alias Sheaf.BlobStore
  alias Sheaf.NS.{CSVW, DCAT, DCTERMS, DOC, FABIO, PROV}
  alias Sheaf.Spreadsheet.Materializer
  require OpenTelemetry.Tracer, as: Tracer

  @xlsx_mime "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  @parquet_mime "application/vnd.apache.parquet"

  def import_directory(path, opts \\ []) when is_binary(path) do
    path
    |> xlsx_files()
    |> import_paths(Keyword.put_new(opts, :directory, path))
  end

  def import_paths(paths, opts \\ []) when is_list(paths) do
    paths =
      paths |> Enum.flat_map(&xlsx_files/1) |> Enum.uniq() |> Enum.sort()

    directory = Keyword.get(opts, :directory, common_directory(paths))

    Tracer.with_span "Sheaf.Spreadsheet.Metadata.import_paths", %{
      kind: :internal,
      attributes: [
        {"sheaf.spreadsheet.directory", Path.expand(directory || ".")},
        {"sheaf.spreadsheet.path_count", length(paths)}
      ]
    } do
      {imported, errors} =
        Enum.reduce(paths, {[], []}, fn path, {imported, errors} ->
          case import_file(path, Keyword.put(opts, :directory, directory)) do
            {:ok, result} ->
              {[result | imported], errors}

            {:error, reason} ->
              {imported, [%{path: path, error: reason} | errors]}
          end
        end)

      {:ok, %{imported: Enum.reverse(imported), errors: Enum.reverse(errors)}}
    end
  end

  def import_file(path, opts \\ []) when is_binary(path) do
    path = Path.expand(path)
    directory = Keyword.get(opts, :directory, Path.dirname(path))

    Tracer.with_span "Sheaf.Spreadsheet.Metadata.import_file", %{
      kind: :internal,
      attributes: [
        {"sheaf.spreadsheet.path", path},
        {"sheaf.spreadsheet.directory", Path.expand(directory)}
      ]
    } do
      with {:ok, spreadsheet} <-
             Materializer.materialize_file(path,
               directory: directory,
               blob_root:
                 Keyword.get(opts, :blob_root, configured_blob_root())
             ),
           {:ok, stored_file} <-
             BlobStore.put_file(path,
               root: Keyword.get(opts, :blob_root, configured_blob_root()),
               filename: Path.basename(path),
               mime_type: @xlsx_mime
             ),
           graph = workbook_graph(spreadsheet, stored_file, directory, opts),
           subjects = graph_subjects(graph),
           :ok <- persist(graph, subjects, opts) do
        {:ok,
         %{
           workbook: workbook_iri(spreadsheet),
           file: file_iri(spreadsheet),
           title: spreadsheet.title,
           path: path,
           sheets: spreadsheet.sheets,
           sheet_errors: spreadsheet.sheet_errors,
           graph: Sheaf.Workspace.graph()
         }}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def list(opts \\ []) do
    with {:ok, graph} <- workspace_graph(opts) do
      workbooks =
        graph
        |> RDF.Data.descriptions()
        |> Enum.filter(
          &Description.include?(&1, {RDF.type(), DOC.SpreadsheetWorkbook})
        )
        |> Enum.map(&workbook_info(graph, &1))
        |> Enum.sort_by(& &1.title)

      {:ok, workbooks}
    end
  end

  defp workbook_graph(spreadsheet, stored_file, directory, _opts) do
    workbook = workbook_iri(spreadsheet)
    file = file_iri(spreadsheet)
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second)

    Graph.new(name: Sheaf.Workspace.graph())
    |> add(file, RDF.type(), DCAT.Distribution)
    |> add(file, RDF.type(), FABIO.ComputerFile)
    |> add(file, RDF.type(), PROV.Entity)
    |> add(file, RDF.NS.RDFS.label(), stored_file.original_filename)
    |> add(file, DCTERMS.title(), stored_file.original_filename)
    |> add(file, DCTERMS.identifier(), stored_file.storage_key)
    |> add(file, DCAT.mediaType(), @xlsx_mime)
    |> add(file, DCAT.byteSize(), stored_file.byte_size)
    |> add(file, DOC.sha256(), stored_file.hash)
    |> add(file, DOC.originalFilename(), stored_file.original_filename)
    |> add(file, PROV.generatedAtTime(), generated_at)
    |> add(workbook, RDF.type(), DOC.SpreadsheetWorkbook)
    |> add(workbook, RDF.type(), DCAT.Dataset)
    |> add(workbook, RDF.type(), CSVW.TableGroup)
    |> add(workbook, RDF.type(), PROV.Entity)
    |> add(workbook, RDF.NS.RDFS.label(), spreadsheet.title)
    |> add(workbook, DCTERMS.title(), spreadsheet.title)
    |> add(workbook, DCTERMS.identifier(), spreadsheet.id)
    |> add(
      workbook,
      DOC.workspacePath(),
      relative_path(directory, spreadsheet.path)
    )
    |> add(workbook, DOC.sourceFile(), file)
    |> add(workbook, DCAT.distribution(), file)
    |> add_sheets(workbook, spreadsheet.sheets)
  end

  defp add_sheets(graph, workbook, sheets) do
    Enum.reduce(sheets, graph, fn sheet, graph ->
      sheet_iri = sheet_iri(workbook, sheet.sheet_index)
      schema = schema_iri(sheet_iri)
      columns = sheet.columns || []

      graph
      |> add(workbook, CSVW.table(), sheet_iri)
      |> add(sheet_iri, RDF.type(), DOC.SpreadsheetSheet)
      |> add(sheet_iri, RDF.type(), CSVW.Table)
      |> add(sheet_iri, RDF.type(), PROV.Entity)
      |> add(sheet_iri, RDF.NS.RDFS.label(), sheet.name)
      |> add(sheet_iri, CSVW.name(), sheet.name)
      |> add(sheet_iri, DCTERMS.isPartOf(), workbook)
      |> add(sheet_iri, PROV.wasDerivedFrom(), workbook)
      |> add(sheet_iri, CSVW.tableSchema(), schema)
      |> add(sheet_iri, DOC.sheetIndex(), sheet.sheet_index)
      |> add(sheet_iri, DOC.duckdbTableName(), sheet.table_name)
      |> add(sheet_iri, DOC.rowCount(), sheet.row_count)
      |> add(
        sheet_iri,
        DOC.columnNameList(),
        Jason.encode!(Enum.map(columns, & &1.name))
      )
      |> add(schema, RDF.type(), CSVW.Schema)
      |> add_columns(schema, sheet_iri, columns)
      |> add_materialized_distribution(sheet_iri, sheet.parquet_file)
    end)
  end

  defp add_materialized_distribution(graph, sheet_iri, stored_file) do
    file = parquet_file_iri(sheet_iri)

    graph
    |> add(sheet_iri, DOC.materializedDistribution(), file)
    |> add(file, RDF.type(), DCAT.Distribution)
    |> add(file, RDF.type(), FABIO.ComputerFile)
    |> add(file, RDF.type(), PROV.Entity)
    |> add(file, RDF.NS.RDFS.label(), stored_file.original_filename)
    |> add(file, DCTERMS.title(), stored_file.original_filename)
    |> add(file, DCTERMS.identifier(), stored_file.storage_key)
    |> add(file, DCAT.mediaType(), @parquet_mime)
    |> add(file, DCAT.byteSize(), stored_file.byte_size)
    |> add(file, DOC.sha256(), stored_file.hash)
    |> add(file, DOC.originalFilename(), stored_file.original_filename)
  end

  defp add_columns(graph, schema, sheet, columns) do
    columns
    |> Enum.with_index(1)
    |> Enum.reduce(graph, fn {column, index}, graph ->
      column_iri = column_iri(sheet, index)

      graph
      |> add(schema, CSVW.column(), column_iri)
      |> add(column_iri, RDF.type(), CSVW.Column)
      |> add(column_iri, CSVW.name(), column.name)
      |> add(column_iri, CSVW.title(), Map.get(column, :header, column.name))
      |> add(column_iri, CSVW.datatype(), RDF.NS.XSD.string())
      |> add(column_iri, DOC.columnIndex(), index)
    end)
  end

  defp workbook_info(graph, %Description{} = workbook) do
    sheets =
      workbook
      |> Description.get(CSVW.table(), [])
      |> Enum.map(&Graph.description(graph, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&sheet_info(graph, &1))
      |> Enum.sort_by(& &1.sheet_index)

    %{
      iri: to_string(workbook.subject),
      id: Sheaf.Id.id_from_iri(workbook.subject),
      title:
        first_value(workbook, DCTERMS.title()) ||
          first_value(workbook, RDF.NS.RDFS.label()),
      path: first_value(workbook, DOC.workspacePath()),
      file_iri:
        workbook |> first_term(DOC.sourceFile()) |> to_string_or_nil(),
      sheets: sheets
    }
  end

  defp sheet_info(graph, %Description{} = sheet) do
    columns =
      sheet
      |> first_term(CSVW.tableSchema())
      |> then(&if &1, do: Graph.description(graph, &1), else: nil)
      |> case do
        nil ->
          []

        schema ->
          schema
          |> Description.get(CSVW.column(), [])
          |> Enum.map(&Graph.description(graph, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn column ->
            %{
              name: first_value(column, CSVW.name()),
              title: first_value(column, CSVW.title()),
              column_index: first_value(column, DOC.columnIndex())
            }
          end)
          |> Enum.sort_by(&(&1.column_index || 0))
      end

    %{
      iri: to_string(sheet.subject),
      name:
        first_value(sheet, CSVW.name()) ||
          first_value(sheet, RDF.NS.RDFS.label()),
      sheet_index: first_value(sheet, DOC.sheetIndex()),
      table_name: first_value(sheet, DOC.duckdbTableName()),
      parquet_file_iri:
        sheet
        |> first_term(DOC.materializedDistribution())
        |> to_string_or_nil(),
      row_count: first_value(sheet, DOC.rowCount()),
      columns: columns
    }
  end

  defp persist(%Graph{} = graph, subjects, opts) do
    case Keyword.fetch(opts, :persist) do
      {:ok, persist} ->
        persist.(graph)

      :error ->
        workspace = RDF.iri(Sheaf.Workspace.graph())

        with :ok <- Sheaf.Repo.load_once({nil, nil, nil, workspace}) do
          old_graph =
            Sheaf.Repo.ask(fn dataset ->
              dataset
              |> RDF.Dataset.graph(workspace)
              |> case do
                nil -> Graph.new(name: workspace)
                graph -> descriptions_graph(graph, subjects)
              end
            end)

          Sheaf.Repo.transact("spreadsheet metadata import", [
            {:retract, old_graph},
            {:assert, Graph.change_name(graph, workspace)}
          ])
        end
    end
  end

  defp descriptions_graph(graph, subjects) do
    subject_set = MapSet.new(subjects)

    graph
    |> Graph.triples()
    |> Enum.filter(fn {subject, _predicate, _object} ->
      MapSet.member?(subject_set, subject)
    end)
    |> Graph.new(name: Sheaf.Workspace.graph())
  end

  defp workspace_graph(opts) do
    case Keyword.fetch(opts, :workspace_graph) do
      {:ok, graph} ->
        {:ok, graph}

      :error ->
        workspace = RDF.iri(Sheaf.Workspace.graph())

        with :ok <- Sheaf.Repo.load_once({nil, nil, nil, workspace}) do
          graph =
            Sheaf.Repo.ask(fn dataset ->
              RDF.Dataset.graph(dataset, workspace) ||
                Graph.new(name: workspace)
            end)

          {:ok, graph}
        end
    end
  end

  defp graph_subjects(graph) do
    graph
    |> Graph.triples()
    |> Enum.map(fn {subject, _predicate, _object} -> subject end)
    |> Enum.uniq()
  end

  defp workbook_iri(spreadsheet),
    do:
      Sheaf.Id.iri("XLSX-" <> String.slice(workbook_key(spreadsheet), 0, 16))

  defp file_iri(spreadsheet),
    do: workbook_iri(spreadsheet) |> append_iri("/source-file")

  defp sheet_iri(workbook, index), do: append_iri(workbook, "/sheet/#{index}")
  defp schema_iri(sheet), do: append_iri(sheet, "/schema")
  defp column_iri(sheet, index), do: append_iri(sheet, "/column/#{index}")
  defp parquet_file_iri(sheet), do: append_iri(sheet, "/parquet")

  defp append_iri(iri, suffix), do: RDF.iri(to_string(iri) <> suffix)

  defp workbook_key(spreadsheet) do
    :crypto.hash(
      :sha256,
      Path.expand(spreadsheet.path) <> "\0" <> spreadsheet.sha256
    )
    |> Base.encode16(case: :lower)
  end

  defp xlsx_files(path) do
    path = Path.expand(path)

    cond do
      File.regular?(path) and xlsx?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.map(&Path.join(path, &1))
        |> Enum.flat_map(&xlsx_files/1)
        |> Enum.sort()

      true ->
        []
    end
  end

  defp xlsx?(path), do: path |> Path.extname() |> String.downcase() == ".xlsx"

  defp add(graph, _subject, _predicate, nil), do: graph

  defp add(graph, subject, predicate, object),
    do: Graph.add(graph, {subject, predicate, object})

  defp first_term(%Description{} = description, property),
    do: Description.first(description, property)

  defp first_value(%Description{} = description, property) do
    description
    |> first_term(property)
    |> case do
      nil -> nil
      term -> RDF.Term.value(term)
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(term), do: to_string(term)

  defp relative_path(nil, path), do: Path.basename(path)

  defp relative_path(directory, path) do
    directory = directory |> Path.expand() |> Path.split()
    path = path |> Path.expand() |> Path.split()

    case Enum.split(path, length(directory)) do
      {^directory, rest} -> Path.join(rest)
      _ -> Path.basename(Path.join(path))
    end
  end

  defp common_directory([]), do: File.cwd!()
  defp common_directory([path]), do: Path.dirname(path)

  defp common_directory(paths),
    do: paths |> Enum.map(&Path.dirname/1) |> common_path()

  defp common_path(paths) do
    paths
    |> Enum.map(&Path.split/1)
    |> Enum.zip()
    |> Enum.map(&Tuple.to_list/1)
    |> Enum.take_while(fn parts -> parts |> Enum.uniq() |> length() == 1 end)
    |> Enum.map(&hd/1)
    |> case do
      [] -> File.cwd!()
      parts -> Path.join(parts)
    end
  end

  defp configured_blob_root do
    :sheaf
    |> Application.get_env(BlobStore, [])
    |> Keyword.get(:root, "priv/blobs")
  end
end
