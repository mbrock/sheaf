defmodule Sheaf.Admin.Error do
  defexception [:message]
end

defmodule Sheaf.Admin do
  @moduledoc """
  Operational jobs exposed by the `sheaf-admin` escript.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.Serialization
  alias Sheaf.NS.DOC

  def backup(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: [output: :string])

    reject_invalid!(invalid)

    case backup_dataset(opts) do
      {:ok, path} ->
        info("Backed up the Quadlog dataset to #{path}")

      {:error, message} ->
        fail!(message)
    end
  end

  def upload_schema(args) do
    reject_positional!(args)

    Sheaf.put_graph(DOC.__base_iri__(), Serialization.read_file!(schema_path()))
    info("Uploaded schema graph #{DOC.__base_iri__()}")

    Sheaf.put_graph(extension_graph(), Serialization.read_file!(extension_path()))
    info("Uploaded schema extension graph #{extension_graph()}")

    Sheaf.put_graph(imported_ontologies_graph(), imported_ontologies())
    info("Uploaded imported ontology graph #{imported_ontologies_graph()}")
  end

  def sync_search(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: [db: :string, limit: :integer, kind: :keep])

    reject_invalid!(invalid)

    sync_opts =
      []
      |> put_if_present(:db_path, Keyword.get(opts, :db))
      |> put_if_present(:limit, Keyword.get(opts, :limit))
      |> put_kinds(Keyword.get_values(opts, :kind))

    case Sheaf.Search.Index.sync(sync_opts) do
      {:ok, summary} ->
        info(
          "Search sync complete: db=#{summary.db_path} rows=#{summary.count}#{kind_summary(summary.kinds)}"
        )

      {:error, reason} ->
        fail!("Search sync failed: #{inspect(reason)}")
    end
  end

  def sync_search_indexes(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: embedding_sync_options())

    reject_invalid!(invalid)

    search_opts = search_opts(opts)
    embedding_opts = embedding_opts(opts)

    with {:ok, search_summary} <- Sheaf.Search.Index.sync(search_opts),
         {:ok, embedding_summary} <- Sheaf.Embedding.Index.sync(embedding_opts) do
      info(
        "Search sync complete: db=#{search_summary.db_path} rows=#{search_summary.count}#{kind_summary(search_summary.kinds)}"
      )

      info(
        "Embedding sync #{embedding_summary.status}: run=#{embedding_summary.run_iri}#{batch_summary(embedding_summary)} target=#{embedding_summary.target_count} embedded=#{embedding_summary.embedded_count} skipped=#{embedding_summary.skipped_count} errors=#{embedding_summary.error_count}"
      )
    else
      {:error, reason} ->
        fail!("Search index sync failed: #{inspect(reason)}")
    end
  end

  def sync_embeddings(args) do
    {opts, _positional, invalid} = OptionParser.parse(args, strict: embedding_sync_options())

    reject_invalid!(invalid)

    case Sheaf.Embedding.Index.sync(embedding_opts(opts)) do
      {:ok, summary} ->
        info(
          "Embedding sync #{summary.status}: run=#{summary.run_iri}#{batch_summary(summary)} target=#{summary.target_count} embedded=#{summary.embedded_count} skipped=#{summary.skipped_count} errors=#{summary.error_count}"
        )

      {:error, reason} ->
        fail!("Embedding sync failed: #{inspect(reason)}")
    end
  end

  def plan_embeddings(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: Keyword.merge(embedding_sync_options(), sample: :integer))

    reject_invalid!(invalid)

    case Sheaf.Embedding.Index.plan(embedding_opts(opts)) do
      {:ok, plan} ->
        info(
          "Embedding plan: model=#{plan.model} dimensions=#{plan.dimensions} source=#{plan.source} target=#{plan.target_count} reusable=#{plan.reusable_count} would_embed=#{plan.missing_count}#{kind_summary(plan.missing_kinds)}"
        )

        Enum.each(plan.sample, fn unit ->
          info(
            "  #{unit.kind} #{unit.iri} chars=#{unit.text_chars} doc=#{unit.doc_iri} title=#{unit.doc_title}"
          )
        end)

      {:error, reason} ->
        fail!("Embedding plan failed: #{inspect(reason)}")
    end
  end

  def ingest_files(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [recursive: :boolean, no_backup: :boolean, dry_run: :boolean, extensions: :string]
      )

    reject_invalid!(invalid)

    if paths == [],
      do:
        fail!(
          "Usage: sheaf-admin ingest files PATH... [--recursive] [--extensions pdf,docx] [--dry-run] [--no-backup]"
        )

    files = files(paths, opts)

    if files == [] do
      info("No files to ingest.")
    else
      unless opts[:no_backup] || opts[:dry_run], do: backup([])
      ingest!(files, opts)
    end
  end

  def import_datalab_json(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [title: :string, pdf: :string, no_backup: :boolean])

    reject_invalid!(invalid)

    if length(paths) != 1,
      do:
        fail!(
          "Usage: sheaf-admin import datalab-json PATH [--title TITLE] [--pdf PDF] [--no-backup]"
        )

    unless opts[:no_backup], do: backup([])
    [path] = paths

    case Sheaf.PDF.import_file(path, title: opts[:title], pdf_path: opts[:pdf]) do
      {:ok, result} ->
        id = Sheaf.Id.id_from_iri(result.document)
        info("Imported #{result.title}")
        info("Graph #{result.document}")
        if result.source_file, do: info("Source file #{result.source_file.path}")
        info("URL /#{id}")

      {:error, reason} ->
        fail!("Import failed: #{inspect(reason)}")
    end
  end

  def import_spreadsheet(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [title: :string, graph: :string, no_backup: :boolean])

    reject_invalid!(invalid)

    if length(paths) != 1,
      do:
        fail!(
          "Usage: sheaf-admin import spreadsheet PATH [--title TITLE] [--graph IRI] [--no-backup]"
        )

    unless opts[:no_backup], do: backup([])
    [path] = paths

    import_opts =
      opts
      |> Keyword.take([:title])
      |> maybe_put_document(opts[:graph])

    case Sheaf.Spreadsheet.import_file(path, import_opts) do
      {:ok, result} ->
        id = Sheaf.Id.id_from_iri(result.document)
        info("Imported #{result.title}")
        info("Graph #{result.document}")
        info("Sources #{result.sources}")
        info("Rows #{result.rows}")
        info("URL /#{id}")

      {:error, reason} ->
        fail!("Import failed: #{inspect(reason)}")
    end
  end

  def import_spreadsheets(args) do
    {opts, paths, invalid} =
      OptionParser.parse(args, strict: [title: :string, db: :string])

    reject_invalid!(invalid)

    if paths == [] do
      fail!("Usage: sheaf-admin spreadsheets import PATH... [--title TITLE] [--db PATH]")
    end

    Enum.each(paths, fn path ->
      import_opts =
        []
        |> put_if_present(:title, opts[:title])
        |> put_if_present(:db_path, opts[:db])

      case Sheaf.Spreadsheets.import_file(path, import_opts) do
        {:ok, result} ->
          info("Imported spreadsheet #{result.id}: #{result.title}")

          Enum.each(result.sheets, fn sheet ->
            info(
              "  #{sheet.name} -> #{sheet.table_name} rows=#{sheet.row_count} cols=#{sheet.col_count}"
            )
          end)

        {:error, reason} ->
          fail!("Import failed for #{path}: #{inspect(reason)}")
      end
    end)
  end

  def import_spreadsheet_metadata(args) do
    {opts, paths, invalid} = OptionParser.parse(args, strict: [no_backup: :boolean])

    reject_invalid!(invalid)

    if paths == [] do
      fail!("Usage: sheaf-admin spreadsheets import-metadata PATH... [--no-backup]")
    end

    unless opts[:no_backup], do: backup([])

    case Sheaf.Spreadsheet.Metadata.import_paths(paths) do
      {:ok, %{imported: imported, errors: errors}} ->
        Enum.each(imported, fn workbook ->
          info("Imported spreadsheet metadata #{workbook.workbook}: #{workbook.title}")

          Enum.each(workbook.sheets, fn sheet ->
            info("  #{sheet.name} rows=#{sheet.row_count} cols=#{sheet.col_count}")
          end)
        end)

        Enum.each(errors, fn error ->
          info("Skipped spreadsheet metadata #{error.path}: #{inspect(error.error)}")
        end)

      {:error, reason} ->
        fail!("Spreadsheet metadata import failed: #{inspect(reason)}")
    end
  end

  def list_spreadsheets(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [db: :string])
    reject_invalid!(invalid)
    reject_positional!(positional)

    case Sheaf.Spreadsheets.list(spreadsheet_db_opts(opts)) do
      {:ok, spreadsheets} ->
        Enum.each(spreadsheets, fn spreadsheet ->
          info("#{spreadsheet.id} #{spreadsheet.title} #{spreadsheet.path}")

          Enum.each(spreadsheet.sheets, fn sheet ->
            columns = sheet.columns |> Enum.map(& &1["name"]) |> Enum.join(", ")
            info("  #{sheet.table_name} #{sheet.name} rows=#{sheet.row_count} columns=#{columns}")
          end)
        end)

      {:error, reason} ->
        fail!("List failed: #{inspect(reason)}")
    end
  end

  def query_spreadsheets(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [db: :string, limit: :integer])
    reject_invalid!(invalid)

    if positional == [] do
      fail!("Usage: sheaf-admin spreadsheets query SQL [--db PATH] [--limit N]")
    end

    sql = Enum.join(positional, " ")

    query_opts =
      opts
      |> spreadsheet_db_opts()
      |> Keyword.put(:limit, opts[:limit] || 50)

    case Sheaf.Spreadsheets.query(sql, query_opts) do
      {:ok, result} ->
        info(Jason.encode!(result, pretty: true))

      {:error, reason} ->
        fail!("Query failed: #{inspect(reason)}")
    end
  end

  def enqueue_metadata(args) do
    {opts, positional} =
      OptionParser.parse!(args,
        strict: [
          all: :boolean,
          missing_only: :boolean,
          limit: :integer,
          doc: :string,
          telegram: :boolean
        ]
      )

    reject_positional!(positional)
    resolver_opts = resolver_opts(opts)

    case Sheaf.MetadataResolver.Queue.enqueue(resolver_opts) do
      {:ok, batch} ->
        message = "Enqueued #{batch.target_count} metadata task(s) in #{short(batch.iri)}"
        info(message)
        if opts[:telegram], do: Sheaf.Telegram.notify(telegram_message(batch, resolver_opts))

      {:error, reason} ->
        fail!("Failed to enqueue metadata tasks: #{inspect(reason)}")
    end
  end

  def work_metadata(args) do
    {opts, positional} =
      OptionParser.parse!(args,
        strict: [
          limit: :integer,
          concurrency: :integer,
          extract_concurrency: :integer,
          lookup_concurrency: :integer,
          match_concurrency: :integer,
          import_concurrency: :integer,
          telegram: :boolean,
          pdf_fallback: :boolean,
          pdf_pages: :integer,
          model: :string,
          receive_timeout: :integer
        ]
      )

    if positional not in [[], ["metadata"]],
      do: fail!("Unexpected arguments: #{inspect(positional)}")

    worker_opts =
      []
      |> Keyword.put(:limit, opts[:limit] || 1)
      |> Keyword.put(:concurrency_by_kind, concurrency_by_kind(opts))
      |> Keyword.put(:telegram, opts[:telegram] || false)
      |> put_if_present(:pdf_fallback, opts[:pdf_fallback])
      |> put_if_present(:pdf_pages, opts[:pdf_pages])
      |> put_if_present(:model, opts[:model])
      |> put_if_present(:receive_timeout, opts[:receive_timeout])

    {:ok, result} = Sheaf.MetadataResolver.Queue.work(worker_opts)

    info(
      "Processed #{result.processed}; imported #{result.imported}, skipped #{result.skipped}, errors #{result.errors}."
    )
  end

  def list_metadata_tasks(args) do
    {opts, _positional} =
      OptionParser.parse!(args, strict: [tasks: :boolean, limit: :integer, status: :string])

    if opts[:tasks], do: list_tasks(opts), else: list_batches(opts)
  end

  def resolve_metadata(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          file_data: :boolean,
          all: :boolean,
          missing_only: :boolean,
          limit: :integer,
          doc: :string,
          pdf_fallback: :boolean,
          pdf_pages: :integer,
          model: :string,
          receive_timeout: :integer
        ]
      )

    reject_invalid!(invalid)
    reject_positional!(positional)

    resolver_opts = resolver_opts(opts)

    case Sheaf.MetadataResolver.candidates(resolver_opts) do
      {:ok, candidates} ->
        cond do
          opts[:file_data] -> print_file_data(candidates, resolver_opts)
          opts[:dry_run] -> print_dry_run(candidates, resolver_opts)
          true -> resolve_metadata!(candidates, resolver_opts)
        end

      {:error, reason} ->
        fail!("Failed to list metadata candidates: #{inspect(reason)}")
    end
  end

  defp backup_dataset(opts) do
    path = output_path(opts)
    source = Sheaf.Repo.path()

    Tracer.with_span "sheaf.admin.backup", %{
      kind: :internal,
      attributes: [
        {"db.system", "sqlite"},
        {"db.operation", "backup"},
        {"db.name", source},
        {"sheaf.backup.path", path}
      ]
    } do
      File.mkdir_p!(Path.dirname(path))

      case Exqlite.start_link(database: source) do
        {:ok, conn} ->
          try do
            with {:ok, _result} <-
                   Exqlite.query(conn, "VACUUM main INTO ?", [path], timeout: :infinity) do
              {:ok, path}
            else
              {:error, reason} -> {:error, "SQLite backup failed: #{inspect(reason)}"}
            end
          after
            GenServer.stop(conn)
          end

        {:error, reason} ->
          {:error, "SQLite backup failed: #{inspect(reason)}"}
      end
    end
  end

  defp output_path(opts) do
    file = "sheaf-#{DateTime.utc_now() |> DateTime.to_unix()}.sqlite3"

    case Keyword.get(opts, :output) do
      nil -> Path.join(["output", "backups", file])
      output -> normalize_output(output, file)
    end
  end

  defp normalize_output(output, file) do
    cond do
      String.ends_with?(output, "/") -> Path.join(output, file)
      Path.extname(output) in [".db", ".sqlite", ".sqlite3"] -> output
      true -> Path.join(output, file)
    end
  end

  defp schema_path, do: priv_path("sheaf-schema.ttl")
  defp extension_path, do: priv_path("sheaf-ext.ttl")
  defp extension_graph, do: "https://less.rest/sheaf/ext"
  defp imported_ontologies_graph, do: "https://less.rest/sheaf/imported-ontologies"

  defp imported_ontologies do
    "ontologies/*"
    |> priv_path()
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&Serialization.read_file!/1)
    |> Enum.reduce(RDF.Graph.new(), &RDF.Graph.add(&2, &1))
  end

  defp priv_path(path) do
    checkout_root = System.get_env("SHEAF_CHECKOUT_ROOT") || System.get_env("SHEAF_APP_ROOT")

    cond do
      is_binary(checkout_root) and File.dir?(Path.join(checkout_root, "priv")) ->
        Path.join([checkout_root, "priv", path])

      File.dir?(Path.join(File.cwd!(), "priv")) ->
        Path.join([File.cwd!(), "priv", path])

      true ->
        Application.app_dir(:sheaf, Path.join("priv", path))
    end
  end

  defp ingest!(files, opts) do
    info("#{if opts[:dry_run], do: "Would ingest", else: "Ingesting"} #{length(files)} files")

    results =
      Enum.map(files, fn path ->
        case ingest_file(path, opts) do
          {:ok, result} ->
            print_ingest_result(path, result, opts)
            {:ok, result}

          {:error, reason} ->
            error("ERROR #{path}: #{inspect(reason)}")
            {:error, {path, reason}}
        end
      end)

    created = Enum.count(results, &match?({:ok, %{created?: true}}, &1))
    existing = Enum.count(results, &match?({:ok, %{created?: false}}, &1))
    errors = Enum.count(results, &match?({:error, _}, &1))

    info("Done. Created #{created}, existing #{existing}, errors #{errors}.")
    if errors > 0, do: fail!("Some files failed to ingest.")
  end

  defp ingest_file(path, opts) do
    if opts[:dry_run] do
      with {:ok, hash} <- Sheaf.BlobStore.sha256(path),
           {:ok, existing_iri} <- Sheaf.Files.find_by_hash(hash) do
        {:ok, %{iri: existing_iri, hash: hash, created?: is_nil(existing_iri)}}
      end
    else
      Sheaf.Files.ingest(path)
    end
  end

  defp print_ingest_result(path, %{created?: created?, iri: iri} = result, opts) do
    status =
      cond do
        opts[:dry_run] && created? -> "would create"
        opts[:dry_run] -> "exists"
        created? -> "created"
        true -> "exists"
      end

    hash =
      case result do
        %{stored_file: %{hash: hash}} -> hash
        %{hash: hash} -> hash
        _ -> nil
      end

    iri = iri || "(new)"
    hash_info = if hash, do: " sha256:#{hash}", else: ""
    info("#{status} #{iri}#{hash_info} #{path}")
  end

  defp files(paths, opts) do
    extensions = extensions(opts)

    paths
    |> Enum.flat_map(&expand_path(&1, opts))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&hidden?/1)
    |> Enum.filter(&extension_match?(&1, extensions))
    |> Enum.sort()
  end

  defp expand_path(path, opts) do
    path = Path.expand(path)

    cond do
      File.dir?(path) && opts[:recursive] -> Path.wildcard(Path.join([path, "**", "*"]))
      File.dir?(path) -> Path.wildcard(Path.join(path, "*"))
      true -> Path.wildcard(path)
    end
  end

  defp extensions(opts) do
    case Keyword.get(opts, :extensions) do
      nil ->
        :all

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim_leading(&1, "."))
        |> Enum.map(&String.downcase/1)
        |> MapSet.new()
    end
  end

  defp extension_match?(_path, :all), do: true

  defp extension_match?(path, extensions) do
    extension = path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    MapSet.member?(extensions, extension)
  end

  defp hidden?(path), do: path |> Path.basename() |> String.starts_with?(".")
  defp maybe_put_document(opts, nil), do: opts
  defp maybe_put_document(opts, graph), do: Keyword.put(opts, :document, RDF.iri(graph))

  defp resolver_opts(opts) do
    []
    |> Keyword.put(:missing_only, missing_only?(opts))
    |> put_if_present(:limit, opts[:limit])
    |> put_if_present(:document, opts[:doc])
    |> put_if_present(:pdf_fallback, opts[:pdf_fallback])
    |> put_if_present(:pdf_pages, opts[:pdf_pages])
    |> put_if_present(:model, opts[:model])
    |> put_if_present(:receive_timeout, opts[:receive_timeout])
  end

  defp missing_only?(opts) do
    cond do
      opts[:all] -> false
      Keyword.has_key?(opts, :missing_only) -> opts[:missing_only]
      true -> true
    end
  end

  defp concurrency_by_kind(opts) do
    extract = opts[:extract_concurrency] || opts[:concurrency]

    %{}
    |> put_kind("metadata.extract_identifiers", extract)
    |> put_kind("metadata.resolve_document", extract)
    |> put_kind("metadata.crossref.lookup", opts[:lookup_concurrency])
    |> put_kind("metadata.match_candidate", opts[:match_concurrency])
    |> put_kind("metadata.import_crossref", opts[:import_concurrency])
  end

  defp put_kind(map, _kind, nil), do: map
  defp put_kind(map, kind, value), do: Map.put(map, kind, value)

  defp list_batches(opts) do
    case Sheaf.TaskQueue.list_batches(limit: opts[:limit] || 20) do
      {:ok, batches} ->
        Enum.each(batches, fn batch ->
          info(
            "#{short(batch.iri)} #{batch.queue}:#{batch.kind} #{batch.status} #{batch.completed_count}/#{batch.target_count} failed=#{batch.failed_count}"
          )
        end)

      {:error, reason} ->
        fail!("Failed to list batches: #{inspect(reason)}")
    end
  end

  defp list_tasks(opts) do
    queue_opts = [limit: opts[:limit] || 50]

    queue_opts =
      if opts[:status], do: Keyword.put(queue_opts, :status, opts[:status]), else: queue_opts

    case Sheaf.TaskQueue.list_tasks(queue_opts) do
      {:ok, tasks} ->
        Enum.each(tasks, fn task ->
          info(
            "##{task.id} #{task.kind} #{task.status} attempts=#{task.attempts}/#{task.max_attempts} #{short(task.subject_iri)} #{task.identifier || ""}"
          )
        end)

      {:error, reason} ->
        fail!("Failed to list tasks: #{inspect(reason)}")
    end
  end

  defp print_dry_run(candidates, resolver_opts) do
    info(
      "Would resolve #{length(candidates)} #{candidate_scope(resolver_opts)} documents from stored PDFs."
    )

    Enum.each(candidates, &info(candidate_line(&1)))
  end

  defp print_file_data(candidates, resolver_opts) do
    info(
      "File data for #{length(candidates)} #{candidate_scope(resolver_opts)} documents; no LLM requests, no RDF writes."
    )

    Enum.each(candidates, &info(file_data_line(&1)))
  end

  defp resolve_metadata!(candidates, resolver_opts) do
    info(
      "Resolving #{length(candidates)} #{candidate_scope(resolver_opts)} documents from stored PDFs."
    )

    results =
      candidates
      |> Enum.with_index(1)
      |> Enum.map(fn {candidate, index} ->
        info("[#{index}/#{length(candidates)}] #{candidate_line(candidate)}")

        case Sheaf.MetadataResolver.resolve(candidate, resolver_opts) do
          {:ok, result} ->
            print_metadata_result(result)
            {:ok, result}

          {:error, reason} ->
            error("ERROR #{short(candidate.document)}: #{inspect(reason)}")
            {:error, {candidate, reason}}
        end
      end)

    imported = Enum.count(results, &match?({:ok, %{wrote?: true}}, &1))
    no_doi = Enum.count(results, &match?({:ok, %{wrote?: false}}, &1))
    errors = Enum.count(results, &match?({:error, _}, &1))

    info("Done. Imported #{imported}, no DOI #{no_doi}, errors #{errors}.")
    if errors > 0, do: fail!("Some metadata resolutions failed.")
  end

  defp print_metadata_result(%{metadata: metadata, wrote?: true, crossref: crossref}) do
    info("  metadata #{metadata_line(metadata)}")
    info("  crossref #{crossref.doi} expression=#{short(crossref.expression)}")
  end

  defp print_metadata_result(%{metadata: metadata, wrote?: false}) do
    info("  metadata #{metadata_line(metadata)}")
    info("  no DOI; skipped RDF write")
  end

  defp candidate_scope(opts),
    do: if(Keyword.get(opts, :missing_only, true), do: "missing-metadata", else: "source-linked")

  defp candidate_line(candidate) do
    original = candidate.original_filename || Path.basename(candidate.path)

    [
      short(candidate.document),
      "file=#{short(candidate.file)}",
      "original=#{inspect(original)}",
      "path=#{candidate.path}"
    ]
    |> Enum.join(" ")
  end

  defp file_data_line(candidate) do
    [
      short(candidate.document),
      "file=#{short(candidate.file)}",
      "original=#{inspect(candidate.original_filename || Path.basename(candidate.path))}",
      field("mime", candidate.mime_type),
      field("bytes", candidate.byte_size),
      field("sha256", short_hash(candidate.sha256)),
      field("stored", date_time(candidate.generated_at)),
      field("pdf_title", pdf_title(candidate.path)),
      "path=#{candidate.path}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp metadata_line(metadata) do
    [
      field("title", metadata.title),
      field("doi", metadata.doi),
      field("authors", authors(metadata.authors)),
      field("year", metadata.year),
      field("publication", metadata.publication),
      field("confidence", metadata.confidence)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp field(_label, nil), do: nil
  defp field(_label, ""), do: nil
  defp field(label, value), do: "#{label}=#{inspect(value)}"
  defp short_hash(nil), do: nil
  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12)
  defp date_time(nil), do: nil
  defp date_time(%DateTime{} = date_time), do: DateTime.to_iso8601(date_time)
  defp date_time(value), do: to_string(value)

  defp pdf_title(path) do
    with executable when is_binary(executable) <- System.find_executable("pdfinfo"),
         {output, 0} <- System.cmd(executable, [path], stderr_to_stdout: true) do
      output
      |> String.split("\n")
      |> Enum.find_value(fn
        "Title:" <> title -> blank_to_nil(String.trim(title))
        _line -> nil
      end)
    else
      _ -> nil
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
  defp authors([]), do: nil
  defp authors(authors), do: Enum.join(authors, "; ")

  defp telegram_message(batch, opts) do
    scope =
      cond do
        opts[:document] -> "one document"
        opts[:limit] -> "up to #{opts[:limit]} document(s)"
        opts[:missing_only] -> "all documents missing Crossref metadata"
        true -> "all source-linked documents"
      end

    """
    Sheaf metadata batch queued

    Batch: #{short(batch.iri)}
    Scope: #{scope}
    Initial tasks: #{batch.target_count} identifier extraction task(s)

    Workflow:
    - extract DOI/ISBN from bounded front-matter text
    - optionally fall back to first PDF pages only
    - look up Crossref serially
    - import accepted matches into RDF serially
    """
    |> String.trim()
  end

  defp put_if_present(opts, _key, nil), do: opts
  defp put_if_present(opts, key, value), do: Keyword.put(opts, key, value)
  defp spreadsheet_db_opts(opts), do: put_if_present([], :db_path, opts[:db])
  defp put_kinds(opts, []), do: opts
  defp put_kinds(opts, kinds), do: Keyword.put(opts, :kinds, kinds)

  defp search_opts(opts) do
    []
    |> put_if_present(:db_path, Keyword.get(opts, :db))
    |> put_if_present(:limit, Keyword.get(opts, :limit))
    |> put_kinds(Keyword.get_values(opts, :kind))
  end

  defp embedding_sync_options do
    [
      db: :string,
      dimensions: :integer,
      concurrency: :integer,
      batch_size: :integer,
      limit: :integer,
      kind: :keep,
      provider: :string,
      model: :string,
      source: :string,
      profile: :string,
      api_mode: :string,
      batch_input: :string,
      poll_interval_ms: :integer,
      poll_timeout_ms: :integer,
      submit_only: :boolean,
      import_run: :string
    ]
  end

  defp embedding_opts(opts) do
    []
    |> put_if_present(:db_path, Keyword.get(opts, :db))
    |> put_if_present(:output_dimensionality, Keyword.get(opts, :dimensions))
    |> put_if_present(:max_concurrency, Keyword.get(opts, :concurrency))
    |> put_if_present(:batch_size, Keyword.get(opts, :batch_size))
    |> put_if_present(:limit, Keyword.get(opts, :limit))
    |> put_if_present(:provider, Keyword.get(opts, :provider))
    |> put_if_present(:model, Keyword.get(opts, :model))
    |> put_if_present(:source, Keyword.get(opts, :source))
    |> put_if_present(:profile, Keyword.get(opts, :profile))
    |> put_if_present(:api_mode, Keyword.get(opts, :api_mode))
    |> put_if_present(:batch_input, Keyword.get(opts, :batch_input))
    |> put_if_present(:poll_interval_ms, Keyword.get(opts, :poll_interval_ms))
    |> put_if_present(:poll_timeout_ms, Keyword.get(opts, :poll_timeout_ms))
    |> put_if_present(:submit_only, Keyword.get(opts, :submit_only))
    |> put_if_present(:import_run, Keyword.get(opts, :import_run))
    |> put_if_present(:sample, Keyword.get(opts, :sample))
    |> put_kinds(Keyword.get_values(opts, :kind))
  end

  defp kind_summary(kinds) when map_size(kinds) == 0, do: ""

  defp kind_summary(kinds) do
    kinds
    |> Enum.sort()
    |> Enum.map(fn {kind, count} -> "#{kind}=#{count}" end)
    |> Enum.join(" ")
    |> then(&(" " <> &1))
  end

  defp batch_summary(%{batch_name: batch_name}), do: " batch=#{batch_name}"
  defp batch_summary(_summary), do: ""

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: fail!("Unrecognized arguments: #{inspect(invalid)}")
  defp reject_positional!([]), do: :ok
  defp reject_positional!(args), do: fail!("Unexpected arguments: #{inspect(args)}")
  defp info(message), do: IO.puts(message)
  defp error(message), do: IO.puts(:stderr, message)
  defp fail!(message), do: raise(Sheaf.Admin.Error, message)

  defp short(nil), do: "(none)"

  defp short(iri) do
    iri
    |> to_string()
    |> String.replace_prefix("https://sheaf.less.rest/", "")
  end
end
