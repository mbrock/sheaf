defmodule SheafWeb.LibraryMarkdownPlug do
  @moduledoc """
  Serves the library index as Markdown when explicitly requested.

  Browser requests continue through the router to the LiveView index.
  """

  import Plug.Conn

  alias SheafWeb.LibraryMarkdown

  require OpenTelemetry.Tracer, as: Tracer

  def init(opts), do: opts

  def call(%{method: "GET", path_info: []} = conn, _opts) do
    if markdown_requested?(conn) do
      send_index(conn)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp send_index(conn) do
    Tracer.with_span "SheafWeb.LibraryMarkdownPlug.send_index", %{
      kind: :server,
      attributes: [
        {"http.request.method", conn.method},
        {"url.path", conn.request_path}
      ]
    } do
      with {:ok, documents} <- Sheaf.Documents.list() do
        Tracer.set_attribute("sheaf.document_count", length(documents))

        conn
        |> put_resp_header("vary", "Accept")
        |> put_resp_content_type("text/markdown", "utf-8")
        |> send_resp(200, LibraryMarkdown.index(documents))
        |> halt()
      else
        {:error, reason} ->
          Tracer.set_attribute("error.type", inspect(reason))

          conn
          |> put_resp_header("vary", "Accept")
          |> put_resp_content_type("text/plain", "utf-8")
          |> send_resp(500, "Could not load the Sheaf library.\n")
          |> halt()
      end
    end
  end

  defp markdown_requested?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn accept ->
      accept
      |> String.downcase()
      |> String.contains?("text/markdown")
    end)
  end
end
