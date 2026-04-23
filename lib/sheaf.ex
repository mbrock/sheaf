defmodule Sheaf do
  @moduledoc """
  Core helpers for minting resource IRIs and working with the Graph Store.
  """

  alias RDF.{Dataset, Graph, Serialization}

  use RDF.Vocabulary.Namespace
  require RDF.Turtle

  @dataset_media_type "application/n-quads"
  @graph_media_type "application/n-triples"

  defvocab(DOC,
    base_iri: "https://less.rest/sheaf/",
    file: "../sheaf-schema.ttl"
  )

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
      {:ok, Dataset.default_graph(dataset)}
    end
  end

  @doc """
  Fetches a named graph through the Graph Store endpoint.
  """
  def fetch_graph(graph_name) do
    graph =
      data_client()
      |> Req.get!(
        headers: [accept: @graph_media_type],
        params: [graph: to_string(graph_name)],
        into: :self
      )
      |> read_graph()

    {:ok, graph}
  end

  @doc """
  Replaces a named graph through the Graph Store endpoint.
  """
  def put_graph(graph_name, %Graph{} = graph) do
    Req.put!(
      data_client(),
      headers: [content_type: @graph_media_type],
      params: [graph: to_string(graph_name)],
      body: write_graph(graph)
    )

    :ok
  end

  def data_client do
    config = Application.fetch_env!(:sheaf, __MODULE__)

    Req.new(
      url: config[:data_endpoint],
      auth: config[:data_auth],
      http_errors: :raise
    )
  end

  @doc """
  Loads the whole dataset through the Graph Store endpoint, applies `fun`, and
  replaces the dataset with the result.
  """
  def migrate(fun) when is_function(fun, 1) do
    with {:ok, dataset} <- fetch_dataset(),
         migrated_dataset = fun.(dataset),
         :ok <- put_dataset(migrated_dataset) do
      {:ok, migrated_dataset}
    end
  end

  @doc """
  Fetches the whole dataset through the Graph Store endpoint.
  """
  def fetch_dataset do
    dataset =
      data_client()
      |> Req.get!(headers: [accept: @dataset_media_type], into: :self)
      |> read_dataset()

    {:ok, dataset}
  end

  defp put_dataset(%Dataset{} = dataset) do
    Req.put!(
      data_client(),
      headers: [content_type: @dataset_media_type],
      body: write_dataset(dataset)
    )

    :ok
  end

  defp read_dataset(response) do
    response
    |> Map.fetch!(:body)
    |> lines()
    |> Serialization.read_stream!(media_type: @dataset_media_type)
  end

  defp read_graph(response) do
    response
    |> Map.fetch!(:body)
    |> lines()
    |> Serialization.read_stream!(media_type: @graph_media_type)
  end

  defp write_dataset(dataset),
    do: Serialization.write_stream(dataset, media_type: @dataset_media_type)

  defp write_graph(graph),
    do: Serialization.write_stream(graph, media_type: @graph_media_type)

  # RDF.ex's N-Triples/N-Quads stream decoders expect one statement per item,
  # while Req emits arbitrary network chunks.
  defp lines(chunks) do
    Stream.transform(chunks, fn -> "" end, &split_lines/2, fn
      "" -> []
      line -> [line]
    end)
  end

  defp split_lines(chunk, rest) do
    lines = :binary.split(rest <> chunk, "\n", [:global])
    {complete, [rest]} = Enum.split(lines, -1)

    {Enum.map(complete, &(&1 <> "\n")), rest}
  end
end
