defmodule SheafWeb.RDFQuadController do
  use SheafWeb, :controller

  require OpenTelemetry.Tracer, as: Tracer

  def index(conn, params) do
    with {:ok, pattern} <- pattern(params) do
      conn =
        conn
        |> put_resp_content_type("application/n-quads")
        |> send_chunked(200)

      case Quadlog.stream_nquads(Sheaf.Repo.path(), pattern, conn, &chunk/2, []) do
        {:ok, count, conn} ->
          Tracer.set_attribute("sheaf.rdf.quad_count", count)
          conn

        {:error, reason} ->
          raise "failed to stream RDF quads: #{inspect(reason)}"
      end
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: to_string(reason)})
    end
  end

  defp pattern(params) do
    with {:ok, subject} <- resource_param(params, ["s", "subject"]),
         {:ok, predicate} <- iri_param(params, ["p", "predicate"]),
         {:ok, object} <- object_param(params, ["o", "object"]),
         {:ok, graph} <- resource_param(params, ["g", "graph"]) do
      {:ok, {subject, predicate, object, graph}}
    end
  end

  defp iri_param(params, keys) do
    with {:ok, value} <- resource_param(params, keys) do
      case value do
        nil -> {:ok, nil}
        %RDF.IRI{} -> {:ok, value}
        [_ | _] = values -> iri_values(values)
        _ -> {:error, :predicate_must_be_iri}
      end
    end
  end

  defp iri_values(values) do
    if Enum.all?(values, &match?(%RDF.IRI{}, &1)) do
      {:ok, values}
    else
      {:error, :predicate_must_be_iri}
    end
  end

  defp resource_param(params, keys), do: param(params, keys, &parse_resource/1)
  defp object_param(params, keys), do: param(params, keys, &parse_object/1)

  defp param(params, keys, parser) do
    case Enum.find_value(keys, &Map.get(params, &1)) do
      nil -> {:ok, nil}
      values when is_list(values) -> parse_values(values, parser)
      value -> parser.(value)
    end
  end

  defp parse_values(values, parser) do
    values
    |> Enum.reduce_while([], fn value, acc ->
      case parser.(value) do
        {:ok, parsed} -> {:cont, [parsed | acc]}
        error -> {:halt, error}
      end
    end)
    |> case do
      [_ | _] = parsed -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_resource("_:" <> id), do: {:ok, RDF.bnode(id)}

  defp parse_resource(value) when is_binary(value) do
    value = unwrap_iri(value)

    if String.contains?(value, [">", "\n", "\r"]) do
      {:error, :invalid_iri}
    else
      {:ok, RDF.iri(value)}
    end
  end

  defp parse_object("\"" <> _ = value) do
    case RDF.NQuads.read_string("<urn:s> <urn:p> #{value} <urn:g> .") do
      {:ok, dataset} ->
        [{_s, _p, object, _g}] = RDF.Dataset.quads(dataset)
        {:ok, object}

      {:error, _reason} ->
        {:error, :invalid_literal}
    end
  end

  defp parse_object(value), do: parse_resource(value)

  defp unwrap_iri("<" <> value) do
    case String.ends_with?(value, ">") do
      true -> String.slice(value, 0, byte_size(value) - 1)
      false -> "<" <> value
    end
  end

  defp unwrap_iri(value), do: value
end
