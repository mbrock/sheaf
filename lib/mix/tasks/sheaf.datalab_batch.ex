defmodule Mix.Tasks.Sheaf.DatalabBatch do
  @moduledoc """
  Submits and polls Datalab conversions with state stored in the Sheaf jobs graph.
  """

  use Mix.Task

  alias RDF.Description
  alias Sheaf.{DatalabJobs, Files}
  alias Sheaf.NS.DOC

  @shortdoc "Manages RDF-backed Datalab batch jobs"
  @default_output_dir "var/datalab"
  @default_await_interval 5_000
  @execution_page_size 100

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {command, args} = command(args)

    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [
          job: :string,
          name: :string,
          limit: :integer,
          output_dir: :string,
          output_format: :string,
          await: :boolean,
          await_interval: :integer
        ]
      )

    cond do
      invalid != [] ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")

      command == "submit" ->
        submit(opts)

      command == "poll" ->
        poll(opts)

      command == "status" ->
        status(opts)

      true ->
        Mix.raise(
          "Usage: mix sheaf.datalab_batch {submit|poll|status} [--job IRI] [--limit N] [--await]"
        )
    end
  end

  defp command([command | rest]) when command in ~w(submit poll status), do: {command, rest}
  defp command(args), do: {"status", args}

  defp submit(opts) do
    job = get_or_create_job(opts)
    pending = DatalabJobs.pending_file_jobs(job)

    Mix.shell().info("Submitting #{length(pending)} files for #{job.iri}")

    pending
    |> Enum.reduce(%{submitted: 0, errors: 0}, fn file_job, stats ->
      file = file_description(file_job.source_file)

      with {:ok, path} <- Files.local_path(file),
           {:ok, %{"execution_id" => execution_id}} <-
             Datalab.start_job(path, output_format: file_job.output_format || output_format(opts)),
           {:ok, _updated} <-
             DatalabJobs.update_file_job(job.iri, file_job.source_file,
               execution_id: execution_id,
               submitted_at: now()
             ) do
        Mix.shell().info("submitted #{execution_id} #{file_name(file)}")
        %{stats | submitted: stats.submitted + 1}
      else
        {:error, reason} ->
          Mix.shell().error("ERROR #{file_name(file)}: #{inspect(reason)}")

          DatalabJobs.update_file_job(job.iri, file_job.source_file,
            error: inspect(reason),
            failed_at: now()
          )

          %{stats | errors: stats.errors + 1}
      end
    end)
    |> then(fn stats ->
      Mix.shell().info("Done. Submitted #{stats.submitted}, errors #{stats.errors}.")
    end)

    if opts[:await] do
      await(job.iri, opts)
    end
  end

  defp poll(opts) do
    job = require_job(opts)

    if opts[:await] do
      await(job.iri, opts)
    else
      poll_job(job, opts)
    end
  end

  defp poll_job(job, opts) do
    output_dir = Keyword.get(opts, :output_dir, @default_output_dir)
    submitted = DatalabJobs.submitted_file_jobs(job)

    Mix.shell().info("Checking #{length(submitted)} active Datalab executions...")

    with {:ok, executions} <- execution_index(submitted, opts) do
      remote_stats = remote_stats(submitted, executions)
      Mix.shell().info(remote_stats_line(remote_stats))

      stats =
        Enum.reduce(submitted, %{completed: 0, failed: 0, running: 0, errors: 0}, fn file_job,
                                                                                     stats ->
          case Map.fetch(executions, file_job.execution_id) do
            {:ok, body} ->
              handle_poll_status(job, file_job, body, output_dir, stats)

            :error ->
              Mix.shell().error(
                "ERROR #{file_job.execution_id}: not found in pipeline executions"
              )

              %{stats | errors: stats.errors + 1}
          end
        end)

      print_job_progress(job.iri, cycle: stats)
    else
      {:error, reason} ->
        Mix.shell().error("ERROR list pipeline executions: #{inspect(reason)}")

        print_job_progress(job.iri,
          cycle: %{
            completed: 0,
            failed: 0,
            running: 0,
            errors: length(submitted)
          }
        )
    end
  end

  defp remote_stats(file_jobs, executions) do
    Enum.reduce(file_jobs, %{ready: 0, failed: 0, running: 0, unknown: 0}, fn file_job, counts ->
      case Map.fetch(executions, file_job.execution_id) do
        {:ok, body} ->
          case Datalab.status(body) do
            {:ok, status} ->
              cond do
                Datalab.complete_status?(status) -> %{counts | ready: counts.ready + 1}
                Datalab.failed_status?(status) -> %{counts | failed: counts.failed + 1}
                true -> %{counts | running: counts.running + 1}
              end

            {:error, _reason} ->
              %{counts | unknown: counts.unknown + 1}
          end

        :error ->
          %{counts | unknown: counts.unknown + 1}
      end
    end)
  end

  defp remote_stats_line(stats) do
    "Datalab: #{stats.ready} ready, #{stats.running} running, #{stats.failed} failed, #{stats.unknown} unknown"
  end

  defp print_job_progress(job_iri, opts) do
    {:ok, job} = DatalabJobs.get_job(job_iri)
    print_job(job, opts)
  end

  defp print_job(job, opts \\ []) do
    counts = Enum.frequencies_by(job.file_jobs, & &1.status)
    total = length(job.file_jobs)
    completed = counts["completed"] || 0
    failed = counts["failed"] || 0
    pending = counts["pending"] || 0
    submitted = counts["submitted"] || 0
    done = completed + failed
    left = total - done
    cycle = Keyword.get(opts, :cycle)
    phase = Keyword.get(opts, :phase)
    id = Sheaf.Id.id_from_iri(job.iri)

    fields =
      [
        phase && "#{phase}:",
        "#{id} #{progress_bar(done, total)}",
        "#{done}/#{total} done",
        "#{left} left",
        "#{submitted} running",
        "#{completed} completed",
        "#{failed} failed",
        "#{pending} pending"
      ]
      |> Enum.reject(&is_nil/1)

    fields =
      if cycle do
        fields ++ ["cycle +#{cycle.completed}/-#{cycle.failed}, errors #{cycle.errors}"]
      else
        fields
      end

    label = job[:label]

    suffix =
      if label && label != "" do
        "  #{label}"
      else
        ""
      end

    Mix.shell().info(Enum.join(fields, "  ") <> suffix)

    job
  end

  defp progress_bar(_done, 0), do: "[--------------------] 0%"

  defp progress_bar(done, total) do
    width = 20
    filled = div(done * width, total)
    percent = div(done * 100, total)

    "[" <>
      String.duplicate("#", filled) <> String.duplicate("-", width - filled) <> "] #{percent}%"
  end

  defp execution_index([], _opts), do: {:ok, %{}}

  defp execution_index(file_jobs, opts) do
    wanted =
      file_jobs
      |> Enum.map(& &1.execution_id)
      |> MapSet.new()

    fetch_execution_pages(wanted, opts, 0, %{})
  end

  defp fetch_execution_pages(wanted, opts, offset, acc) do
    with {:ok, body} <-
           Datalab.list_pipeline_executions(
             Keyword.merge(opts, limit: @execution_page_size, offset: offset)
           ) do
      executions = Map.get(body, "executions", [])
      total = Map.get(body, "total", offset + length(executions))

      acc =
        executions
        |> Enum.reduce(acc, fn execution, acc ->
          case execution_id(execution) do
            nil -> acc
            execution_id -> Map.put(acc, execution_id, execution)
          end
        end)

      if MapSet.subset?(wanted, MapSet.new(Map.keys(acc))) or offset + length(executions) >= total or
           executions == [] do
        {:ok, acc}
      else
        fetch_execution_pages(wanted, opts, offset + @execution_page_size, acc)
      end
    end
  end

  defp await(job_iri, opts) do
    interval = await_interval(opts)
    Mix.shell().info("Awaiting #{job_iri}; polling every #{div(interval, 1000)}s.")
    await_loop(job_iri, opts, interval)
  end

  defp await_loop(job_iri, opts, interval) do
    {:ok, job} = DatalabJobs.get_job(job_iri)
    print_job(job, phase: "local")
    stats = poll_job(job, opts)
    {:ok, job} = DatalabJobs.get_job(job_iri)

    if DatalabJobs.submitted_file_jobs(job) == [] do
      Mix.shell().info("Await complete for #{job_iri}.")
      print_job(job)
      stats
    else
      Process.sleep(interval)
      await_loop(job_iri, opts, interval)
    end
  end

  defp handle_poll_status(job, file_job, body, output_dir, stats) do
    with {:ok, status} <- Datalab.status(body) do
      cond do
        Datalab.complete_status?(status) ->
          Mix.shell().info("Saving #{file_job.execution_id}...")
          complete_file_job(job, file_job, output_dir, stats)

        Datalab.failed_status?(status) ->
          DatalabJobs.update_file_job(job.iri, file_job.source_file,
            error: inspect(body),
            failed_at: now()
          )

          %{stats | failed: stats.failed + 1}

        true ->
          %{stats | running: stats.running + 1}
      end
    else
      {:error, reason} ->
        Mix.shell().error("ERROR #{file_job.execution_id}: #{inspect(reason)}")
        %{stats | errors: stats.errors + 1}
    end
  end

  defp complete_file_job(job, file_job, output_dir, stats) do
    with {:ok, body} <- Datalab.result(file_job.execution_id),
         {:ok, output} <- Datalab.output(body, file_job.output_format || "json"),
         {:ok, output_path} <- write_output(job.iri, file_job, output, output_dir),
         {:ok, _updated} <-
           DatalabJobs.update_file_job(job.iri, file_job.source_file,
             output_path: output_path,
             completed_at: now()
           ) do
      %{stats | completed: stats.completed + 1}
    else
      {:error, reason} ->
        Mix.shell().error("ERROR #{file_job.execution_id}: #{inspect(reason)}")
        %{stats | errors: stats.errors + 1}
    end
  end

  defp status(opts) do
    case Keyword.get(opts, :job) do
      nil ->
        {:ok, jobs} = DatalabJobs.list_jobs()
        Enum.each(jobs, &print_job/1)

      job_iri ->
        print_job(require_job(Keyword.put(opts, :job, job_iri)))
    end
  end

  defp get_or_create_job(opts) do
    case Keyword.get(opts, :job) do
      nil ->
        candidates = candidate_source_files(opts)

        {:ok, job} =
          DatalabJobs.create_job(candidates,
            name: Keyword.get(opts, :name, "PDF conversion batch"),
            output_format: output_format(opts)
          )

        job

      job_iri ->
        {:ok, job} = DatalabJobs.get_job(job_iri)
        job
    end
  end

  defp require_job(opts) do
    case Keyword.get(opts, :job) do
      nil -> Mix.raise("--job IRI is required")
      job_iri -> DatalabJobs.get_job(job_iri) |> elem(1)
    end
  end

  defp candidate_source_files(opts) do
    {:ok, graph} = Files.list_graph()
    {:ok, already_queued} = DatalabJobs.source_files_in_jobs()

    graph
    |> Files.descriptions()
    |> Enum.filter(&pdf?/1)
    |> Enum.filter(&standalone?(graph, &1))
    |> Enum.reject(&MapSet.member?(already_queued, &1.subject))
    |> Enum.map(& &1.subject)
    |> maybe_limit(Keyword.get(opts, :limit))
  end

  defp maybe_limit(values, nil), do: values
  defp maybe_limit(values, limit), do: Enum.take(values, limit)

  defp file_description(file_iri) do
    {:ok, graph} = Files.list_graph()
    RDF.Graph.description(graph, file_iri)
  end

  defp pdf?(%Description{} = file) do
    first_value(file, DOC.mimeType()) == "application/pdf"
  end

  defp standalone?(graph, %Description{} = file) do
    graph
    |> RDF.Data.descriptions()
    |> Enum.any?(&Description.include?(&1, {DOC.sourceFile(), file.subject}))
    |> Kernel.not()
  end

  defp write_output(job_iri, file_job, output, output_dir) when is_map(output) do
    job_id = Sheaf.Id.id_from_iri(job_iri)
    file_id = Sheaf.Id.id_from_iri(file_job.source_file)
    path = Path.join([output_dir, job_id, "#{file_id}.datalab.json"])
    File.mkdir_p!(Path.dirname(path))

    with :ok <- File.write(path, Jason.encode!(output, pretty: true)) do
      {:ok, path}
    end
  end

  defp file_name(%Description{} = file) do
    first_value(file, DOC.originalFilename()) || Sheaf.Id.id_from_iri(file.subject)
  end

  defp first_value(%Description{} = description, property) do
    description
    |> Description.first(property)
    |> case do
      nil -> nil
      term -> RDF.Term.value(term)
    end
  end

  defp output_format(opts), do: Keyword.get(opts, :output_format, "json")

  defp execution_id(%{"execution_id" => execution_id}) when is_binary(execution_id),
    do: execution_id

  defp execution_id(%{"id" => execution_id}) when is_binary(execution_id), do: execution_id
  defp execution_id(%{execution_id: execution_id}) when is_binary(execution_id), do: execution_id
  defp execution_id(_execution), do: nil

  defp await_interval(opts) do
    case Keyword.get(opts, :await_interval) do
      nil ->
        @default_await_interval

      seconds when is_integer(seconds) and seconds > 0 ->
        seconds * 1000

      other ->
        Mix.raise(
          "--await-interval must be a positive integer number of seconds, got #{inspect(other)}"
        )
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
