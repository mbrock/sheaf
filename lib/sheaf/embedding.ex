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
  @default_max_retries 5
  @default_batch_poll_interval_ms 10_000
  @terminal_batch_states ~w(BATCH_STATE_SUCCEEDED BATCH_STATE_FAILED BATCH_STATE_CANCELLED BATCH_STATE_EXPIRED)

  require Logger

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
  Embeds a single text input.

  Options:

    * `:model` - Gemini model id, defaulting to `gemini-embedding-2`.
    * `:output_dimensionality` - optional vector size from 128 to 3072.
    * `:task` - `:search`, `:semantic_similarity`, `:classification`, or `:clustering`.
    * `:input_role` - `:query` or `:document`.
    * `:title` - document title for retrieval document embeddings.
    * `:api_key`, `:base_url`, `:receive_timeout` - request configuration.
    * `:req_options` - extra Req options, mostly useful in tests.

  For `gemini-embedding-2`, task information is translated to the prompt
  formats Google documents for text-only retrieval. For `gemini-embedding-001`,
  task information is translated to `taskType` and `title` request parameters.
  """
  @spec embed_text(String.t(), keyword()) :: response()
  def embed_text(text, opts \\ []) when is_binary(text) do
    prepared = prepare_text(text, opts)
    embed_parts([%{text: prepared.text}], prepared.opts)
  end

  @doc """
  Embeds a search query with the model-appropriate retrieval task format.
  """
  @spec embed_query(String.t(), keyword()) :: response()
  def embed_query(query, opts \\ []) when is_binary(query) do
    embed_text(query, Keyword.merge(opts, task: :search, input_role: :query))
  end

  @doc """
  Embeds a document text with the model-appropriate retrieval task format.
  """
  @spec embed_document(String.t(), String.t() | nil, keyword()) :: response()
  def embed_document(text, title \\ nil, opts \\ []) when is_binary(text) do
    embed_text(text, Keyword.merge(opts, task: :search, input_role: :document, title: title))
  end

  @doc """
  Returns the exact text sent to Gemini after task/profile formatting.
  """
  @spec prepared_text(String.t(), keyword()) :: String.t()
  def prepared_text(text, opts \\ []) when is_binary(text), do: prepare_text(text, opts).text

  @doc """
  Embeds several texts as separate embeddings with `batchEmbedContents`.
  """
  @spec embed_texts([String.t()], keyword()) :: {:ok, [embedding()]} | {:error, term()}
  def embed_texts(texts, opts \\ []) when is_list(texts) do
    texts
    |> Enum.map(&%{text: &1})
    |> embed_documents(opts)
  end

  @doc """
  Embeds document-like inputs as separate embeddings with `batchEmbedContents`.

  Each document must contain `:text` and may contain `:title`.
  """
  @spec embed_documents([map()], keyword()) :: {:ok, [embedding()]} | {:error, term()}
  def embed_documents(documents, opts \\ []) when is_list(documents) do
    batch_size = Keyword.get(opts, :batch_size, 32)

    documents
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(&embed_text_batch(&1, opts),
      max_concurrency: Keyword.get(opts, :max_concurrency, 8),
      ordered: true,
      timeout: Keyword.get(opts, :timeout, :infinity)
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, embeddings}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ embeddings}}

      {:ok, {:error, reason}}, _ ->
        {:halt, {:error, reason}}

      {:exit, reason}, _ ->
        {:halt, {:error, {:task_exit, reason}}}
    end)
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

  @doc """
  Embeds a batch of texts/documents with `batchEmbedContents`.
  """
  @spec embed_text_batch([map()], keyword()) :: {:ok, [embedding()]} | {:error, term()}
  def embed_text_batch(documents, opts \\ []) when is_list(documents) do
    embed_text_batch_with_retry(documents, opts, 0)
  end

  @doc """
  Embeds documents with Gemini's asynchronous Batch API.

  This uses `asyncBatchEmbedContent`, not the synchronous `batchEmbedContents`
  endpoint. By default it uses file-backed JSONL so large output sets are
  downloaded as JSONL instead of being returned in one large operation response.
  """
  @spec async_batch_embed_documents([map()], keyword()) :: {:ok, [embedding()]} | {:error, term()}
  def async_batch_embed_documents(documents, opts \\ []) when is_list(documents) do
    with {:ok, batch} <- create_async_embed_batch(documents, opts),
         {:ok, completed} <- wait_for_batch(batch.name, opts),
         {:ok, responses} <- batch_embed_responses(completed, opts),
         {:ok, embeddings} <- normalize_async_embed_responses(responses, model(opts)) do
      {:ok, embeddings}
    end
  end

  @doc """
  Creates an asynchronous Gemini embedding batch job.
  """
  @spec create_async_embed_batch([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def create_async_embed_batch(documents, opts \\ []) when is_list(documents) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, input_config} <- async_batch_input_config(documents, opts),
         {:ok, body} <- post_async_embed_batch(api_key, input_config, documents, opts),
         {:ok, batch} <- normalize_batch(body) do
      {:ok, batch}
    end
  end

  @doc """
  Fetches a Gemini batch operation by name, for example `batches/abc`.
  """
  @spec get_batch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_batch(name, opts \\ []) when is_binary(name) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, body} <-
           client(api_key, opts)
           |> Req.get(url: "/#{String.trim_leading(name, "/")}")
           |> handle_response(),
         {:ok, batch} <- normalize_batch(body) do
      {:ok, batch}
    end
  end

  @doc """
  Polls a Gemini batch operation until it reaches a terminal state.
  """
  @spec wait_for_batch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def wait_for_batch(name, opts \\ []) when is_binary(name) do
    deadline =
      Keyword.get_lazy(opts, :poll_timeout_ms, fn -> :timer.hours(24) end)
      |> then(&(:erlang.monotonic_time(:millisecond) + &1))

    wait_for_batch(name, opts, deadline, nil)
  end

  @doc """
  Waits for an existing async embedding batch and returns its embeddings.
  """
  @spec collect_async_embed_batch(String.t(), keyword()) ::
          {:ok, [embedding()]} | {:error, term()}
  def collect_async_embed_batch(name, opts \\ []) when is_binary(name) do
    with {:ok, completed} <- wait_for_batch(name, opts),
         {:ok, responses} <- batch_embed_responses(completed, opts),
         {:ok, embeddings} <- normalize_async_embed_responses(responses, model(opts)) do
      {:ok, embeddings}
    end
  end

  @doc false
  def request_body(parts, opts \\ []) when is_list(parts) do
    opts = normalize_task_options(opts)

    %{content: %{parts: parts}}
    |> maybe_put(:taskType, task_type(opts))
    |> maybe_put(:title, request_title(opts))
    |> maybe_put(:output_dimensionality, Keyword.get(opts, :output_dimensionality))
  end

  @doc false
  def batch_request_body(documents, opts \\ []) when is_list(documents) do
    %{
      requests:
        Enum.map(documents, fn document ->
          embed_content_request(document, opts)
        end)
    }
  end

  @doc false
  def embed_content_request(document, opts \\ []) when is_map(document) do
    document_opts = Keyword.merge(opts, document_options(document))
    prepared = prepare_text(document_text(document), document_opts)

    %{model: model_resource(model(document_opts))}
    |> Map.merge(request_body([%{text: prepared.text}], prepared.opts))
  end

  defp embed_parts_with_retry(parts, opts, attempt) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, body} <- post_embedding(api_key, parts, opts),
         {:ok, [embedding | _]} <- extract_embeddings(body),
         {:ok, embedding} <- normalize_embedding(embedding, model(opts)) do
      {:ok, embedding}
    else
      {:error, reason} = error ->
        if retryable?(reason) and attempt < max_retries(opts) do
          sleep_before_retry(reason, attempt, opts)
          embed_parts_with_retry(parts, opts, attempt + 1)
        else
          error
        end
    end
  end

  defp embed_text_batch_with_retry(documents, opts, attempt) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, body} <- post_embedding_batch(api_key, documents, opts),
         {:ok, embeddings} <- extract_embeddings(body),
         {:ok, embeddings} <- normalize_embeddings(embeddings, model(opts)) do
      {:ok, embeddings}
    else
      {:error, reason} = error ->
        if retryable?(reason) and attempt < max_retries(opts) do
          sleep_before_retry(reason, attempt, opts)
          embed_text_batch_with_retry(documents, opts, attempt + 1)
        else
          error
        end
    end
  end

  defp post_embedding(api_key, parts, opts) do
    client(api_key, opts)
    |> Req.post(url: embedding_path(model(opts)), json: request_body(parts, opts))
    |> handle_response()
  end

  defp post_embedding_batch(api_key, documents, opts) do
    client(api_key, opts)
    |> Req.post(url: batch_embedding_path(model(opts)), json: batch_request_body(documents, opts))
    |> handle_response()
  end

  defp post_async_embed_batch(api_key, input_config, documents, opts) do
    display_name =
      Keyword.get_lazy(opts, :display_name, fn ->
        "sheaf-embeddings-#{System.system_time(:second)}-#{length(documents)}"
      end)

    body = %{
      batch: %{
        displayName: display_name,
        inputConfig: input_config
      }
    }

    client(api_key, opts)
    |> Req.post(url: async_batch_embedding_path(model(opts)), json: body)
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

  defp normalize_embeddings(embeddings, model) when is_list(embeddings) do
    embeddings
    |> Enum.reduce_while({:ok, []}, fn embedding, {:ok, acc} ->
      case normalize_embedding(embedding, model) do
        {:ok, embedding} -> {:cont, {:ok, [embedding | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_async_embed_responses(responses, model) do
    responses
    |> Enum.reduce_while({:ok, []}, fn response, {:ok, acc} ->
      case embed_response_embedding(response, model) do
        {:ok, embedding} -> {:cont, {:ok, [embedding | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, embeddings} -> {:ok, Enum.reverse(embeddings)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp embed_response_embedding(%{"error" => error}, _model),
    do: {:error, {:batch_item_error, error}}

  defp embed_response_embedding(%{"output" => %{"error" => error}}, _model),
    do: {:error, {:batch_item_error, error}}

  defp embed_response_embedding(response, model) do
    embedding =
      response
      |> response_payload()
      |> case do
        %{"embedding" => embedding} -> embedding
        %{"embeddings" => [embedding | _]} -> embedding
        embedding -> embedding
      end

    normalize_embedding(embedding, model)
  end

  defp response_payload(%{"response" => response}), do: response
  defp response_payload(%{"output" => %{"response" => response}}), do: response
  defp response_payload(response), do: response

  defp async_batch_input_config(documents, opts) do
    case Keyword.get(opts, :batch_input, :file) do
      mode when mode in [:inline, "inline"] ->
        {:ok, %{requests: %{requests: inlined_embed_requests(documents, opts)}}}

      mode when mode in [:file, "file"] ->
        with {:ok, file} <- upload_async_batch_file(documents, opts) do
          {:ok, %{fileName: file.name}}
        end

      other ->
        {:error, {:invalid_batch_input, other}}
    end
  end

  defp inlined_embed_requests(documents, opts) do
    documents
    |> Enum.with_index()
    |> Enum.map(fn {document, index} ->
      %{
        request: embed_content_request(document, opts),
        metadata: %{key: document_key(document, index)}
      }
    end)
  end

  defp upload_async_batch_file(documents, opts) do
    jsonl = async_batch_jsonl(documents, opts)

    with {:ok, api_key} <- api_key(opts),
         {:ok, upload_url} <- start_file_upload(api_key, jsonl, opts),
         {:ok, body} <- finalize_file_upload(upload_url, jsonl, opts),
         {:ok, file} <- normalize_uploaded_file(body) do
      {:ok, file}
    end
  end

  defp async_batch_jsonl(documents, opts) do
    documents
    |> Enum.with_index()
    |> Enum.map(fn {document, index} ->
      Jason.encode!(%{
        key: document_key(document, index),
        request: embed_content_request(document, opts)
      })
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp start_file_upload(api_key, jsonl, opts) do
    display_name =
      Keyword.get_lazy(opts, :file_display_name, fn ->
        "sheaf-embedding-batch-#{System.system_time(:second)}.jsonl"
      end)

    Req.post(
      upload_files_url(opts),
      headers: [
        {"x-goog-api-key", api_key},
        {"X-Goog-Upload-Protocol", "resumable"},
        {"X-Goog-Upload-Command", "start"},
        {"X-Goog-Upload-Header-Content-Length", Integer.to_string(byte_size(jsonl))},
        {"X-Goog-Upload-Header-Content-Type", "application/jsonl"},
        {"Content-Type", "application/json"}
      ],
      json: %{file: %{displayName: display_name, mimeType: "application/jsonl"}},
      http_errors: :return,
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    )
    |> case do
      {:ok, %{status: status, headers: headers}} when status in 200..299 ->
        case headers["x-goog-upload-url"] do
          [upload_url | _] -> {:ok, upload_url}
          _ -> {:error, :missing_upload_url}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_file_upload(upload_url, jsonl, opts) do
    Req.post(
      upload_url,
      headers: [
        {"Content-Length", Integer.to_string(byte_size(jsonl))},
        {"X-Goog-Upload-Offset", "0"},
        {"X-Goog-Upload-Command", "upload, finalize"}
      ],
      body: jsonl,
      http_errors: :return,
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    )
    |> handle_response()
  end

  defp normalize_uploaded_file(%{"file" => %{"name" => name} = file}) do
    {:ok, %{name: name, body: file}}
  end

  defp normalize_uploaded_file(body), do: {:error, {:invalid_file_upload_response, body}}

  defp wait_for_batch(name, opts, deadline, previous_state) do
    case get_batch(name, opts) do
      {:ok, %{state: state} = batch} when state in @terminal_batch_states ->
        Logger.info("Gemini embedding batch #{name}: #{state} #{inspect(batch.stats)}")
        terminal_batch_result(batch)

      {:ok, %{state: state} = batch} ->
        if state != previous_state do
          Logger.info("Gemini embedding batch #{name}: #{state} #{inspect(batch.stats)}")
        end

        if :erlang.monotonic_time(:millisecond) >= deadline do
          {:error, {:batch_poll_timeout, batch}}
        else
          Process.sleep(Keyword.get(opts, :poll_interval_ms, @default_batch_poll_interval_ms))
          wait_for_batch(name, opts, deadline, state)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminal_batch_result(%{state: "BATCH_STATE_SUCCEEDED"} = batch), do: {:ok, batch}
  defp terminal_batch_result(batch), do: {:error, {:batch_failed, batch}}

  defp batch_embed_responses(%{body: body}, opts) do
    output = batch_output(body)

    cond do
      responses = inlined_embed_responses(output) ->
        {:ok, responses}

      output && output["responsesFile"] ->
        download_batch_responses_file(output["responsesFile"], opts)

      true ->
        {:error, {:missing_batch_output, body}}
    end
  end

  defp batch_output(body) do
    body["output"] || get_in(body, ["metadata", "output"]) || get_in(body, ["response", "output"]) ||
      body["dest"] || get_in(body, ["metadata", "dest"]) || get_in(body, ["response", "dest"])
  end

  defp inlined_embed_responses(nil), do: nil

  defp inlined_embed_responses(output) do
    get_in(output, ["inlinedResponses", "inlinedResponses"]) ||
      get_in(output, ["inlinedEmbedContentResponses", "inlinedResponses"]) ||
      output["inlinedResponses"] ||
      output["inlinedEmbedContentResponses"]
  end

  defp download_batch_responses_file(file_name, opts) do
    with {:ok, api_key} <- api_key(opts),
         {:ok, body} <-
           Req.get(download_file_url(file_name, opts),
             headers: [{"x-goog-api-key", api_key}],
             http_errors: :return,
             receive_timeout: Keyword.get(opts, :receive_timeout, @default_receive_timeout)
           )
           |> handle_response() do
      parse_jsonl_responses(body)
    end
  end

  defp parse_jsonl_responses(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, response} -> {:cont, {:ok, [response | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_jsonl_response, reason, line}}}
      end
    end)
    |> case do
      {:ok, responses} -> {:ok, Enum.reverse(responses)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_jsonl_responses(body), do: {:error, {:invalid_jsonl_body, body}}

  defp normalize_batch(%{"name" => name} = body) do
    {:ok,
     %{
       name: name,
       state: batch_state(body),
       stats: batch_stats(body),
       body: body
     }}
  end

  defp normalize_batch(body), do: {:error, {:invalid_batch_response, body}}

  defp batch_state(body),
    do:
      body["state"] || get_in(body, ["metadata", "state"]) || get_in(body, ["response", "state"])

  defp batch_stats(body),
    do:
      body["batchStats"] || get_in(body, ["metadata", "batchStats"]) ||
        get_in(body, ["response", "batchStats"]) || %{}

  defp prepare_text(text, opts) do
    opts = normalize_task_options(opts)
    %{text: format_text_for_model(text, opts), opts: opts}
  end

  defp normalize_task_options(opts) do
    model = model(opts)
    task = opts |> Keyword.get(:task) |> normalize_task()
    input_role = opts |> Keyword.get(:input_role) |> normalize_input_role()

    opts
    |> Keyword.put(:task, task)
    |> Keyword.put(:input_role, input_role)
    |> Keyword.put(:gemini_2_task_prompt?, gemini_embedding_2?(model) and task != nil)
  end

  defp format_text_for_model(text, opts) do
    if Keyword.get(opts, :gemini_2_task_prompt?) do
      case {Keyword.get(opts, :task), Keyword.get(opts, :input_role)} do
        {:search, :query} ->
          "task: search result | query: #{text}"

        {:search, :document} ->
          "title: #{title_or_none(Keyword.get(opts, :title))} | text: #{text}"

        {:semantic_similarity, _role} ->
          "task: sentence similarity | query: #{text}"

        {:classification, _role} ->
          "task: classification | query: #{text}"

        {:clustering, _role} ->
          "task: clustering | query: #{text}"

        _ ->
          text
      end
    else
      text
    end
  end

  defp task_type(opts) do
    if gemini_embedding_2?(model(opts)) do
      nil
    else
      case {Keyword.get(opts, :task), Keyword.get(opts, :input_role)} do
        {:search, :query} -> "RETRIEVAL_QUERY"
        {:search, :document} -> "RETRIEVAL_DOCUMENT"
        {:semantic_similarity, _role} -> "SEMANTIC_SIMILARITY"
        {:classification, _role} -> "CLASSIFICATION"
        {:clustering, _role} -> "CLUSTERING"
        _ -> nil
      end
    end
  end

  defp request_title(opts) do
    if task_type(opts) == "RETRIEVAL_DOCUMENT" do
      title_or_none(Keyword.get(opts, :title))
    end
  end

  defp title_or_none(nil), do: "none"

  defp title_or_none(title) when is_binary(title) do
    case String.trim(title) do
      "" -> "none"
      title -> title
    end
  end

  defp title_or_none(title), do: to_string(title)

  defp normalize_task(nil), do: nil

  defp normalize_task(task)
       when task in [:search, :semantic_similarity, :classification, :clustering], do: task

  defp normalize_task("search"), do: :search
  defp normalize_task("semantic_similarity"), do: :semantic_similarity
  defp normalize_task("classification"), do: :classification
  defp normalize_task("clustering"), do: :clustering

  defp normalize_input_role(nil), do: nil
  defp normalize_input_role(role) when role in [:query, :document], do: role
  defp normalize_input_role("query"), do: :query
  defp normalize_input_role("document"), do: :document

  defp gemini_embedding_2?(model),
    do: model |> String.trim() |> String.trim_leading("models/") == "gemini-embedding-2"

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

  defp embedding_path(model), do: "/#{model_resource(model)}:embedContent"
  defp batch_embedding_path(model), do: "/#{model_resource(model)}:batchEmbedContents"
  defp async_batch_embedding_path(model), do: "/#{model_resource(model)}:asyncBatchEmbedContent"

  defp upload_files_url(opts), do: "#{api_origin(opts)}/upload/v1beta/files"

  defp download_file_url(file_name, opts),
    do: "#{api_origin(opts)}/download/v1beta/#{file_name}:download?alt=media"

  defp api_origin(opts) do
    uri = URI.parse(base_url(opts))

    %URI{scheme: uri.scheme, host: uri.host, port: uri.port}
    |> URI.to_string()
  end

  defp model_resource(model) do
    model =
      model
      |> String.trim()
      |> String.trim_leading("models/")
      |> URI.encode(&URI.char_unreserved?/1)

    "models/#{model}"
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

  defp document_options(document) do
    document
    |> Enum.flat_map(fn
      {:text, _value} -> []
      {"text", _value} -> []
      {key, value} when key in [:title, :key] -> [{key, value}]
      {"title", value} -> [title: value]
      {"key", value} -> [key: value]
      _other -> []
    end)
  end

  defp document_text(%{text: text}) when is_binary(text), do: text
  defp document_text(%{"text" => text}) when is_binary(text), do: text

  defp document_key(document, index) do
    Map.get(document, :key) || Map.get(document, "key") || Integer.to_string(index)
  end

  defp retryable?(%{status: status}) when status in [408, 409, 425, 429], do: true
  defp retryable?(%{status: status}) when status in 500..599, do: true
  defp retryable?(_reason), do: false

  defp max_retries(opts), do: Keyword.get(opts, :max_retries, @default_max_retries)

  defp sleep_before_retry(reason, attempt, opts) do
    delay_ms = retry_delay_ms(reason, attempt, opts)

    Logger.warning(
      "Gemini embedding request failed with #{retry_summary(reason)}; retrying in #{delay_ms}ms (attempt #{attempt + 1}/#{max_retries(opts)})"
    )

    Process.sleep(delay_ms)
  end

  defp retry_delay_ms(reason, attempt, opts) do
    case retry_info_delay_ms(reason) do
      nil -> exponential_retry_delay_ms(attempt, opts)
      delay_ms -> delay_ms + retry_jitter_ms(opts)
    end
  end

  defp exponential_retry_delay_ms(attempt, opts) do
    base = Keyword.get(opts, :retry_base_ms, 500)
    (base * :math.pow(2, attempt)) |> round() |> Kernel.+(retry_jitter_ms(opts))
  end

  defp retry_jitter_ms(opts) do
    base = Keyword.get(opts, :retry_base_ms, 500)
    if base > 0, do: :rand.uniform(base), else: 0
  end

  defp retry_info_delay_ms(%{body: %{"error" => %{"details" => details}}})
       when is_list(details) do
    details
    |> Enum.map(&Map.get(&1, "retryDelay"))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&duration_ms/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp retry_info_delay_ms(_reason), do: nil

  defp duration_ms(value) when is_binary(value) do
    case Regex.run(~r/^([0-9]+)(?:\.([0-9]+))?s$/, value) do
      [_, seconds] ->
        String.to_integer(seconds) * 1000

      [_, seconds, fraction] ->
        fraction_ms =
          fraction
          |> String.pad_trailing(3, "0")
          |> String.slice(0, 3)
          |> String.to_integer()

        String.to_integer(seconds) * 1000 + fraction_ms

      _ ->
        nil
    end
  end

  defp retry_summary(%{status: status, body: %{"error" => %{"status" => error_status}}}),
    do: "HTTP #{status} #{error_status}"

  defp retry_summary(%{status: status}), do: "HTTP #{status}"
  defp retry_summary(reason), do: inspect(reason)
end
