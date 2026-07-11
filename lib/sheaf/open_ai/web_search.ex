defmodule Sheaf.OpenAI.WebSearch do
  @moduledoc """
  Bounded access to OpenAI's server-side web search Responses tool.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @endpoint "https://api.openai.com/v1/responses"
  @default_model "gpt-5.6"
  @default_timeout 120_000

  def search(query, opts \\ []) when is_binary(query) do
    query = String.trim(query)
    model = Keyword.get(opts, :model, @default_model)

    Tracer.with_span "sheaf.openai.web_search", %{
      kind: :client,
      attributes: [
        {"gen_ai.system", "openai"},
        {"gen_ai.request.model", model},
        {"gen_ai.tool.name", "web_search"},
        {"sheaf.web_search.query", query}
      ]
    } do
      with :ok <- require_query(query),
           {:ok, key, _source} <- ReqLLM.Keys.get(:openai, opts),
           {:ok, response} <- request(query, model, key, opts),
           {:ok, result} <- decode(response.body) do
        Tracer.set_attribute("http.response.status_code", response.status)

        Tracer.set_attribute(
          "sheaf.web_search.source_count",
          length(result.sources)
        )

        {:ok, result}
      end
    end
  end

  defp request(query, model, key, opts) do
    request = Keyword.get(opts, :request, &Req.post/2)

    request.(@endpoint,
      auth: {:bearer, key},
      json: %{
        model: model,
        input: query,
        tools: [%{type: "web_search"}],
        store: false
      },
      receive_timeout: Keyword.get(opts, :receive_timeout, @default_timeout)
    )
    |> case do
      {:ok, %Req.Response{status: status} = response}
      when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:openai_web_search_http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode(%{"output" => output}) when is_list(output) do
    text =
      for %{"type" => "message", "content" => content} <- output,
          %{"type" => "output_text", "text" => text} <- content,
          is_binary(text),
          do: text

    sources =
      output
      |> Enum.flat_map(&sources_from_item/1)
      |> Enum.uniq_by(& &1.url)

    case Enum.join(text, "\n\n") |> String.trim() do
      "" -> {:error, :missing_web_search_output}
      text -> {:ok, %{text: text, sources: sources}}
    end
  end

  defp decode(_body), do: {:error, :invalid_web_search_response}

  defp sources_from_item(%{"type" => "message", "content" => content}) do
    for %{"annotations" => annotations} <- content,
        %{"type" => "url_citation", "url" => url} = citation <- annotations,
        is_binary(url),
        do: %{url: url, title: Map.get(citation, "title")}
  end

  defp sources_from_item(_item), do: []

  defp require_query(""), do: {:error, "query is required"}
  defp require_query(_query), do: :ok
end
