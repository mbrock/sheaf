defmodule Sheaf.MetadataResolver.Queue do
  @moduledoc """
  Queue adapter for bibliographic metadata resolution.

  The workflow is split into explicit task kinds so each phase can have its own
  concurrency:

  * `metadata.extract_identifiers` uses Gemini over bounded document text.
  * `metadata.crossref.lookup` calls Crossref and is serial by default.
  * `metadata.match_candidate` is local matching.
  * `metadata.import_crossref` performs the RDF write and is serial by default.
  """

  @queue "metadata"
  @kind "metadata.resolve"
  @legacy_resolve_kind "metadata.resolve_document"
  @extract_kind "metadata.extract_identifiers"
  @lookup_kind "metadata.crossref.lookup"
  @match_kind "metadata.match_candidate"
  @import_kind "metadata.import_crossref"

  @default_concurrency %{
    @legacy_resolve_kind => 32,
    @extract_kind => 32,
    @lookup_kind => 1,
    @match_kind => 8,
    @import_kind => 1
  }

  @spec enqueue(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(opts \\ []) do
    with {:ok, candidates} <- Sheaf.MetadataResolver.candidates(opts) do
      tasks = Enum.map(candidates, &extract_task_from_candidate/1)

      Sheaf.TaskQueue.create_batch(
        %{
          iri: Keyword.get_lazy(opts, :batch_iri, &Sheaf.mint/0) |> to_string(),
          queue: @queue,
          kind: @kind,
          input: %{
            "missing_only" => Keyword.get(opts, :missing_only, true),
            "limit" => Keyword.get(opts, :limit),
            "document" => Keyword.get(opts, :document)
          }
        },
        tasks,
        opts
      )
    end
  end

  @spec work(keyword()) :: {:ok, map()} | {:error, term()}
  def work(opts \\ []) do
    limit = Keyword.get(opts, :limit, 1)
    notify? = Keyword.get(opts, :telegram, false)
    started = %{processed: 0, imported: 0, skipped: 0, errors: 0, phases: %{}}

    if notify? do
      Sheaf.Telegram.notify(start_message(limit, opts))
    end

    result = work_until_limit(limit, opts, started)

    if notify? do
      Sheaf.Telegram.notify(finish_message(result))
    end

    {:ok, result}
  end

  defp work_until_limit(remaining, _opts, acc) when remaining <= 0, do: acc

  defp work_until_limit(remaining, opts, acc) do
    result =
      remaining
      |> claim_tasks()
      |> process_claimed_tasks(opts, acc)

    processed_now = result.processed - acc.processed

    cond do
      Map.has_key?(result, :queue_error) -> result
      processed_now <= 0 -> result
      true -> work_until_limit(remaining - processed_now, opts, result)
    end
  end

  defp claim_tasks(limit) do
    1..limit
    |> Enum.reduce_while([], fn _index, tasks ->
      case Sheaf.TaskQueue.claim_task(queue: @queue) do
        {:ok, nil} -> {:halt, Enum.reverse(tasks)}
        {:ok, task} -> {:cont, [task | tasks]}
        {:error, reason} -> {:halt, [%{queue_error: reason} | tasks] |> Enum.reverse()}
      end
    end)
  end

  defp process_claimed_tasks([%{queue_error: reason}], _opts, acc),
    do: Map.put(acc, :queue_error, reason)

  defp process_claimed_tasks(tasks, opts, acc) do
    tasks
    |> Enum.group_by(& &1.kind)
    |> Enum.sort_by(fn {kind, _tasks} -> kind_order(kind) end)
    |> Enum.reduce(acc, fn {kind, kind_tasks}, acc ->
      process_kind_tasks(kind, kind_tasks, opts, acc)
    end)
  end

  defp process_kind_tasks(kind, tasks, opts, acc) do
    tasks
    |> Task.async_stream(&process_task(&1, opts),
      max_concurrency: concurrency_for(kind, opts),
      timeout: Keyword.get(opts, :task_timeout, 300_000),
      on_timeout: :kill_task
    )
    |> Enum.zip(tasks)
    |> Enum.reduce(acc, fn {async_result, task}, acc ->
      case async_result do
        {:ok, {:ok, payload}} ->
          acc
          |> count_phase(kind, :processed)
          |> Map.update!(:processed, &(&1 + 1))
          |> count_result(payload)

        {:ok, {:error, reason}} ->
          fail_processed_task(task, reason, acc)

        {:exit, reason} ->
          fail_processed_task(task, reason, acc)
      end
    end)
  end

  defp process_task(%{kind: kind} = task, opts)
       when kind in [@extract_kind, @legacy_resolve_kind] do
    candidate = candidate_from_input(task.input)

    with {:ok, metadata} <- Sheaf.MetadataResolver.extract_candidate_metadata(candidate, opts),
         payload = extraction_payload(candidate, metadata),
         :ok <- Sheaf.TaskQueue.complete_task(task.id, payload),
         :ok <- enqueue_lookup_if_needed(task, payload) do
      {:ok, payload}
    end
  end

  defp process_task(%{kind: @lookup_kind} = task, opts) do
    metadata = metadata_from_input(task.input)

    with {:ok, lookup} <- Sheaf.MetadataResolver.lookup_identifier(metadata, opts),
         payload = lookup_payload(task.input, lookup),
         :ok <- Sheaf.TaskQueue.complete_task(task.id, payload),
         :ok <- enqueue_match_if_needed(task, payload) do
      {:ok, payload}
    end
  end

  defp process_task(%{kind: @match_kind} = task, _opts) do
    metadata = metadata_from_input(task.input)
    lookup = lookup_from_input(task.input)

    with {:ok, match} <- Sheaf.MetadataResolver.match_lookup(metadata, lookup),
         payload = match_payload(task.input, match),
         :ok <- Sheaf.TaskQueue.complete_task(task.id, payload),
         :ok <- enqueue_import_if_needed(task, payload) do
      {:ok, payload}
    end
  end

  defp process_task(%{kind: @import_kind} = task, opts) do
    candidate = candidate_from_input(task.input)
    metadata = metadata_from_input(task.input)
    match = match_from_input(task.input)

    with {:ok, result} <- Sheaf.MetadataResolver.import_match(candidate, metadata, match, opts),
         payload = result_payload(result),
         :ok <- Sheaf.TaskQueue.complete_task(task.id, payload) do
      {:ok, payload}
    end
  end

  defp process_task(task, _opts) do
    reason = {:unknown_task_kind, task.kind}
    _ = Sheaf.TaskQueue.fail_task(task.id, reason)
    {:error, reason}
  end

  defp enqueue_lookup_if_needed(_task, %{doi: nil, isbn: nil}), do: :ok

  defp enqueue_lookup_if_needed(task, payload) do
    enqueue_next(task, @lookup_kind, payload, payload.identifier)
  end

  defp enqueue_match_if_needed(_task, %{lookup: %{source: "none"}}), do: :ok

  defp enqueue_match_if_needed(task, payload),
    do: enqueue_next(task, @match_kind, payload, payload.identifier)

  defp enqueue_import_if_needed(_task, %{match: %{accept?: false}}), do: :ok

  defp enqueue_import_if_needed(task, payload),
    do: enqueue_next(task, @import_kind, payload, payload.identifier)

  defp enqueue_next(task, kind, input, identifier) do
    with {:ok, _task} <-
           Sheaf.TaskQueue.create_task(
             task.batch_iri,
             %{queue: @queue},
             %{
               kind: kind,
               subject_iri: document_from_payload(input),
               identifier: identifier,
               unique_key: "#{kind}:#{document_from_payload(input)}:#{identifier}",
               input: input
             }
           ) do
      :ok
    end
  end

  defp extract_task_from_candidate(candidate) do
    document = to_string(candidate.document)

    %{
      kind: @extract_kind,
      subject_iri: document,
      identifier: short_iri(document),
      unique_key: "#{@extract_kind}:#{document}",
      input: candidate_payload(candidate)
    }
  end

  defp candidate_payload(candidate) do
    %{
      candidate: %{
        document: to_string(candidate.document),
        file: candidate.file && to_string(candidate.file),
        path: candidate.path,
        label: candidate.label,
        original_filename: candidate.original_filename,
        mime_type: candidate.mime_type,
        byte_size: candidate.byte_size,
        sha256: candidate.sha256
      }
    }
  end

  defp extraction_payload(candidate, metadata) do
    candidate
    |> candidate_payload()
    |> Map.merge(%{
      identifier: metadata.doi || metadata.isbn,
      doi: metadata.doi,
      isbn: metadata.isbn,
      metadata: metadata_payload(metadata)
    })
  end

  defp lookup_payload(input, lookup) do
    input
    |> base_payload()
    |> Map.merge(%{
      identifier: lookup.identifier,
      lookup: lookup_payload_map(lookup)
    })
  end

  defp match_payload(input, match) do
    input
    |> base_payload()
    |> Map.merge(%{
      identifier: input_value(input, :identifier) || match.identifier,
      match: match_payload_map(match)
    })
  end

  defp result_payload(result) do
    %{
      wrote: result.wrote?,
      document: to_string(result.candidate.document),
      title: result.metadata.title,
      authors: result.metadata.authors,
      doi: result.metadata.doi,
      isbn: result.metadata.isbn,
      match: result[:match] || %{},
      crossref: crossref_payload(result[:crossref])
    }
  end

  defp base_payload(input) do
    %{
      candidate: input_value(input, :candidate),
      metadata: input_value(input, :metadata),
      doi: input_value(input, :doi),
      isbn: input_value(input, :isbn)
    }
  end

  defp metadata_payload(metadata) do
    %{
      title: metadata.title,
      authors: metadata.authors,
      doi: metadata.doi,
      isbn: metadata.isbn,
      year: metadata.year,
      publication: metadata.publication,
      volume: metadata.volume,
      issue: metadata.issue,
      pages: metadata.pages,
      confidence: metadata.confidence,
      notes: metadata.notes,
      model: metadata.model,
      source_filename: metadata.source_filename,
      usage: metadata.usage
    }
  end

  defp lookup_payload_map(%{source: "doi", identifier: identifier, work: work}) do
    %{source: "doi", identifier: identifier, work: work}
  end

  defp lookup_payload_map(%{source: "isbn", identifier: identifier, works: works}) do
    %{source: "isbn", identifier: identifier, works: works}
  end

  defp lookup_payload_map(lookup), do: lookup

  defp match_payload_map(match) do
    match
    |> Map.delete(:work)
    |> Map.put(:work, Map.get(match, :work))
  end

  defp crossref_payload(nil), do: nil

  defp crossref_payload(crossref) do
    %{
      doi: crossref.doi,
      expression: crossref.expression && to_string(crossref.expression),
      work: crossref.work && to_string(crossref.work),
      graph: crossref.graph
    }
  end

  defp candidate_from_input(input) do
    candidate = input_value(input, :candidate) || input
    Sheaf.MetadataResolver.task_candidate(candidate)
  end

  defp metadata_from_input(input) do
    input
    |> input_value(:metadata)
    |> Sheaf.PaperMetadata.normalize_object()
  end

  defp lookup_from_input(input) do
    lookup = input_value(input, :lookup) || %{}

    case input_value(lookup, :source) do
      "doi" ->
        %{
          source: "doi",
          identifier: input_value(lookup, :identifier),
          work: input_value(lookup, :work)
        }

      "isbn" ->
        %{
          source: "isbn",
          identifier: input_value(lookup, :identifier),
          works: input_value(lookup, :works) || []
        }

      _ ->
        %{source: "none", reason: input_value(lookup, :reason)}
    end
  end

  defp match_from_input(input) do
    match = input_value(input, :match) || %{}

    %{
      accept?: input_value(match, :accept?) || input_value(match, :accept) || false,
      score: input_value(match, :score) || 0.0,
      source: input_value(match, :source),
      identifier: input_value(match, :identifier),
      doi: input_value(match, :doi),
      crossref_type: input_value(match, :crossref_type),
      crossref_title: input_value(match, :crossref_title),
      reason: input_value(match, :reason),
      work: input_value(match, :work)
    }
  end

  defp input_value(nil, _key), do: nil

  defp input_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp document_from_payload(payload) do
    payload
    |> input_value(:candidate)
    |> input_value(:document)
  end

  defp count_result(acc, %{wrote: true}), do: Map.update!(acc, :imported, &(&1 + 1))
  defp count_result(acc, %{match: %{accept?: false}}), do: Map.update!(acc, :skipped, &(&1 + 1))
  defp count_result(acc, %{doi: nil, isbn: nil}), do: Map.update!(acc, :skipped, &(&1 + 1))
  defp count_result(acc, _result), do: acc

  defp fail_processed_task(task, reason, acc) do
    :ok = Sheaf.TaskQueue.fail_task(task.id, reason)

    acc
    |> count_phase(task.kind, :errors)
    |> Map.update!(:processed, &(&1 + 1))
    |> Map.update!(:errors, &(&1 + 1))
  end

  defp count_phase(acc, kind, field) do
    update_in(acc, [:phases, phase_label(kind)], fn phase ->
      (phase || %{processed: 0, errors: 0})
      |> Map.update!(field, &(&1 + 1))
    end)
  end

  defp concurrency_for(kind, opts) do
    overrides = Keyword.get(opts, :concurrency_by_kind, %{})
    override = Map.get(overrides, kind) || Map.get(overrides, phase_label(kind))
    max(override || Map.fetch!(@default_concurrency, kind), 1)
  end

  defp kind_order(@extract_kind), do: 1
  defp kind_order(@legacy_resolve_kind), do: 1
  defp kind_order(@lookup_kind), do: 2
  defp kind_order(@match_kind), do: 3
  defp kind_order(@import_kind), do: 4
  defp kind_order(_kind), do: 99

  defp short_iri(iri), do: String.replace_prefix(to_string(iri), "https://sheaf.less.rest/", "")

  defp start_message(limit, opts) do
    pdf =
      if Keyword.get(opts, :pdf_fallback, false) do
        "PDF fallback: on, first #{Keyword.get(opts, :pdf_pages, 3)} page(s) only"
      else
        "PDF fallback: off"
      end

    """
    Sheaf metadata worker starting

    Scope: up to #{limit} queued task(s)
    Extraction: text first, front matter only, no last pages, DOI + ISBN
    #{pdf}

    Concurrency:
    - Gemini extraction: #{concurrency_for(@extract_kind, opts)}
    - Crossref lookup: #{concurrency_for(@lookup_kind, opts)}
    - local matching: #{concurrency_for(@match_kind, opts)}
    - RDF import: #{concurrency_for(@import_kind, opts)}
    """
    |> String.trim()
  end

  defp finish_message(result) do
    """
    Sheaf metadata worker finished

    Processed: #{result.processed}
    Imported: #{result.imported}
    Skipped: #{result.skipped}
    Errors: #{result.errors}

    Phases:
    #{phase_summary(result.phases)}
    """
    |> String.trim()
  end

  defp phase_summary(phases) when map_size(phases) == 0, do: "- none"

  defp phase_summary(phases) do
    phases
    |> Enum.sort_by(fn {phase, _counts} -> phase_order(phase) end)
    |> Enum.map_join("\n", fn {phase, counts} ->
      "- #{phase}: #{counts.processed} processed, #{counts.errors} errors"
    end)
  end

  defp phase_label(@legacy_resolve_kind), do: "extract identifiers"
  defp phase_label(@extract_kind), do: "extract identifiers"
  defp phase_label(@lookup_kind), do: "crossref lookup"
  defp phase_label(@match_kind), do: "match candidates"
  defp phase_label(@import_kind), do: "rdf import"
  defp phase_label(kind), do: kind

  defp phase_order("extract identifiers"), do: 1
  defp phase_order("crossref lookup"), do: 2
  defp phase_order("match candidates"), do: 3
  defp phase_order("rdf import"), do: 4
  defp phase_order(_phase), do: 99
end
