defmodule Sheaf do
  @moduledoc """
  Core helpers for minting resource IRIs and working with the Graph Store.
  """

  alias RDF.{Dataset, Graph, Serialization}

  @dataset_media_type "application/n-quads"
  @graph_media_type "application/n-triples"

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

  @doc """
  Runs a SPARQL query against the configured query endpoint.
  """
  def query(query, opts \\ []) do
    config = Application.fetch_env!(:sheaf, __MODULE__)
    opts = Keyword.put_new(opts, :protocol_version, "1.1")

    SPARQL.Client.query(query, config[:query_endpoint], sparql_options(config, opts))
  end

  @doc """
  Runs a SPARQL SELECT query against the configured query endpoint.

  Hand-written query strings are executed in SPARQL.Client raw mode by default.
  """
  def select(query, opts \\ []) do
    config = Application.fetch_env!(:sheaf, __MODULE__)

    opts =
      opts
      |> Keyword.put_new(:protocol_version, "1.1")
      |> Keyword.put_new(:raw_mode, true)

    SPARQL.Client.select(query, config[:query_endpoint], sparql_options(config, opts))
  end

  @doc """
  Runs a SPARQL update against the configured update endpoint.

  Hand-written update strings are executed in SPARQL.Client raw mode by default.
  """
  def update(update, opts \\ []) do
    config = Application.fetch_env!(:sheaf, __MODULE__)
    endpoint = config[:update_endpoint] || config[:query_endpoint]
    opts = Keyword.put_new(opts, :raw_mode, true)

    SPARQL.Client.update(update, endpoint, sparql_options(config, opts))
  end

  def data_client do
    config = Application.fetch_env!(:sheaf, __MODULE__)

    Req.new(
      url: config[:data_endpoint],
      auth: config[:data_auth],
      http_errors: :raise
    )
  end

  @doc false
  def rpc_eval(gl, code) when is_pid(gl) and is_binary(code) do
    Process.group_leader(self(), gl)
    {result, _bindings} = Code.eval_string(code)
    result
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

  defp sparql_options(config, opts) do
    case sparql_auth_headers(config) do
      headers when map_size(headers) == 0 ->
        opts

      headers ->
        Keyword.update(opts, :headers, headers, &merge_headers(headers, &1))
    end
  end

  defp sparql_auth_headers(config) do
    case config[:sparql_auth] || config[:data_auth] do
      {:basic, credentials} when is_binary(credentials) ->
        %{"Authorization" => "Basic " <> Base.encode64(credentials)}

      nil ->
        %{}
    end
  end

  defp merge_headers(default_headers, headers) when is_map(headers) do
    Map.merge(default_headers, headers)
  end

  defp merge_headers(default_headers, fun) when is_function(fun, 2) do
    fn request, headers -> Map.merge(default_headers, fun.(request, headers)) end
  end

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
