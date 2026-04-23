defmodule Sheaf.GraphStore do
  @moduledoc """
  Reads configured Sheaf graphs via `SPARQL.Client`.
  """

  alias RDF.{Dataset, Graph}
  alias SPARQL.Client
  alias SPARQL.Client.HTTPError

  @construct_graph_query """
  CONSTRUCT { ?s ?p ?o }
  WHERE {
    ?s ?p ?o .
  }
  """
  @prefixes %{
    prov: "http://www.w3.org/ns/prov#",
    rdf: "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    rdfs: "http://www.w3.org/2000/01/rdf-schema#",
    sheaf: Sheaf.NS.Sheaf.__base_iri__(),
    xsd: "http://www.w3.org/2001/XMLSchema#"
  }

  def fetch_graph(graph_name \\ default_graph()) when is_binary(graph_name) do
    @construct_graph_query
    |> Client.construct(query_endpoint(), default_graph: graph_name)
    |> normalize_result()
  end

  defp normalize_result({:ok, %Graph{} = graph}), do: {:ok, Graph.add_prefixes(graph, @prefixes)}

  defp normalize_result({:ok, %Dataset{} = dataset}) do
    {:ok, dataset |> Dataset.default_graph() |> Graph.add_prefixes(@prefixes)}
  end

  defp normalize_result({:error, %HTTPError{request: request, status: status}}) do
    body =
      request.http_response_body
      |> Kernel.||("")
      |> String.trim()

    if body == "" do
      {:error, "SPARQL request failed (#{status})"}
    else
      {:error, "SPARQL request failed (#{status}): #{body}"}
    end
  end

  defp normalize_result({:error, reason}), do: {:error, format_error(reason)}
  defp normalize_result(other), do: other

  defp default_graph, do: config()[:graph]
  defp query_endpoint, do: config()[:query_endpoint]

  defp format_error(%{reason: reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp config do
    Application.get_env(:sheaf, __MODULE__, [])
  end
end
