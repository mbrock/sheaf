defmodule SheafWeb.CorpusController do
  @moduledoc """
  Lightweight Markdown endpoint for corpus search.
  """

  use SheafWeb, :controller

  alias Sheaf.Assistant.ToolResults
  alias SheafWeb.ReadController

  require OpenTelemetry.Tracer, as: Tracer

  def index(conn, %{"parts" => parts} = params) when is_list(parts) do
    params =
      params
      |> Map.delete("parts")
      |> Map.put("q", path_query(parts))

    index(conn, params)
  end

  def index(conn, %{"q" => query} = params) when is_binary(query) do
    document_kind = document_kind(params)

    Tracer.with_span "SheafWeb.CorpusController.index", %{
      query: query,
      document_kind: document_kind || "all"
    } do
      case Sheaf.CorpusSearch.search(query,
             document_kind: document_kind
           ) do
        {:ok, results} ->
          {content_type, body} = response_body(conn, params, results, query)

          conn
          |> put_resp_content_type(content_type, "utf-8")
          |> send_resp(200, body)

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> put_resp_content_type("text/plain", "utf-8")
          |> send_resp(502, "Search failed: #{inspect(reason)}\n")
      end
    end
  end

  def index(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(400, "Missing required query parameter: q\n")
  end

  defp document_kind(%{"kind" => "all"}), do: nil
  defp document_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp document_kind(_params), do: nil

  @doc false
  def path_query(parts) when is_list(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.map(&URI.decode/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp response_body(conn, params, results, query) do
    cond do
      turtle_requested?(conn, params) ->
        {"text/turtle", Sheaf.CorpusSearch.turtle(results, query: query)}

      markdown_requested?(conn, params) ->
        {"text/markdown", Sheaf.CorpusSearch.markdown(results, query: query)}

      true ->
        {"text/html", html_body(results, query)}
    end
  end

  defp turtle_requested?(conn, _params) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn accept ->
      accept
      |> String.downcase()
      |> String.contains?("text/turtle")
    end)
  end

  defp markdown_requested?(conn, _params) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn accept ->
      accept
      |> String.downcase()
      |> String.contains?("text/markdown")
    end)
  end

  defp html_body(%ToolResults.SearchResults{} = results, query) do
    hits = merged_hits(results)

    main =
      if hits == [] do
        ~s(<p>No results found for #{ReadController.escape(inspect(query))}.</p>)
      else
        Enum.map(hits, &ReadController.search_result_html/1)
      end

    ReadController.page(
      %{
        title: "Corpus results for #{query}",
        source_label: "Corpus search",
        authors: [],
        year: nil,
        publisher: nil,
        doi: nil,
        isbn: nil
      },
      main: main
    )
  end

  defp merged_hits(%ToolResults.SearchResults{} = results) do
    results.exact_results ++
      Enum.reject(results.approximate_results, fn approximate ->
        Enum.any?(
          results.exact_results,
          &(&1.block_id == approximate.block_id)
        )
      end)
  end
end
