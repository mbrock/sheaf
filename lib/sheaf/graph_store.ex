defmodule Sheaf.GraphStore do
  @moduledoc """
  Reads and writes configured Sheaf graphs via `SPARQL.Client`.
  """

  alias RDF.{Dataset, Graph}
  alias SPARQL.Client
  alias SPARQL.Client.HTTPError

  @default_max_update_bytes 200_000
  @construct_graph_query """
  CONSTRUCT { ?s ?p ?o }
  WHERE {
    ?s ?p ?o .
  }
  """

  def query_endpoint do
    config()[:query_endpoint]
  end

  def update_endpoint do
    config()[:update_endpoint]
  end

  def default_graph do
    config()[:graph]
  end

  def backup_graphs do
    case normalize_graph_names(config()[:backup_graphs]) do
      [] -> normalize_graph_names([default_graph()])
      graph_names -> graph_names
    end
  end

  def fetch_graph(graph_name \\ default_graph(), opts \\ []) when is_binary(graph_name) do
    @construct_graph_query
    |> Client.construct(query_endpoint(), query_options(graph_name, opts))
    |> normalize_result()
    |> case do
      {:ok, %Graph{} = graph} ->
        {:ok, Graph.add_prefixes(graph, prefixes())}

      {:ok, %Dataset{} = dataset} ->
        {:ok, dataset |> RDF.Dataset.default_graph() |> Graph.add_prefixes(prefixes())}

      other ->
        other
    end
  end

  def backup_graph(graph_name, output_path)
      when is_binary(graph_name) and is_binary(output_path) do
    with {:ok, graph} <- fetch_graph(graph_name) do
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, RDF.Turtle.write_string!(graph, prefixes: prefixes()))
      {:ok, output_path}
    end
  end

  def insert_graph(graph_name, %Graph{} = graph, opts \\ []) when is_binary(graph_name) do
    graph_name
    |> named_graph(graph)
    |> Client.insert_data(update_endpoint(), update_options(opts))
    |> normalize_result()
  end

  def delete_graph_data(graph_name, %Graph{} = graph, opts \\ []) when is_binary(graph_name) do
    graph_name
    |> named_graph(graph)
    |> Client.delete_data(update_endpoint(), update_options(opts))
    |> normalize_result()
  end

  def clear_graph(graph_name \\ default_graph(), opts \\ []) when is_binary(graph_name) do
    update_endpoint()
    |> Client.clear(Keyword.merge(update_request_options(opts), graph: graph_name, silent: true))
    |> normalize_result()
  end

  def replace_graph(graph_name, %RDF.Graph{} = graph, opts \\ []) when is_binary(graph_name) do
    max_update_bytes = Keyword.get(opts, :max_update_bytes, @default_max_update_bytes)
    statements = Enum.to_list(graph)

    with :ok <- clear_graph(graph_name, opts) do
      insert_batches(statements, graph_name, max_update_bytes)
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

  def prefixes do
    %{
      prov: "http://www.w3.org/ns/prov#",
      rdf: "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
      rdfs: "http://www.w3.org/2000/01/rdf-schema#",
      sheaf: Sheaf.NS.Sheaf.__base_iri__(),
      xsd: "http://www.w3.org/2001/XMLSchema#"
    }
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

  defp insert_batches([], _graph_name, _max_update_bytes), do: {:ok, 0}

  defp insert_batches(statements, graph_name, max_update_bytes) do
    statements
    |> chunk_statements(max_update_bytes)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, inserted} ->
      chunk_graph = Graph.new(chunk, name: graph_name, prefixes: prefixes())

      case insert_graph(graph_name, chunk_graph) do
        :ok -> {:cont, {:ok, inserted + length(chunk)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp chunk_statements(statements, max_update_bytes) do
    {chunks, current_chunk, _current_size} =
      Enum.reduce(statements, {[], [], 0}, fn statement, {chunks, current_chunk, current_size} ->
        statement_size = statement_size(statement)

        if current_chunk != [] and current_size + statement_size > max_update_bytes do
          {[Enum.reverse(current_chunk) | chunks], [statement], statement_size}
        else
          {chunks, [statement | current_chunk], current_size + statement_size}
        end
      end)

    chunks =
      if current_chunk == [] do
        chunks
      else
        [Enum.reverse(current_chunk) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp statement_size(statement) do
    statement
    |> List.wrap()
    |> Graph.new()
    |> RDF.NTriples.write_string!()
    |> byte_size()
  end

  defp named_graph(graph_name, %Graph{} = graph) do
    Graph.new(Enum.to_list(graph), name: graph_name, prefixes: prefixes())
  end

  defp query_options(graph_name, opts) do
    Keyword.merge(request_options(opts), default_graph: graph_name)
  end

  defp update_options(opts) do
    Keyword.merge(request_options(opts), prefixes: prefixes())
  end

  defp update_request_options(opts) do
    request_options(opts)
  end

  defp request_options(opts) do
    []
    |> maybe_put_headers(opts)
    |> maybe_put_request_opts(opts)
  end

  defp maybe_put_headers(request_opts, opts) do
    if auth_override?(opts) do
      Keyword.put(
        request_opts,
        :headers,
        auth_header_map(
          Keyword.get(opts, :username, config()[:username]),
          Keyword.get(opts, :password, config()[:password])
        )
      )
    else
      request_opts
    end
  end

  defp maybe_put_request_opts(request_opts, opts) do
    case Keyword.fetch(opts, :receive_timeout) do
      {:ok, timeout} ->
        Keyword.put(request_opts, :request_opts, adapter: [receive_timeout: timeout])

      :error ->
        request_opts
    end
  end

  defp auth_override?(opts) do
    Keyword.has_key?(opts, :username) or Keyword.has_key?(opts, :password)
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, %Graph{} = graph}), do: {:ok, graph}
  defp normalize_result({:ok, %Dataset{} = dataset}), do: {:ok, dataset}

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
