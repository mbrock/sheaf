defmodule Mix.Tasks.Sheaf.Backup do
  @moduledoc """
  Starts a Fuseki-native backup for the configured RDF dataset.
  """

  use Mix.Task

  @shortdoc "Backs up the configured dataset with Fuseki"
  @default_timeout 300_000
  @poll_interval 1_000
  @server_backup_dir "/fuseki/backups"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, invalid} =
      OptionParser.parse(args, strict: [output: :string, timeout: :integer, no_copy: :boolean])

    case invalid do
      [] ->
        case backup_dataset(opts) do
          {:ok, %{file: file, copied_to: path}} when is_binary(path) ->
            Mix.shell().info("Backed up the dataset to #{path} via Fuseki (#{file})")

          {:ok, %{file: file, server_path: server_path}} ->
            Mix.shell().info("Backed up the dataset in Fuseki at #{server_path} (#{file})")

          {:error, message} ->
            Mix.raise(message)
        end

      _ ->
        Mix.raise("Unrecognized arguments: #{inspect(invalid)}")
    end
  end

  defp backup_dataset(opts) do
    config = Application.fetch_env!(:sheaf, Sheaf)
    admin = admin_config(config)

    with {:ok, before_files} <- backups_list(admin),
         {:ok, task_id} <- start_backup(admin),
         {:ok, _task} <- await_task(admin, task_id, timeout(opts)),
         {:ok, after_files} <- backups_list(admin),
         {:ok, file} <- new_backup_file(before_files, after_files) do
      result = %{
        file: file,
        task_id: task_id,
        server_path: Path.join("backups", file)
      }

      maybe_copy_backup(result, opts)
    end
  end

  defp admin_config(config) do
    uri = URI.parse(config[:query_endpoint] || config[:data_endpoint])
    path_segments = uri.path |> String.trim_leading("/") |> String.split("/", trim: true)
    dataset = List.first(path_segments) || raise "Could not derive Fuseki dataset from endpoint"
    port = if uri.port, do: ":#{uri.port}", else: ""

    %{
      base_url: "#{uri.scheme}://#{uri.host}#{port}",
      dataset: dataset,
      auth: config[:sparql_auth] || config[:data_auth]
    }
  end

  defp start_backup(admin) do
    case request(:post, admin, "/$/backup/#{admin.dataset}") do
      {:ok, body, _headers} ->
        case Map.get(body, "taskId") || Map.get(body, :taskId) do
          task_id when is_binary(task_id) or is_integer(task_id) -> {:ok, to_string(task_id)}
          _ -> {:error, "Fuseki backup response did not include taskId: #{inspect(body)}"}
        end

      {:error, reason} ->
        {:error, "Could not start Fuseki backup: #{inspect(reason)}"}
    end
  end

  defp await_task(admin, task_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_task(admin, task_id, deadline, nil)
  end

  defp await_task(admin, task_id, deadline, last_task) do
    case request(:get, admin, "/$/tasks/#{task_id}") do
      {:ok, body, _headers} ->
        task = task_record(body, task_id)

        cond do
          finished_task?(task) ->
            {:ok, task}

          System.monotonic_time(:millisecond) >= deadline ->
            {:error,
             "Timed out waiting for Fuseki backup task #{task_id}: #{inspect(task || last_task)}"}

          true ->
            Process.sleep(@poll_interval)
            await_task(admin, task_id, deadline, task || last_task)
        end

      {:error, reason} ->
        {:error, "Could not inspect Fuseki backup task #{task_id}: #{inspect(reason)}"}
    end
  end

  defp task_record([record], _task_id), do: record

  defp task_record(records, task_id) when is_list(records) do
    Enum.find(records, &(to_string(Map.get(&1, "taskId") || Map.get(&1, :taskId)) == task_id))
  end

  defp task_record(record, _task_id) when is_map(record), do: record
  defp task_record(_body, _task_id), do: nil

  defp finished_task?(task) when is_map(task) do
    Map.has_key?(task, "finished") or Map.has_key?(task, "finishPoint") or
      Map.has_key?(task, :finished) or Map.has_key?(task, :finishPoint)
  end

  defp finished_task?(_task), do: false

  defp backups_list(admin) do
    case request(:get, admin, "/$/backups-list") do
      {:ok, body, _headers} ->
        backups = Map.get(body, "backups") || Map.get(body, :backups) || []

        if is_list(backups) do
          {:ok, Enum.map(backups, &to_string/1)}
        else
          {:error, "Fuseki backups-list response was not a list: #{inspect(body)}"}
        end

      {:error, reason} ->
        {:error, "Could not list Fuseki backups: #{inspect(reason)}"}
    end
  end

  defp new_backup_file(before_files, after_files) do
    new_files =
      after_files
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(before_files))
      |> MapSet.to_list()
      |> Enum.sort(:desc)

    case new_files do
      [file | _] -> {:ok, file}
      [] -> {:error, "Fuseki backup finished, but no new backup file appeared in /$/backups-list"}
    end
  end

  defp request(method, admin, path) do
    admin
    |> client()
    |> Req.request(method: method, url: path)
    |> case do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        {:ok, decode_body(body), headers}

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp client(admin) do
    Req.new(
      base_url: admin.base_url,
      auth: req_auth(admin.auth),
      headers: [accept: "application/json"],
      http_errors: :return
    )
  end

  defp req_auth({:basic, credentials}), do: {:basic, credentials}
  defp req_auth(nil), do: nil

  defp decode_body(body) when is_map(body) or is_list(body), do: body

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp maybe_copy_backup(result, opts) do
    if opts[:no_copy] do
      {:ok, result}
    else
      output_path = output_path(result.file, opts)

      case copy_from_container(result.file, output_path) do
        :ok ->
          {:ok, Map.put(result, :copied_to, output_path)}

        {:error, message} ->
          Mix.shell().error("#{message}; leaving backup in Fuseki at #{result.server_path}")
          {:ok, result}
      end
    end
  end

  defp copy_from_container(file, output_path) do
    container = System.get_env("SHEAF_TRIPLESTORE_CONTAINER", "sheaf-fuseki")
    File.mkdir_p!(Path.dirname(output_path))

    case System.cmd(
           "docker",
           ["cp", "#{container}:#{Path.join(@server_backup_dir, file)}", output_path],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error,
         "Could not copy Fuseki backup with docker cp (exit #{status}): #{String.trim(output)}"}
    end
  rescue
    error in ErlangError -> {:error, "Could not run docker cp: #{Exception.message(error)}"}
  end

  defp output_path(file, opts) do
    case Keyword.get(opts, :output) do
      nil -> Path.join(default_backup_dir(), file)
      output -> normalize_output(output, file)
    end
  end

  defp normalize_output(output, file) do
    cond do
      String.ends_with?(output, "/") -> Path.join(output, file)
      Path.extname(output) in [".gz", ".nq", ".trig", ".ttl"] -> output
      true -> Path.join(output, file)
    end
  end

  defp default_backup_dir, do: Path.join(["output", "backups"])

  defp timeout(opts) do
    Keyword.get(opts, :timeout, @default_timeout)
  end
end
