defmodule Sheaf.SafeFetch do
  @moduledoc """
  Bounded downloads from public HTTPS origins.

  This is intentionally narrower than a general HTTP client: it rejects local
  and private network targets, follows only validated HTTPS redirects, limits
  response bytes, and writes into a caller-provided directory.
  """

  require OpenTelemetry.Tracer, as: Tracer
  import Bitwise

  @default_max_bytes 50 * 1024 * 1024
  @default_redirects 5

  def download_pdf(url, opts \\ []) when is_binary(url) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    redirects = Keyword.get(opts, :redirects, @default_redirects)
    directory = Keyword.get(opts, :directory, System.tmp_dir!())

    Tracer.with_span "Sheaf.SafeFetch.download_pdf", %{
      kind: :client,
      attributes: [
        {"url.full", url},
        {"sheaf.download.max_bytes", max_bytes},
        {"sheaf.download.max_redirects", redirects}
      ]
    } do
      with :ok <- File.mkdir_p(directory),
           {:ok, result} <- download(url, directory, max_bytes, redirects),
           :ok <- verify_pdf(result.path) do
        {:ok, result}
      end
    end
  end

  defp download(_url, _directory, _max_bytes, redirects) when redirects < 0,
    do: {:error, :too_many_redirects}

  defp download(url, directory, max_bytes, redirects) do
    with {:ok, uri} <- public_https_uri(url),
         path <- temporary_path(directory),
         {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      result =
        try do
          request =
            Finch.build(:get, URI.to_string(uri), [
              {"accept", "application/pdf"}
            ])

          Finch.stream_while(
            request,
            Sheaf.Finch,
            %{status: nil, headers: [], bytes: 0, too_large?: false},
            &stream_chunk(&1, &2, io, max_bytes),
            receive_timeout: 60_000
          )
        after
          File.close(io)
        end

      handle_response(result, uri, path, directory, max_bytes, redirects)
    end
  end

  defp stream_chunk({:status, status}, acc, _io, _max_bytes),
    do: {:cont, %{acc | status: status}}

  defp stream_chunk({:headers, headers}, acc, _io, _max_bytes),
    do: {:cont, %{acc | headers: acc.headers ++ headers}}

  defp stream_chunk({:data, data}, acc, io, max_bytes) do
    bytes = acc.bytes + byte_size(data)

    if bytes > max_bytes do
      {:halt, %{acc | bytes: bytes, too_large?: true}}
    else
      :ok = IO.binwrite(io, data)
      {:cont, %{acc | bytes: bytes}}
    end
  end

  defp stream_chunk(_event, acc, _io, _max_bytes), do: {:cont, acc}

  defp handle_response(
         {:ok, %{too_large?: true}},
         _uri,
         path,
         _directory,
         _max,
         _redirects
       ) do
    File.rm(path)
    {:error, :response_too_large}
  end

  defp handle_response(
         {:ok, %{status: status} = response},
         uri,
         path,
         directory,
         max,
         redirects
       )
       when status in 300..399 do
    File.rm(path)

    with location when is_binary(location) <-
           header(response.headers, "location"),
         {:ok, next} <- redirect_uri(uri, location) do
      download(URI.to_string(next), directory, max, redirects - 1)
    else
      nil -> {:error, :redirect_without_location}
      error -> error
    end
  end

  defp handle_response(
         {:ok, %{status: 200, bytes: bytes, headers: headers}},
         uri,
         path,
         _directory,
         _max,
         _redirects
       ) do
    {:ok,
     %{
       path: path,
       url: URI.to_string(uri),
       filename: source_filename(uri, headers),
       byte_size: bytes,
       content_type: header(headers, "content-type")
     }}
  end

  defp handle_response(
         {:ok, %{status: status}},
         _uri,
         path,
         _directory,
         _max,
         _redirects
       ) do
    File.rm(path)
    {:error, {:http_status, status}}
  end

  defp handle_response(
         {:error, reason},
         _uri,
         path,
         _directory,
         _max,
         _redirects
       ) do
    File.rm(path)
    {:error, reason}
  end

  defp public_https_uri(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, :https_required}
      not is_binary(uri.host) or uri.host == "" -> {:error, :missing_host}
      uri.userinfo not in [nil, ""] -> {:error, :userinfo_not_allowed}
      true -> validate_public_host(uri)
    end
  end

  defp validate_public_host(uri) do
    host = String.to_charlist(uri.host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, values} -> values
          {:error, _reason} -> []
        end
      end)

    cond do
      addresses == [] ->
        {:error, :host_not_found}

      Enum.any?(addresses, &private_address?/1) ->
        {:error, :private_network_not_allowed}

      true ->
        {:ok, uri}
    end
  end

  defp private_address?({a, _, _, _}) when a in [0, 10, 127], do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, b, _, _}) when b in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({100, b, _, _}) when b in 64..127, do: true
  defp private_address?({224, _, _, _}), do: true
  defp private_address?({a, _, _, _}) when a >= 240, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    private_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp private_address?({a, _, _, _, _, _, _, _})
       when Bitwise.band(a, 0xFF00) == 0xFF00,
       do: true

  defp private_address?({a, _, _, _, _, _, _, _})
       when Bitwise.band(a, 0xFE00) == 0xFC00, do: true

  defp private_address?({a, _, _, _, _, _, _, _})
       when Bitwise.band(a, 0xFFC0) == 0xFE80, do: true

  defp private_address?(_address), do: false

  defp redirect_uri(base, location) do
    next = base |> URI.merge(location) |> URI.to_string()
    public_https_uri(next)
  rescue
    _error -> {:error, :invalid_redirect}
  end

  defp verify_pdf(path) do
    case File.open(path, [:read, :binary], fn io -> IO.binread(io, 5) end) do
      {:ok, "%PDF-"} ->
        :ok

      {:ok, _other} ->
        File.rm(path)
        {:error, :not_a_pdf}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp header(headers, wanted) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted, do: value
    end)
  end

  defp source_filename(uri, _headers) do
    uri.path
    |> Path.basename()
    |> URI.decode()
    |> case do
      value when value in ["", "/", "."] ->
        "document.pdf"

      value ->
        if(String.ends_with?(String.downcase(value), ".pdf"),
          do: value,
          else: value <> ".pdf"
        )
    end
  end

  defp temporary_path(directory) do
    Path.join(
      directory,
      "sheaf-pdf-#{System.unique_integer([:positive, :monotonic])}.pdf"
    )
  end
end
