defmodule Sheaf.PDF do
  @moduledoc """
  Small wrapper around the Datalab PDF conversion pipeline.

  The default pipeline is configured by `DATALAB_PIPELINE_ID`, falling back to
  the first Markdown conversion pipeline we tried by hand. The API key is read
  from `DATALAB_API_KEY`.
  """

  @default_base_url "https://www.datalab.to/api/v1"
  @default_output_format "markdown"
  @result_step 0

  @type execution_id :: String.t()
  @type response :: {:ok, map()} | {:error, term()}

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

  defp blank_to_nil(value) when value in [nil, ""], do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
