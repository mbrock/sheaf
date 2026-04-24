defmodule Datalab do
  @moduledoc """
  Client for the Datalab PDF conversion pipeline.

  The default pipeline is configured by `DATALAB_PIPELINE_ID`, falling back to
  the first Markdown conversion pipeline we tried by hand. The API key is read
  from `DATALAB_API_KEY`.
  """

  @default_base_url "https://www.datalab.to/api/v1"
  @default_output_format "markdown"
  @default_poll_interval 10_000
  @default_poll_timeout :timer.minutes(15)
  @complete_statuses ~w(completed succeeded success finished done)
  @failed_statuses ~w(failed error errored cancelled canceled)
  @result_step 0

  @type execution_id :: String.t()
  @type response :: {:ok, map()} | {:error, term()}

  @doc """
  Converts a local PDF and returns the normalized Datalab result.

  This starts a job, polls until completion, fetches the step result, and
  normalizes the response for the requested `:output_format`.

  Options:

    * `:output_format` - `"markdown"`, `"html"`, or `"json"`
    * `:poll_interval` - milliseconds between status checks, defaults to 10s
    * `:poll_timeout` - total milliseconds to wait, defaults to 15 minutes

  The returned map includes `:execution_id`, `:status`, `:output_format`, and
  `:output`.
  """
  @spec convert(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def convert(path, opts \\ []) when is_binary(path) do
    output_format = output_format(opts)

    with {:ok, %{"execution_id" => execution_id}} <- start_job(path, opts),
         {:ok, status} <- await_job(execution_id, opts),
         {:ok, body} <- result(execution_id, opts),
         {:ok, output} <- extract_output(body, output_format) do
      {:ok,
       %{
         execution_id: execution_id,
         output: output,
         output_format: output_format,
         status: status
       }}
    end
  end

  @doc """
  Converts a local PDF and writes the normalized result next to the source file.

  By default this writes `basename.datalab.<format-extension>`. Pass
  `:output_suffix` to use another basename suffix, or `:output_path` to choose
  a specific file.
  """
  @spec convert_file(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def convert_file(path, opts \\ []) when is_binary(path) do
    output_format = output_format(opts)

    output_path =
      Keyword.get_lazy(opts, :output_path, fn -> output_path(path, output_format, opts) end)

    with {:ok, result} <- convert(path, opts),
         :ok <- write_output(output_path, result.output, output_format) do
      {:ok, Map.put(result, :output_path, output_path)}
    end
  end

  @doc """
  Converts several PDFs sequentially with `convert_file/2`.
  """
  @spec convert_files([Path.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def convert_files(paths, opts \\ []) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, results} ->
      case convert_file(path, opts) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  @doc """
  Starts a Datalab pipeline job for a local PDF.

  Options:

    * `:page_range` - optional Datalab page range, such as `"16-18"`
    * `:output_format` - defaults to `"markdown"`
    * `:pipeline_id`, `:api_key`, `:base_url` - override configured values
    * `:req_options` - extra Req options, mostly useful in tests

  Returns the decoded Datalab response, including the `execution_id`.
  """
  @spec start_job(Path.t(), keyword()) :: response()
  def start_job(path, opts \\ []) when is_binary(path) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, bytes} <- File.read(path) do
      form =
        [
          {"file", {bytes, filename: Path.basename(path), content_type: "application/pdf"}},
          {"output_format", Keyword.get(opts, :output_format, @default_output_format)}
        ]
        |> maybe_put("page_range", Keyword.get(opts, :page_range))

      client(api_key, opts)
      |> Req.post(url: "/pipelines/#{pipeline_id(opts)}/run", form_multipart: form)
      |> handle_response()
    end
  end

  @doc """
  Checks a Datalab pipeline execution.
  """
  @spec check_job(execution_id(), keyword()) :: response()
  def check_job(execution_id, opts \\ []) when is_binary(execution_id) do
    with {:ok, api_key} <- api_key(opts) do
      client(api_key, opts)
      |> Req.get(url: "/pipelines/executions/#{execution_id}")
      |> handle_response()
    end
  end

  @doc """
  Polls a Datalab pipeline execution until it reaches a terminal status.
  """
  @spec await_job(execution_id(), keyword()) :: response()
  def await_job(execution_id, opts \\ []) when is_binary(execution_id) do
    deadline =
      System.monotonic_time(:millisecond) +
        Keyword.get(opts, :poll_timeout, @default_poll_timeout)

    do_await_job(execution_id, deadline, opts)
  end

  @doc """
  Fetches the raw result for a completed Datalab pipeline step.
  """
  @spec result(execution_id(), keyword()) :: response()
  def result(execution_id, opts \\ []) when is_binary(execution_id) do
    step = Keyword.get(opts, :step, @result_step)

    with {:ok, api_key} <- api_key(opts) do
      client(api_key, opts)
      |> Req.get(url: "/pipelines/executions/#{execution_id}/steps/#{step}/result")
      |> handle_response()
    end
  end

  @doc """
  Fetches the Markdown result for a completed conversion job.
  """
  @spec markdown(execution_id(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def markdown(execution_id, opts \\ []) when is_binary(execution_id) do
    with {:ok, body} <- result(execution_id, opts),
         {:ok, markdown} <- fetch_markdown(body) do
      {:ok, markdown}
    end
  end

  defp do_await_job(execution_id, deadline, opts) do
    with {:ok, body} <- check_job(execution_id, opts),
         {:ok, status} <- job_status(body) do
      cond do
        status in @complete_statuses ->
          {:ok, body}

        status in @failed_statuses ->
          {:error, {:job_failed, body}}

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, {:job_timeout, body}}

        true ->
          opts
          |> Keyword.get(:poll_interval, @default_poll_interval)
          |> Process.sleep()

          do_await_job(execution_id, deadline, opts)
      end
    end
  end

  defp client(api_key, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    [
      base_url: base_url(opts),
      headers: [{"x-api-key", api_key}],
      receive_timeout: Keyword.get(opts, :receive_timeout, 120_000)
    ]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  defp api_key(opts) do
    opts
    |> Keyword.get(:api_key)
    |> blank_to_nil()
    |> case do
      nil ->
        :sheaf
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:api_key)
        |> blank_to_nil()
        |> case do
          nil -> {:error, :missing_datalab_api_key}
          api_key -> {:ok, api_key}
        end

      api_key ->
        {:ok, api_key}
    end
  end

  defp pipeline_id(opts) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:pipeline_id, "pl_QWhrjJhpUUoo")

    Keyword.get(opts, :pipeline_id, configured)
  end

  defp base_url(opts) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:base_url, @default_base_url)

    Keyword.get(opts, :base_url, configured)
  end

  defp maybe_put(form, _key, nil), do: form
  defp maybe_put(form, _key, ""), do: form
  defp maybe_put(form, key, value), do: form ++ [{key, value}]

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, %{status: status, body: body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp fetch_markdown(%{"markdown" => markdown}) when is_binary(markdown), do: {:ok, markdown}

  defp fetch_markdown(%{"result" => %{"markdown" => markdown}}) when is_binary(markdown),
    do: {:ok, markdown}

  defp fetch_markdown(body), do: {:error, {:missing_markdown, body}}

  defp extract_output(body, "markdown"), do: fetch_markdown(body)
  defp extract_output(%{"html" => html}, "html") when is_binary(html), do: {:ok, html}

  defp extract_output(%{"result" => result}, "html") when is_map(result),
    do: extract_output(result, "html")

  defp extract_output(%{"children" => _} = document, "json"), do: {:ok, document}
  defp extract_output(%{"json" => document}, "json") when is_map(document), do: {:ok, document}
  defp extract_output(%{"json" => json}, "json") when is_binary(json), do: Jason.decode(json)

  defp extract_output(%{"result" => result}, "json") when is_map(result),
    do: extract_output(result, "json")

  defp extract_output(body, output_format), do: {:error, {:missing_output, output_format, body}}

  defp write_output(path, output, "json") when is_map(output) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(path, Jason.encode!(output, pretty: true))
  end

  defp write_output(path, output, _output_format) when is_binary(output) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(path, output)
  end

  defp output_format(opts) do
    opts
    |> Keyword.get(:output_format, @default_output_format)
    |> to_string()
  end

  defp output_path(path, output_format, opts) do
    suffix = Keyword.get(opts, :output_suffix, "datalab")
    Path.rootname(path) <> ".#{suffix}." <> output_extension(output_format)
  end

  defp output_extension("markdown"), do: "md"
  defp output_extension(output_format), do: output_format

  defp job_status(%{"status" => status}) when is_binary(status),
    do: {:ok, String.downcase(status)}

  defp job_status(%{"state" => status}) when is_binary(status),
    do: {:ok, String.downcase(status)}

  defp job_status(%{"execution" => execution}) when is_map(execution), do: job_status(execution)
  defp job_status(body), do: {:error, {:missing_job_status, body}}

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
