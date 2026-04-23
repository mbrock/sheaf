defmodule Sheaf.GraphStore do
  @moduledoc """
  Fetches, serializes, and replaces named graphs in Fuseki.
  """

  alias SPARQL.Query.Result
  alias Sheaf.Fuseki

  @default_max_update_bytes 200_000

  def fetch_rows(graph_name) when is_binary(graph_name) do
    query = """
    SELECT ?s ?p ?o
    WHERE {
      GRAPH #{Fuseki.iri_ref(graph_name)} {
        ?s ?p ?o .
      }
    }
    ORDER BY STR(?s) STR(?p) STR(?o)
    """

    case Fuseki.select(query) do
      {:ok, %Result{results: rows}} -> {:ok, rows}
      error -> error
    end
  end

  def fetch_graph(graph_name) when is_binary(graph_name) do
    with {:ok, rows} <- fetch_rows(graph_name) do
      {:ok, graph_from_rows(rows)}
    end
  end

  def graph_from_rows(rows) when is_list(rows) do
    RDF.Graph.new(Enum.map(rows, &row_to_triple/1), prefixes: prefixes())
  end

  def backup_graph(graph_name, output_path)
      when is_binary(graph_name) and is_binary(output_path) do
    with {:ok, graph} <- fetch_graph(graph_name) do
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, RDF.Turtle.write_string!(graph, prefixes: prefixes()))
      {:ok, output_path}
    end
  end

  def replace_graph(graph_name, %RDF.Graph{} = graph, opts \\ []) when is_binary(graph_name) do
    max_update_bytes = Keyword.get(opts, :max_update_bytes, @default_max_update_bytes)
    statements = graph |> RDF.NTriples.write_string!() |> String.split("\n", trim: true)

    with :ok <- Fuseki.update("CLEAR SILENT GRAPH #{Fuseki.iri_ref(graph_name)}") do
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

  defp graph_slug(graph_name) do
    graph_name
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
    |> String.downcase()
  end

  defp row_to_triple(%{"s" => subject, "p" => predicate, "o" => object}),
    do: {subject, predicate, object}

  defp insert_batches([], _graph_name, _max_update_bytes), do: {:ok, 0}

  defp insert_batches(statements, graph_name, max_update_bytes) do
    statements
    |> chunk_statements(max_update_bytes)
    |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, inserted} ->
      update = """
      INSERT DATA {
        GRAPH #{Fuseki.iri_ref(graph_name)} {
          #{Enum.join(chunk, "\n")}
        }
      }
      """

      case Fuseki.update(update) do
        :ok -> {:cont, {:ok, inserted + length(chunk)}}
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp chunk_statements(statements, max_update_bytes) do
    {chunks, current_chunk, _current_size} =
      Enum.reduce(statements, {[], [], 0}, fn statement, {chunks, current_chunk, current_size} ->
        statement_size = byte_size(statement) + 1

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
end
