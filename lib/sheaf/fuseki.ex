defmodule Sheaf.Fuseki do
  @moduledoc """
  Thin wrapper around `SPARQL.Client` for the project's named graph in Fuseki.
  """

  alias SPARQL.Client
  alias SPARQL.Client.HTTPError
  alias SPARQL.Query.Result

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
    query
    |> Client.select(query_endpoint(), request_options(opts))
    |> normalize_result()
  end

  def ask(query, opts \\ []) when is_binary(query) do
    query
    |> Client.ask(query_endpoint(), request_options(opts))
    |> normalize_result()
  end

  def update(query, opts \\ []) when is_binary(query) do
    query
    |> Client.update(update_endpoint(), request_options(opts))
    |> normalize_result()
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

  def default_http_headers(_request, _headers) do
    auth_header_map(config()[:username], config()[:password])
  end

  defp request_options(opts) do
    [raw_mode: true]
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

  defp normalize_result({:ok, %Result{} = result}), do: {:ok, result}
  defp normalize_result(:ok), do: :ok

  defp normalize_result({:error, %HTTPError{request: request, status: status}}) do
    body =
      request.http_response_body
      |> Kernel.||("")
      |> String.trim()

    if body == "" do
      {:error, "Fuseki request failed (#{status})"}
    else
      {:error, "Fuseki request failed (#{status}): #{body}"}
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
