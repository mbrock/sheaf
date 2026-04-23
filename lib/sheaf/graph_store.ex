defmodule Sheaf.GraphStore do
  @moduledoc """
  Reads and backs up configured Sheaf graphs via `SPARQL.Client`.
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

  def backup_graphs do
    case normalize_graph_names(config()[:backup_graphs]) do
      [] -> normalize_graph_names([default_graph()])
      graph_names -> graph_names
    end
  end

  def fetch_graph(graph_name \\ default_graph()) when is_binary(graph_name) do
    @construct_graph_query
    |> Client.construct(query_endpoint(), default_graph: graph_name)
    |> normalize_result()
  end

  def backup_graph(graph_name, output_path)
      when is_binary(graph_name) and is_binary(output_path) do
    with {:ok, graph} <- fetch_graph(graph_name) do
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, RDF.Turtle.write_string!(graph, prefixes: @prefixes))
      {:ok, output_path}
    end
  end

  def default_backup_path(graph_name) when is_binary(graph_name) do
    timestamp =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.to_iso8601()
      |> String.replace(":", "-")

    Path.join(["output", "backups", "#{graph_slug(graph_name)}-#{timestamp}.ttl"])
  end

  def default_http_headers(_request, _headers) do
    auth_header_map(config()[:username], config()[:password])
  end

  defp graph_slug(graph_name) do
    graph_name
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  defp normalize_graph_names(graph_names) do
    graph_names
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_result(:ok), do: :ok
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

  defp auth_header_map(username, password)
       when is_binary(username) and is_binary(password) do
    %{"Authorization" => "Basic " <> Base.encode64("#{username}:#{password}")}
  end

  defp auth_header_map(_, _), do: %{}

  defp format_error(%{reason: reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp config do
    Application.get_env(:sheaf, __MODULE__, [])
  end
end
