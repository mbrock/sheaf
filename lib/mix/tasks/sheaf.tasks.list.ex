defmodule Mix.Tasks.Sheaf.Tasks.List do
  @moduledoc """
  Lists durable Sheaf task batches or task rows.
  """

  use Mix.Task

  @shortdoc "Lists Sheaf task queue state"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional} =
      OptionParser.parse!(args,
        strict: [
          tasks: :boolean,
          limit: :integer,
          status: :string
        ]
      )

    if opts[:tasks] do
      list_tasks(opts)
    else
      list_batches(opts)
    end
  end

  defp list_batches(opts) do
    with {:ok, batches} <- Sheaf.TaskQueue.list_batches(limit: opts[:limit] || 20) do
      Enum.each(batches, fn batch ->
        Mix.shell().info(
          "#{short(batch.iri)} #{batch.queue}:#{batch.kind} #{batch.status} " <>
            "#{batch.completed_count}/#{batch.target_count} failed=#{batch.failed_count}"
        )
      end)
    else
      {:error, reason} -> Mix.raise("Failed to list batches: #{inspect(reason)}")
    end
  end

  defp list_tasks(opts) do
    queue_opts = [limit: opts[:limit] || 50]

    queue_opts =
      if opts[:status], do: Keyword.put(queue_opts, :status, opts[:status]), else: queue_opts

    with {:ok, tasks} <- Sheaf.TaskQueue.list_tasks(queue_opts) do
      Enum.each(tasks, fn task ->
        Mix.shell().info(
          "##{task.id} #{task.kind} #{task.status} attempts=#{task.attempts}/#{task.max_attempts} " <>
            "#{short(task.subject_iri)} #{task.identifier || ""}"
        )
      end)
    else
      {:error, reason} -> Mix.raise("Failed to list tasks: #{inspect(reason)}")
    end
  end

  defp short(nil), do: "(none)"

  defp short(iri) do
    iri
    |> to_string()
    |> String.replace_prefix("https://sheaf.less.rest/", "")
  end
end
