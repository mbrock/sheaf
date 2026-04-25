defmodule Sheaf.Embedding do
  @moduledoc """
  Raw HTTP client for Gemini embeddings.

  This intentionally uses Req directly instead of ReqLLM because embeddings are
  a data-plane operation for Sheaf: callers should get vectors, not chat-model
  abstractions.
  """

  @default_base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_model "gemini-embedding-2"
  @default_receive_timeout 120_000

  @type embedding :: %{
          required(:values) => [float()],
          required(:dimensions) => non_neg_integer(),
          required(:model) => String.t()
        }

  @type response :: {:ok, embedding()} | {:error, term()}

  @doc """
  Returns the configured Gemini embedding model.
  """
  @spec model(keyword()) :: String.t()
  def model(opts \\ []) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:model, @default_model)

    Keyword.get(opts, :model, configured)
  end

  @doc """
  Returns the configured Gemini API base URL.
  """
  @spec base_url(keyword()) :: String.t()
  def base_url(opts \\ []) do
    configured =
      :sheaf
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:base_url, @default_base_url)

    Keyword.get(opts, :base_url, configured)
  end

  @doc """
  Embeds a single text input with Gemini Embedding 2.

  Options:

    * `:model` - Gemini model id, defaulting to `gemini-embedding-2`.
    * `:output_dimensionality` - optional vector size from 128 to 3072.
    * `:api_key`, `:base_url`, `:receive_timeout` - request configuration.
    * `:req_options` - extra Req options, mostly useful in tests.
  """
  @spec embed_text(String.t(), keyword()) :: response()
  def embed_text(text, opts \\ []) when is_binary(text) do
    embed_parts([%{text: text}], opts)
  end

  @doc """
  Embeds several text inputs as separate embeddings using concurrent requests.

  Gemini Embedding 2 aggregates multiple parts in one `embedContent` request.
  This helper deliberately sends one request per text, but runs those requests
  concurrently so paragraph embeddings remain independently comparable without
  serializing throughput.

  Options:

    * `:max_concurrency` - maximum in-flight requests, defaulting to online
      scheduler count.
    * `:timeout` - per-task timeout, defaulting to `:infinity`.
  """
  @spec embed_texts([String.t()], keyword()) :: {:ok, [embedding()]} | {:error, term()}
  def embed_texts(texts, opts \\ []) when is_list(texts) do
    texts
    |> Task.async_stream(&embed_text(&1, opts),
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      ordered: true,
      timeout: Keyword.get(opts, :timeout, :infinity)
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, embedding}}, {:ok, embeddings} ->
        {:cont, {:ok, [embedding | embeddings]}}

      {:ok, {:error, reason}}, _ ->
        {:halt, {:error, reason}}

      {:exit, reason}, _ ->
        {:halt, {:error, {:task_exit, reason}}}
    end)
    |> case do
      {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Embeds raw Gemini content parts.

  Parts should use the Gemini REST shape, for example `%{text: "..."}` or
  `%{inline_data: %{mime_type: "image/png", data: base64}}`.
  """
  @spec embed_parts([map()], keyword()) :: response()
  def embed_parts(parts, opts \\ []) when is_list(parts) do
    embed_parts_with_retry(parts, opts, 0)
  end

  defp embed_parts_with_retry(parts, opts, attempt) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, body} <- post_embedding(api_key, parts, opts),
         {:ok, [embedding | _]} <- extract_embeddings(body),
         {:ok, embedding} <- normalize_embedding(embedding, model(opts)) do
      {:ok, embedding}
    else
      {:error, reason} = error ->
        if retryable?(reason) and attempt < Keyword.get(opts, :max_retries, 3) do
          sleep_before_retry(attempt, opts)
          embed_parts_with_retry(parts, opts, attempt + 1)
        else
          error
        end
    end
  end

  @doc false
  def request_body(parts, opts \\ []) when is_list(parts) do
    %{content: %{parts: parts}}
    |> maybe_put(:output_dimensionality, Keyword.get(opts, :output_dimensionality))
  end

  defp post_embedding(api_key, parts, opts) do
    client(api_key, opts)
    |> Req.post(url: embedding_path(model(opts)), json: request_body(parts, opts))
    |> handle_response()
  end

  defp client(api_key, opts) do
    req_options = Keyword.get(opts, :req_options, [])

    [
      base_url: base_url(opts),
      headers: [{"x-goog-api-key", api_key}],
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout),
      http_errors: :return
    ]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: status, body: body}}),
    do: {:error, %{status: status, body: body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  defp extract_embeddings(%{"embeddings" => embeddings}) when is_list(embeddings),
    do: {:ok, embeddings}

  defp extract_embeddings(%{"embedding" => embedding}) when is_map(embedding),
    do: {:ok, [embedding]}

  defp extract_embeddings(body), do: {:error, {:missing_embedding, body}}

  defp normalize_embedding(%{"values" => values}, model) when is_list(values) do
    values = Enum.map(values, &(&1 * 1.0))
    {:ok, %{values: values, dimensions: length(values), model: model}}
  end

  defp normalize_embedding(embedding, _model), do: {:error, {:missing_values, embedding}}

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
          nil -> {:error, :missing_gemini_api_key}
          api_key -> {:ok, api_key}
        end

      api_key ->
        {:ok, api_key}
    end
  end

  defp embedding_path(model) do
    model =
      model
      |> String.trim()
      |> String.trim_leading("models/")
      |> URI.encode(&URI.char_unreserved?/1)

    "/models/#{model}:embedContent"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp retryable?(%{status: status}) when status in [408, 409, 425, 429], do: true
  defp retryable?(%{status: status}) when status in 500..599, do: true
  defp retryable?(_reason), do: false

  defp sleep_before_retry(attempt, opts) do
    base = Keyword.get(opts, :retry_base_ms, 500)
    jitter = if base > 0, do: :rand.uniform(base), else: 0
    Process.sleep((base * :math.pow(2, attempt)) |> round() |> Kernel.+(jitter))
  end
end
