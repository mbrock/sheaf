defmodule Sheaf.DocumentImport do
  @moduledoc """
  Bounded, durable operations used by the document-import assistant tool.

  The model chooses actions; this module owns paths, network access, Datalab
  credentials, RDF mutations, and idempotency.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.Description
  alias Sheaf.{DatalabJobs, Files}
  alias Sheaf.NS.DOC

  @output_root "var/datalab"
  @poll_interval 5_000
  @default_timeout 15 * 60_000

  def dispatch(args, opts \\ [])

  def dispatch(%{"action" => action} = args, opts) do
    Tracer.with_span "Sheaf.DocumentImport.#{action}", %{
      kind: :internal,
      attributes: [
        {"sheaf.document_import.action", action},
        {"sheaf.document_import.run_id", Map.get(args, "run_id", "")},
        {"sheaf.document_import.url_count", length(List.wrap(args["urls"]))},
        {"sheaf.document_import.file_count",
         length(List.wrap(args["file_ids"]))}
      ]
    } do
      case action do
        "stage" -> stage(args, opts)
        "status" -> status(args)
        "extract" -> extract(args, opts)
        "inspect" -> inspect_run(args)
        "import" -> import_run(args, opts)
        "metadata" -> resolve_metadata(args, opts)
        "validate" -> validate(args, opts)
        _ -> {:error, {:unknown_action, action}}
      end
    end
  end

  def dispatch(_args, _opts), do: {:error, :missing_action}

  def stage(args, opts \\ []) do
    urls = args |> Map.get("urls", []) |> List.wrap() |> Enum.uniq()
    file_ids = args |> Map.get("file_ids", []) |> List.wrap() |> Enum.uniq()

    with {:ok, downloaded} <- stage_urls(urls, opts),
         source_files =
           (Enum.map(downloaded, & &1.file_iri) ++
              Enum.map(file_ids, &Sheaf.Id.iri/1))
           |> Enum.uniq(),
         :ok <- require_sources(source_files),
         {:ok, job} <-
           DatalabJobs.create_job(source_files,
             name: Map.get(args, "name", "Agent document import"),
             output_format: "json"
           ) do
      {:ok,
       %{
         action: "stage",
         run_id: Sheaf.Id.id_from_iri(job.iri),
         run_iri: to_string(job.iri),
         sources: Enum.map(downloaded, &Map.drop(&1, [:file_iri])),
         file_ids: Enum.map(source_files, &Sheaf.Id.id_from_iri/1),
         status: summarize(job)
       }}
    end
  end

  def status(%{"run_id" => run_id}) do
    with {:ok, job} <- DatalabJobs.get_job(run_iri(run_id)) do
      {:ok, %{action: "status", run_id: run_id, status: summarize(job)}}
    end
  end

  def status(_args), do: {:error, :run_id_required}

  def extract(args, opts \\ [])

  def extract(%{"run_id" => run_id}, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    notify = Keyword.get(opts, :notify, fn _message -> :ok end)

    with {:ok, job} <- DatalabJobs.get_job(run_iri(run_id)),
         {:ok, submitted} <- submit_pending(job, notify),
         {:ok, completed} <- await_extraction(job.iri, timeout, notify) do
      {:ok,
       %{
         action: "extract",
         run_id: run_id,
         submitted: submitted,
         completed: completed,
         status: summarize_job(job.iri)
       }}
    end
  end

  def extract(_args, _opts), do: {:error, :run_id_required}

  def inspect_run(%{"run_id" => run_id}) do
    with {:ok, job} <- DatalabJobs.get_job(run_iri(run_id)) do
      reports =
        Enum.map(job.file_jobs, fn file_job ->
          %{
            file_id: source_id(file_job),
            status: file_job.status,
            output_path: file_job.output_path,
            quality: quality_report(file_job.output_path)
          }
        end)

      {:ok,
       %{
         action: "inspect",
         run_id: run_id,
         files: reports,
         status: summarize(job)
       }}
    end
  end

  def inspect_run(_args), do: {:error, :run_id_required}

  def import_run(args, opts \\ [])

  def import_run(%{"run_id" => run_id}, opts) do
    notify = Keyword.get(opts, :notify, fn _message -> :ok end)

    with {:ok, job} <- DatalabJobs.get_job(run_iri(run_id)),
         {:ok, imported_sources} <- imported_source_documents() do
      {results, _imported_sources} =
        job.file_jobs
        |> Enum.with_index(1)
        |> Enum.map_reduce(imported_sources, fn {file_job, index},
                                                imported_sources ->
          notify.(
            "Importing document #{index}/#{length(job.file_jobs)} · #{source_id(file_job)}"
          )

          result = import_file_job(file_job, imported_sources)

          imported_sources =
            case result do
              %{document_iri: document_iri} ->
                Map.put(
                  imported_sources,
                  file_job.source_file,
                  RDF.iri(document_iri)
                )

              _other ->
                imported_sources
            end

          {result, imported_sources}
        end)

      errors = Enum.filter(results, &Map.has_key?(&1, :error))

      if errors == [] do
        :ok = Sheaf.SearchIndexWorker.enqueue("PDF import #{run_id}")

        {:ok,
         %{
           action: "import",
           run_id: run_id,
           documents: results,
           next:
             "Resolve metadata and validate reader pages. Search indexing is continuing in the background."
         }}
      else
        {:error, {:import_failed, results}}
      end
    end
  end

  def import_run(_args, _opts), do: {:error, :run_id_required}

  def resolve_metadata(args, opts \\ [])

  def resolve_metadata(%{"run_id" => run_id}, opts) do
    notify = Keyword.get(opts, :notify, fn _message -> :ok end)

    with {:ok, job} <- DatalabJobs.get_job(run_iri(run_id)),
         {:ok, documents} <- documents_for_job(job) do
      results =
        documents
        |> Enum.with_index(1)
        |> Enum.map(fn {document, index} ->
          document_id = Sheaf.Id.id_from_iri(document)

          notify.(
            "Resolving metadata #{index}/#{length(documents)} · #{document_id}"
          )

          result =
            with {:ok, [candidate]} <-
                   Sheaf.MetadataResolver.candidates(
                     document: document,
                     missing_only: true
                   ),
                 {:ok, result} <-
                   Sheaf.MetadataResolver.resolve(candidate,
                     pdf_fallback: true,
                     llm_options: Keyword.get(opts, :llm_options, [])
                   ) do
              %{
                document_id: document_id,
                wrote: result.wrote?,
                metadata: Map.from_struct(result.metadata),
                match: Map.get(result, :match)
              }
            else
              {:ok, []} ->
                %{
                  document_id: document_id,
                  status: "already_resolved"
                }

              {:error, reason} ->
                %{
                  document_id: document_id,
                  error: inspect(reason)
                }

              other ->
                %{
                  document_id: document_id,
                  error: inspect(other)
                }
            end

          notify.(metadata_result_message(result, index, length(documents)))
          result
        end)

      :ok =
        Sheaf.SearchIndexWorker.enqueue(
          "Metadata resolved for import #{run_id}"
        )

      {:ok, %{action: "metadata", run_id: run_id, documents: results}}
    end
  end

  def resolve_metadata(_args, _opts), do: {:error, :run_id_required}

  def validate(args, opts \\ [])

  def validate(%{"run_id" => run_id}, opts) do
    notify = Keyword.get(opts, :notify, fn _message -> :ok end)
    notify.("Checking imported reader pages")

    with {:ok, job} <- DatalabJobs.get_job(run_iri(run_id)),
         {:ok, documents} <- documents_for_job(job) do
      checks = Enum.map(documents, &validate_document/1)

      :ok =
        Sheaf.SearchIndexWorker.enqueue("Validation of PDF import #{run_id}")

      search_status = Sheaf.SearchIndexWorker.status()

      {:ok,
       %{
         action: "validate",
         run_id: run_id,
         documents: checks,
         search_index_status: search_status.phase,
         search_index_message: search_status.message,
         embedding_status:
           if(search_status.running?, do: "updating", else: "queued"),
         embedding_errors: 0
       }}
    end
  end

  def validate(_args, _opts), do: {:error, :run_id_required}

  defp stage_urls(urls, opts) do
    Enum.reduce_while(urls, {:ok, []}, fn url, {:ok, staged} ->
      case stage_url(url, opts) do
        {:ok, source} -> {:cont, {:ok, [source | staged]}}
        {:error, reason} -> {:halt, {:error, {:download_failed, url, reason}}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      error -> error
    end
  end

  defp stage_url(url, opts) do
    with {:ok, download} <- Sheaf.SafeFetch.download_pdf(url, opts) do
      try do
        with {:ok, stored} <-
               Files.ingest(download.path,
                 filename: download.filename,
                 mime_type: "application/pdf"
               ),
             :ok <- record_source_url(stored.iri, download.url) do
          {:ok,
           %{
             file_iri: stored.iri,
             file_id: Sheaf.Id.id_from_iri(stored.iri),
             filename: download.filename,
             url: download.url,
             byte_size: download.byte_size,
             created: stored.created?
           }}
        end
      after
        File.rm(download.path)
      end
    end
  end

  defp record_source_url(file_iri, url) do
    Sheaf.Repo.assert(
      "record import source URL",
      RDF.Graph.new(
        [
          {file_iri, RDF.iri("http://purl.org/dc/terms/source"), RDF.iri(url)}
        ],
        name: file_iri
      )
    )
  end

  defp require_sources([]), do: {:error, :sources_required}

  defp require_sources(source_files) do
    with {:ok, graph} <- Files.list_graph() do
      missing =
        Enum.reject(source_files, fn iri ->
          description = RDF.Graph.description(graph, iri)

          file? =
            Description.include?(
              description,
              {RDF.type(), Sheaf.NS.FABIO.ComputerFile}
            )

          pdf? =
            case Description.first(description, DOC.mimeType()) do
              nil -> false
              mime -> RDF.Term.value(mime) == "application/pdf"
            end

          file? and pdf?
        end)

      if missing == [],
        do: :ok,
        else:
          {:error,
           {:unknown_file_ids, Enum.map(missing, &Sheaf.Id.id_from_iri/1)}}
    end
  end

  defp submit_pending(job, notify) do
    job
    |> DatalabJobs.pending_file_jobs()
    |> Enum.reduce_while({:ok, 0}, fn file_job, {:ok, count} ->
      notify.("Submitting #{source_id(file_job)} to Datalab")

      with {:ok, path} <- source_path(file_job.source_file),
           {:ok, %{"execution_id" => execution_id}} <-
             Datalab.start_job(path, output_format: "json"),
           {:ok, _updated} <-
             DatalabJobs.update_file_job(job.iri, file_job.source_file,
               execution_id: execution_id,
               submitted_at: now()
             ) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp await_extraction(job_iri, timeout, notify) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_extraction_loop(job_iri, deadline, notify)
  end

  defp await_extraction_loop(job_iri, deadline, notify) do
    with {:ok, job} <- DatalabJobs.get_job(job_iri),
         {:ok, completed_now} <- poll_submitted(job, notify),
         {:ok, refreshed} <- DatalabJobs.get_job(job_iri) do
      notify.(extraction_progress_message(refreshed))

      cond do
        Enum.any?(refreshed.file_jobs, &DatalabJobs.failed?/1) ->
          {:error, {:datalab_failed, summarize(refreshed)}}

        DatalabJobs.submitted_file_jobs(refreshed) == [] ->
          {:ok, completed_now}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, {:extraction_timeout, summarize(refreshed)}}

        true ->
          receive do
          after
            @poll_interval -> await_extraction_loop(job_iri, deadline, notify)
          end
      end
    end
  end

  defp poll_submitted(job, notify) do
    Enum.reduce_while(
      DatalabJobs.submitted_file_jobs(job),
      {:ok, 0},
      fn file_job, {:ok, count} ->
        with {:ok, body} <- Datalab.check_job(file_job.execution_id),
             {:ok, status} <- Datalab.status(body) do
          cond do
            Datalab.complete_status?(status) ->
              notify.("Saving extracted document #{source_id(file_job)}")

              case complete_file_job(job, file_job) do
                :ok -> {:cont, {:ok, count + 1}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            Datalab.failed_status?(status) ->
              DatalabJobs.update_file_job(job.iri, file_job.source_file,
                error: inspect(body),
                failed_at: now()
              )

              {:halt, {:error, {:datalab_failed, file_job.execution_id}}}

            true ->
              {:cont, {:ok, count}}
          end
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp complete_file_job(job, file_job) do
    with {:ok, body} <- Datalab.result(file_job.execution_id),
         {:ok, output} <- Datalab.output(body, "json"),
         {:ok, path} <- write_output(job.iri, file_job, output),
         {:ok, _updated} <-
           DatalabJobs.update_file_job(job.iri, file_job.source_file,
             output_path: path,
             completed_at: now()
           ) do
      :ok
    end
  end

  defp write_output(job_iri, file_job, output) do
    directory = Path.join(@output_root, Sheaf.Id.id_from_iri(job_iri))
    path = Path.join(directory, "#{source_id(file_job)}.datalab.json")

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(path, Jason.encode!(output)) do
      {:ok, Path.expand(path)}
    end
  end

  defp import_file_job(file_job, imported_sources) do
    cond do
      document = Map.get(imported_sources, file_job.source_file) ->
        %{
          file_id: source_id(file_job),
          status: "already_imported",
          document_id: Sheaf.Id.id_from_iri(document),
          document_iri: to_string(document)
        }

      not DatalabJobs.completed?(file_job) ->
        %{file_id: source_id(file_job), error: "extraction_not_completed"}

      true ->
        case Sheaf.PDF.import_file(file_job.output_path,
               source_file_iri: file_job.source_file
             ) do
          {:ok, result} ->
            %{
              file_id: source_id(file_job),
              status: "imported",
              document_id: Sheaf.Id.id_from_iri(result.document),
              document_iri: to_string(result.document),
              title: result.title
            }

          {:error, reason} ->
            %{file_id: source_id(file_job), error: inspect(reason)}
        end
    end
  end

  defp quality_report(path) when is_binary(path) do
    with true <- File.exists?(path),
         {:ok, document} <- Datalab.Document.read_file(path) do
      Datalab.Document.quality_report(document)
    else
      _ -> nil
    end
  end

  defp quality_report(_path), do: nil

  defp imported_source_documents do
    with {:ok, rows} <-
           Sheaf.Repo.match_rows({nil, DOC.sourceFile(), nil, nil}) do
      {:ok,
       Map.new(rows, fn {_graph, document, _predicate, file} ->
         {file, document}
       end)}
    end
  end

  defp documents_for_job(job) do
    sources = Enum.map(job.file_jobs, & &1.source_file)

    with {:ok, rows} <-
           Sheaf.Repo.match_rows({nil, DOC.sourceFile(), sources, nil}) do
      {:ok,
       rows
       |> Enum.map(fn {_g, document, _p, _file} -> document end)
       |> Enum.uniq()}
    end
  end

  defp validate_document(document) do
    case Sheaf.fetch_graph(document) do
      {:ok, graph} ->
        chunks = Sheaf.Document.text_chunks(graph, document)

        %{
          document_id: Sheaf.Id.id_from_iri(document),
          title: Sheaf.Document.title(graph, document),
          readable_chunks: length(chunks),
          source_pages:
            chunks
            |> Enum.map(& &1.source_page)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> length(),
          reader_path: "/#{Sheaf.Id.id_from_iri(document)}",
          valid: chunks != []
        }

      {:error, reason} ->
        %{
          document_id: Sheaf.Id.id_from_iri(document),
          valid: false,
          error: inspect(reason)
        }
    end
  end

  defp source_path(file_iri) do
    with {:ok, graph} <- Files.list_graph() do
      graph |> RDF.Graph.description(file_iri) |> Files.local_path()
    end
  end

  defp metadata_result_message(%{error: _error}, index, total),
    do: "Metadata resolution #{index}/#{total} finished with an error"

  defp metadata_result_message(%{status: "already_resolved"}, index, total),
    do: "Metadata #{index}/#{total} was already complete"

  defp metadata_result_message(_result, index, total),
    do: "Resolved metadata #{index}/#{total}"

  defp extraction_progress_message(job) do
    completed = Enum.count(job.file_jobs, &DatalabJobs.completed?/1)
    total = length(job.file_jobs)
    "Extracting PDFs with Datalab · #{completed}/#{total} complete"
  end

  defp summarize_job(job_iri) do
    case DatalabJobs.get_job(job_iri) do
      {:ok, job} -> summarize(job)
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp summarize(job) do
    files =
      Enum.map(job.file_jobs, fn file_job ->
        %{
          file_id: source_id(file_job),
          execution_id: file_job.execution_id,
          status: file_job.status,
          error: file_job.error
        }
      end)

    %{counts: Enum.frequencies_by(files, & &1.status), files: files}
  end

  defp source_id(%{source_file: source_file}),
    do: Sheaf.Id.id_from_iri(source_file)

  defp run_iri(run_id), do: Sheaf.Id.iri(run_id)
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
