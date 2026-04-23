defmodule Sheaf do
  @moduledoc """
  """

  alias RDF.{Dataset, Graph, TriG, Turtle}

  @dataset_media_type "application/trig"
  @graph_media_type "text/turtle"

  @doc """
  Generates a new unique IRI for a resource.
  """
  def mint do
    Sheaf.Id.iri(Sheaf.Id.generate())
  end

  @doc """
  Fetches the default graph through the Graph Store endpoint.
  """
  def fetch_graph do
    with {:ok, dataset} <- fetch_dataset() do
      {:ok, RDF.Dataset.default_graph(dataset)}
    end
  end

  @doc """
  Fetches a named graph through the Graph Store endpoint.
  """
  def fetch_graph(graph_name) do
    data_endpoint()
    |> Req.get!(
      finch: Sheaf.Finch,
      params: [graph: RDF.IRI.to_string(graph_name)],
      headers: [{"accept", @graph_media_type} | auth_headers()]
    )
    |> case do
      %{status: status, body: body} when status in 200..299 ->
        {:ok, body |> Turtle.read_string!() |> ensure_graph(graph_name)}

      %{status: status, body: body} ->
        {:error, "Failed to fetch graph #{graph_name} (#{status}): #{body}"}
    end
  end

  @doc """
  Loads the whole dataset through the Graph Store endpoint, applies `fun`, and
  replaces the dataset with the result.
  """
  def migrate(fun) when is_function(fun, 1) do
    with {:ok, dataset} <- fetch_dataset(),
         {:ok, migrated_dataset} <- dataset |> fun.() |> normalize_dataset(),
         {:ok, _response} <- put_dataset(migrated_dataset) do
      {:ok, migrated_dataset}
    end
  end

  @doc """
  Fetches the whole dataset through the Graph Store endpoint.
  """
  def fetch_dataset do
    data_endpoint()
    |> Req.get!(
      finch: Sheaf.Finch,
      headers: [{"accept", @dataset_media_type} | auth_headers()]
    )
    |> case do
      %{status: status, body: body} when status in 200..299 ->
        {:ok, body |> TriG.read_string!() |> ensure_dataset()}

      %{status: status, body: body} ->
        {:error, "Failed to fetch dataset (#{status}): #{body}"}
    end
  end

  defp put_dataset(%Dataset{} = dataset) do
    data_endpoint()
    |> Req.put!(
      finch: Sheaf.Finch,
      headers: [{"content-type", @dataset_media_type} | auth_headers()],
      body: TriG.write_string!(dataset)
    )
    |> case do
      %{status: status} = response when status in 200..299 ->
        {:ok, response}

      %{status: status, body: body} ->
        {:error, "Failed to replace dataset (#{status}): #{body}"}
    end
  end

  defp normalize_dataset(%Dataset{} = dataset), do: {:ok, dataset}
  defp normalize_dataset(%Graph{} = graph), do: {:ok, Dataset.new(graph)}

  defp normalize_dataset(other) do
    {:error, "Migration must return an RDF.Dataset or RDF.Graph, got: #{inspect(other)}"}
  end

  defp ensure_dataset(%Dataset{} = dataset), do: dataset
  defp ensure_dataset(%Graph{} = graph), do: Dataset.new(graph)

  defp ensure_graph(%Graph{} = graph, graph_name), do: Graph.new(graph, name: graph_name)
  defp ensure_graph(%Dataset{} = dataset, graph_name), do: Dataset.graph(dataset, graph_name)

  defp auth_headers do
    Application.get_env(:sparql_client, :http_headers, %{})
    |> Enum.map(fn {key, value} -> {String.downcase(to_string(key)), value} end)
  end

  defp data_endpoint, do: Application.get_env(:sheaf, __MODULE__, [])[:data_endpoint]
end
