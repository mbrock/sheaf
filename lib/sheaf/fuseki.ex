defmodule Sheaf.Fuseki do
  @moduledoc """
  Thin SPARQL client for the project's named graph in Fuseki.
  """

  alias Finch.Response
  alias SPARQL.Query.Result
  alias SPARQL.Query.Result.JSON.Decoder, as: ResultJSON

  @query_headers [
    {"accept", "application/sparql-results+json"},
    {"content-type", "application/x-www-form-urlencoded"}
  ]
  @update_headers [{"content-type", "application/x-www-form-urlencoded"}]

  def query_endpoint do
    config()[:query_endpoint]
  end

  def update_endpoint do
    config()[:update_endpoint]
  end

  def graph do
    config()[:graph]
  end

  def select(query, opts \\ []) when is_binary(query) do
    run(:select, query, query_endpoint(), opts)
  end

  def ask(query, opts \\ []) when is_binary(query) do
    run(:ask, query, query_endpoint(), opts)
  end

  def update(query, opts \\ []) when is_binary(query) do
    run(:update, query, update_endpoint(), opts)
  end

  def graph_ref do
    iri_ref(graph())
  end

  def iri_ref(term) when is_atom(term) do
    term
    |> RDF.Namespace.resolve_term!()
    |> iri_ref()
  end

  def iri_ref(%RDF.IRI{} = iri), do: iri_ref(to_string(iri))
  def iri_ref(iri) when is_binary(iri), do: "<#{iri}>"

  def literal(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    ~s("#{escaped}")
  end

  def ok_boolean?(%Result{results: value}) when is_boolean(value), do: value

  def ok_boolean?(_), do: false

  defp run(:select, query, _endpoint, opts), do: run_query(query, opts)
  defp run(:ask, query, _endpoint, opts), do: run_query(query, opts)
  defp run(:update, query, _endpoint, opts), do: run_update(query, opts)

  defp run_query(query, opts) do
    request =
      Finch.build(
        :post,
        query_endpoint(),
        headers(@query_headers, opts),
        URI.encode_query(query: query)
      )

    with {:ok, body} <- request(request, opts) do
      ResultJSON.decode(body)
    end
  end

  defp run_update(query, opts) do
    request =
      Finch.build(
        :post,
        update_endpoint(),
        headers(@update_headers, opts),
        URI.encode_query(update: query)
      )

    with {:ok, _body} <- request(request, opts) do
      :ok
    end
  end

  defp request(request, opts) do
    timeout = Keyword.get(opts, :receive_timeout, config()[:receive_timeout] || 30_000)

    case Finch.request(request, Sheaf.Finch, receive_timeout: timeout) do
      {:ok, %Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Response{status: status, body: body}} ->
        {:error, "Fuseki request failed (#{status}): #{String.trim(body)}"}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp headers(base_headers, opts) do
    base_headers ++ auth_headers(opts)
  end

  defp auth_headers(opts) do
    case {
      Keyword.get(opts, :username, config()[:username]),
      Keyword.get(opts, :password, config()[:password])
    } do
      {username, password} when is_binary(username) and is_binary(password) ->
        [{"authorization", "Basic " <> Base.encode64("#{username}:#{password}")}]

      _ ->
        []
    end
  end

  defp format_error(%{reason: reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp config do
    Application.get_env(:sheaf, __MODULE__, [])
  end
end
