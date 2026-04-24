defmodule SheafWeb.API.SparqlController do
  @moduledoc """
  Minimal SPARQL endpoint over the configured query endpoint.

  Accepts `query` on GET or POST. Returns:

    * `application/sparql-results+json` (W3C) for SELECT / ASK
    * `text/turtle` for CONSTRUCT / DESCRIBE

  This is an agent-facing convenience wrapper, not a fully conformant SPARQL
  protocol endpoint. For power use, agents can also talk to the underlying
  Fuseki endpoint directly.
  """

  use SheafWeb, :controller

  alias RDF.{BlankNode, Graph, IRI, Literal}
  alias SPARQL.Query.Result

  def query(conn, params) do
    case query_string(conn, params) do
      {:ok, query} -> run(conn, query)
      :error -> bad_request(conn, "missing 'query' parameter")
    end
  end

  defp query_string(conn, params) do
    cond do
      is_binary(params["query"]) and params["query"] != "" ->
        {:ok, params["query"]}

      match?(["application/sparql-query" <> _], get_req_header(conn, "content-type")) ->
        case read_body(conn) do
          {:ok, body, _conn} when byte_size(body) > 0 -> {:ok, body}
          _ -> :error
        end

      true ->
        :error
    end
  end

  defp run(conn, query) do
    case Sheaf.query(query) do
      {:ok, %Result{} = result} ->
        render_results(conn, result)

      {:ok, %Graph{} = graph} ->
        render_graph(conn, graph)

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "query failed", reason: inspect(reason)})
    end
  rescue
    error ->
      conn
      |> put_status(400)
      |> json(%{error: "query failed", reason: Exception.message(error)})
  end

  defp render_results(conn, %Result{variables: nil, results: boolean})
       when is_boolean(boolean) do
    conn
    |> put_resp_content_type("application/sparql-results+json")
    |> json(%{head: %{}, boolean: boolean})
  end

  defp render_results(conn, %Result{variables: variables, results: rows}) do
    bindings = Enum.map(rows, &binding(&1, variables))

    conn
    |> put_resp_content_type("application/sparql-results+json")
    |> json(%{head: %{vars: variables}, results: %{bindings: bindings}})
  end

  defp binding(row, variables) do
    variables
    |> Enum.reduce(%{}, fn var, acc ->
      case Map.get(row, var) do
        nil -> acc
        term -> Map.put(acc, var, term_json(term))
      end
    end)
  end

  defp term_json(%IRI{value: value}), do: %{type: "uri", value: value}

  defp term_json(%BlankNode{} = bnode) do
    %{type: "bnode", value: bnode |> to_string() |> String.trim_leading("_:")}
  end

  defp term_json(%Literal{} = literal) do
    base = %{type: "literal", value: to_string(Literal.lexical(literal))}

    base
    |> maybe_put("xml:lang", Literal.language(literal))
    |> maybe_put_datatype(literal)
  end

  defp term_json(other), do: %{type: "literal", value: to_string(other)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_datatype(map, literal) do
    case Literal.datatype_id(literal) do
      nil ->
        map

      %IRI{value: "http://www.w3.org/2001/XMLSchema#string"} ->
        map

      datatype ->
        if Literal.language(literal), do: map, else: Map.put(map, "datatype", to_string(datatype))
    end
  end

  defp render_graph(conn, %Graph{} = graph) do
    conn
    |> put_resp_content_type("text/turtle")
    |> send_resp(200, RDF.Turtle.write_string!(graph))
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(400)
    |> json(%{error: message})
  end
end
