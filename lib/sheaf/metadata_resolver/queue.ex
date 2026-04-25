defmodule Sheaf.MetadataResolver.Queue do
  @moduledoc """
  Queue adapter for bibliographic metadata resolution.
  """

  @queue "metadata"
  @kind "metadata.resolve"
  @task_kind "metadata.resolve_document"

  @spec enqueue(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue(opts \\ []) do
    with {:ok, candidates} <- Sheaf.MetadataResolver.candidates(opts) do
      tasks = Enum.map(candidates, &task_from_candidate/1)

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
    started = %{processed: 0, imported: 0, skipped: 0, errors: 0}

    if notify?, do: Sheaf.Telegram.notify("Sheaf metadata queue: starting #{limit} task(s)")

    result =
      Enum.reduce_while(1..limit, started, fn _index, acc ->
        case Sheaf.TaskQueue.claim_task(queue: @queue) do
          {:ok, nil} ->
            {:halt, acc}

          {:ok, task} ->
            case process_task(task, opts) do
              {:ok, task_result} ->
                acc =
                  acc
                  |> Map.update!(:processed, &(&1 + 1))
                  |> count_result(task_result)

                {:cont, acc}

              {:error, _reason} ->
                {:cont,
                 acc |> Map.update!(:processed, &(&1 + 1)) |> Map.update!(:errors, &(&1 + 1))}
            end

          {:error, reason} ->
            {:halt, Map.put(acc, :queue_error, reason)}
        end
      end)

    if notify? do
      Sheaf.Telegram.notify(
        "Sheaf metadata queue: processed #{result.processed}, imported #{result.imported}, skipped #{result.skipped}, errors #{result.errors}"
      )
    end

    {:ok, result}
  end

  defp process_task(%{kind: @task_kind} = task, opts) do
    case Sheaf.MetadataResolver.resolve_task(task.input, opts) do
      {:ok, result} ->
        payload = result_payload(result)
        :ok = Sheaf.TaskQueue.complete_task(task.id, payload)
        {:ok, payload}

      {:error, reason} ->
        :ok = Sheaf.TaskQueue.fail_task(task.id, reason)
        {:error, reason}
    end
  end

  defp process_task(task, _opts) do
    reason = {:unknown_task_kind, task.kind}
    :ok = Sheaf.TaskQueue.fail_task(task.id, reason)
    {:error, reason}
  end

  defp task_from_candidate(candidate) do
    document = to_string(candidate.document)

    %{
      kind: @task_kind,
      subject_iri: document,
      identifier: short_iri(document),
      unique_key: "#{@task_kind}:#{document}",
      input: %{
        document: document,
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

  defp crossref_payload(nil), do: nil

  defp crossref_payload(crossref) do
    %{
      doi: crossref.doi,
      expression: crossref.expression && to_string(crossref.expression),
      work: crossref.work && to_string(crossref.work),
      graph: crossref.graph
    }
  end

  defp count_result(acc, %{wrote: true}), do: Map.update!(acc, :imported, &(&1 + 1))
  defp count_result(acc, _result), do: Map.update!(acc, :skipped, &(&1 + 1))

  defp short_iri(iri), do: String.replace_prefix(to_string(iri), "https://sheaf.less.rest/", "")
end
