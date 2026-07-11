defmodule SheafWeb.ResourceTextPlug do
  @moduledoc """
  Serves a concise Markdown representation of assistant conversations to
  generic text clients while leaving browser HTML, JSON, and RDF negotiation
  unchanged.
  """

  import Plug.Conn

  alias Sheaf.Assistant.ConversationDocument
  alias Sheaf.ResourceResolver

  require OpenTelemetry.Tracer, as: Tracer

  @reserved ~w(api assets b corpus dev health history live phoenix rdf search sheaf-schema.ttl)

  def init(opts), do: opts

  def call(%{method: "GET"} = conn, _opts) do
    with true <- text_request?(conn),
         [id] <- conn.path_info,
         false <- id in @reserved,
         {:ok, %{kind: :assistant_conversation}} <-
           ResourceResolver.resolve(id) do
      send_conversation(conn, id)
    else
      _other -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp send_conversation(conn, id) do
    Tracer.with_span "SheafWeb.ResourceTextPlug.send_conversation", %{
      kind: :server,
      attributes: [
        {"http.request.method", conn.method},
        {"url.path", conn.request_path},
        {"sheaf.assistant.conversation_id", id}
      ]
    } do
      case ConversationDocument.read(id) do
        {:ok, document} ->
          canonical_url = canonical_url(conn)

          conn
          |> put_resp_header("vary", "Accept")
          |> put_resp_header(
            "link",
            ~s(<#{canonical_url}>; rel="canonical", <#{canonical_url}>; rel="alternate"; type="text/html", <#{canonical_url}>; rel="alternate"; type="application/json", <#{canonical_url}>; rel="alternate"; type="application/n-quads")
          )
          |> put_resp_content_type("text/markdown")
          |> send_resp(
            200,
            ConversationDocument.to_markdown(document, canonical_url)
          )
          |> halt()

        {:error, reason} ->
          Tracer.set_attribute("error.type", inspect(reason))

          conn
          |> put_resp_header("vary", "Accept")
          |> put_resp_content_type("text/plain")
          |> send_resp(
            404,
            "Conversation #{id} has no persisted transcript.\n"
          )
          |> halt()
      end
    end
  end

  defp text_request?(conn) do
    case get_req_header(conn, "accept") do
      [] -> true
      accepts -> Enum.any?(accepts, &text_accept?/1)
    end
  end

  defp text_accept?(accept) do
    accept = String.trim(accept)

    accept == "*/*" or String.contains?(accept, "text/markdown") or
      String.contains?(accept, "text/plain")
  end

  defp canonical_url(conn) do
    forwarded_scheme =
      conn
      |> get_req_header("x-forwarded-proto")
      |> List.first()

    scheme =
      case forwarded_scheme do
        nil ->
          to_string(conn.scheme)

        forwarded ->
          forwarded |> String.split(",") |> List.first() |> String.trim()
      end

    default_port? =
      not is_nil(forwarded_scheme) or
        (scheme == "https" and conn.port == 443) or
        (scheme == "http" and conn.port == 80)

    authority =
      if default_port?, do: conn.host, else: "#{conn.host}:#{conn.port}"

    "#{scheme}://#{authority}#{conn.request_path}"
  end
end
