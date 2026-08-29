defmodule SheafWeb.ReadController do
  @moduledoc """
  Small static HTML reader for document resources.
  """

  use SheafWeb, :controller

  alias RDF.{Description, Graph}
  alias Sheaf.Assistant.ToolResults
  alias Sheaf.{Document, Id, ResourceResolver}
  alias Sheaf.Document.Markdown
  alias SheafWeb.LibraryMarkdown
  alias Sheaf.NS.{BIBO, DCTERMS, FABIO, FOAF, PRISM}

  require OpenTelemetry.Tracer, as: Tracer

  def export(conn, %{"id" => id}) do
    Tracer.with_span "SheafWeb.ReadController.export", %{
      kind: :internal,
      attributes: [
        {"url.path", conn.request_path},
        {"sheaf.resource_id", id},
        {"sheaf.representation", "markdown"}
      ]
    } do
      case ResourceResolver.resolve(id, skip_block?: true) do
        {:ok, %{kind: :document, id: document_id}} ->
          root = Id.iri(document_id)

          with {:ok, %Graph{} = graph} <- Sheaf.fetch_graph(root) do
            body =
              Markdown.render(graph, root, metadata: metadata(root, graph))

            conn
            |> put_resp_content_type("text/markdown", "utf-8")
            |> send_resp(200, body)
          else
            error -> export_not_found(conn, error)
          end

        error ->
          export_not_found(conn, error)
      end
    end
  end

  def show(conn, %{"id" => id}) do
    representation = representation(conn)

    Tracer.with_span "SheafWeb.ReadController.show", %{
      kind: :internal,
      attributes: [
        {"url.path", conn.request_path},
        {"sheaf.resource_id", id},
        {"sheaf.representation", to_string(representation)}
      ]
    } do
      case read_page(id, representation) do
        {:ok, body} ->
          conn
          |> put_resp_header("vary", "Accept")
          |> put_resp_content_type(content_type(representation), "utf-8")
          |> send_resp(200, body)

        {:error, reason} ->
          Tracer.set_attribute("error.type", inspect(reason))

          conn
          |> put_resp_header("vary", "Accept")
          |> put_status(:not_found)
          |> put_resp_content_type("text/plain", "utf-8")
          |> send_resp(404, "Not found\n")
      end
    end
  end

  defp read_page(id, representation) do
    case ResourceResolver.resolve(id) do
      {:ok, %{kind: :document, id: document_id}} ->
        document_page(document_id, representation)

      {:ok, %{kind: :block, id: block_id, document_id: document_id}} ->
        block_page(document_id, block_id, representation)

      _other ->
        {:error, :not_found}
    end
  end

  defp export_not_found(conn, reason) do
    Tracer.set_attribute("error.type", inspect(reason))

    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(404, "Not found\n")
  end

  defp document_page(document_id, representation) do
    root = Id.iri(document_id)

    with {:ok, %Graph{} = graph} <- Sheaf.fetch_graph(root) do
      metadata = metadata(root, graph)

      case representation do
        :markdown ->
          {:ok, LibraryMarkdown.document(metadata, graph, root)}

        :html ->
          {:ok,
           page(metadata,
             main: [
               ~s(<section aria-labelledby="contents-heading">),
               ~s(<h2 id="contents-heading">Contents</h2>),
               document_toc_html(Document.toc(graph, root)),
               ~s(</section>)
             ]
           )}
      end
    end
  end

  defp block_page(document_id, block_id, representation) do
    root = Id.iri(document_id)
    block = Id.iri(block_id)

    with {:ok, %Graph{} = graph} <- Sheaf.fetch_graph(root),
         type when not is_nil(type) <- Document.block_type(graph, block) do
      metadata = metadata(root, graph)
      breadcrumbs = Document.breadcrumbs(graph, block)

      case representation do
        :markdown ->
          {:ok,
           LibraryMarkdown.resource(
             metadata,
             graph,
             block,
             type,
             breadcrumbs
           )}

        :html ->
          {:ok,
           page(metadata,
             breadcrumbs: breadcrumbs,
             main: render_resource(graph, block, type)
           )}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc false
  def page(metadata, opts) do
    title = metadata.title || "Untitled"

    [
      "<!doctype html>",
      ~s(<html lang="en">),
      "<head>",
      ~s(<meta charset="utf-8">),
      ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
      "<title>#{escape(title)}</title>",
      metadata_links(metadata),
      style(),
      "</head>",
      "<body>",
      source_header(metadata, Keyword.get(opts, :breadcrumbs, []), 1),
      "<main>",
      Keyword.fetch!(opts, :main),
      "</main>",
      "</body>",
      "</html>"
    ]
    |> IO.iodata_to_binary()
  end

  @doc false
  def search_result_html(%ToolResults.SearchHit{} = hit) do
    with document_id when is_binary(document_id) <- hit.document_id,
         block_id when is_binary(block_id) <- hit.block_id,
         root = Id.iri(document_id),
         block = Id.iri(block_id),
         {:ok, %Graph{} = graph} <- Sheaf.fetch_graph(root),
         type when not is_nil(type) <- Document.block_type(graph, block) do
      [
        ~s(<section class="result">),
        source_header(
          metadata(root, graph),
          Document.breadcrumbs(graph, block),
          2
        ),
        render_resource(graph, block, type),
        ~s(</section>)
      ]
    else
      _error ->
        [
          ~s(<section class="result">),
          ~s(<article><p>#{escape(hit.text)}</p></article>),
          ~s(</section>)
        ]
    end
  end

  @doc false
  def render_resource(graph, iri, :section) do
    [
      ~s(<section aria-labelledby="section-heading">),
      ~s(<h2 id="section-heading">#{escape(Document.heading(graph, iri))}</h2>),
      graph
      |> Document.children(iri)
      |> Enum.map(&render_section_child(graph, &1)),
      ~s(</section>)
    ]
  end

  def render_resource(graph, iri, :paragraph) do
    content =
      case Document.paragraph_markup(graph, iri) do
        nil -> escape(Document.paragraph_text(graph, iri))
        markup -> markup
      end

    ~s(<article><p>#{content}</p></article>)
  end

  def render_resource(graph, iri, :extracted) do
    ~s(<article>#{Document.source_html(graph, iri)}</article>)
  end

  def render_resource(graph, iri, :row) do
    ~s(<article><p>#{escape(Document.text(graph, iri))}</p></article>)
  end

  def render_resource(_graph, _iri, _type), do: ""

  defp render_section_child(graph, iri) do
    case Document.block_type(graph, iri) do
      :section ->
        ~s(<p class="section-link"><a href="#{read_path(Document.id(iri))}">#{escape(Document.heading(graph, iri))}</a></p>)

      type ->
        render_resource(graph, iri, type)
    end
  end

  defp document_toc_html([]), do: ~s(<p>No contents available.</p>)
  defp document_toc_html(entries), do: toc_html(entries)

  defp toc_html([]), do: ""

  defp toc_html(entries) do
    [
      "<ol>",
      Enum.map(entries, fn entry ->
        [
          "<li>",
          ~s(<a href="#{read_path(entry.id)}">#{escape(section_title(entry))}</a>),
          toc_html(entry.children),
          "</li>"
        ]
      end),
      "</ol>"
    ]
  end

  defp section_title(%{number: number, title: title}) do
    number =
      number
      |> Enum.join(".")
      |> case do
        "" -> nil
        value -> value
      end

    [number, title]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp breadcrumbs_html([]), do: ""

  defp breadcrumbs_html(breadcrumbs) do
    [
      ~s(<nav aria-label="Breadcrumb">),
      "<ol>",
      Enum.map(breadcrumbs, fn crumb ->
        ~s(<li><a href="#{read_path(crumb.id)}">#{escape(crumb.title)}</a></li>)
      end),
      "</ol>",
      "</nav>"
    ]
  end

  @doc false
  def source_header(metadata, breadcrumbs, level) when level in [1, 2] do
    title = metadata.title || "Untitled"
    heading = if level == 1, do: "h1", else: "h2"

    [
      ~s(<header class="source">),
      ~s(<p class="source-label">#{escape(metadata.source_label || "Source")}</p>),
      "<#{heading}>#{escape(title)}</#{heading}>",
      metadata_html(metadata),
      breadcrumbs_html(breadcrumbs),
      "</header>"
    ]
  end

  @doc false
  def metadata_html(metadata) do
    items =
      [
        metadata.authors |> Enum.join(", "),
        metadata.year,
        metadata.publisher
      ]
      |> Enum.reject(&blank?/1)

    if items == [] do
      ""
    else
      ~s(<p class="meta">#{items |> Enum.map(&escape/1) |> Enum.join(" · ")}</p>)
    end
  end

  @doc false
  def metadata(root, graph) do
    metadata_graph = fetch_metadata_graph()

    expression =
      metadata_graph &&
        first(metadata_graph, root, FABIO.isRepresentationOf())

    %{
      title:
        first_value(metadata_graph, expression, DCTERMS.title()) ||
          first_value(metadata_graph, root, DCTERMS.title()) ||
          Document.title(graph, root),
      source_label:
        source_label(metadata_graph, expression, Document.kind(graph, root)),
      authors: authors(metadata_graph, expression),
      publisher: first_value(metadata_graph, expression, DCTERMS.publisher()),
      year:
        first_value(metadata_graph, expression, FABIO.hasPublicationYear()),
      doi:
        first_value(metadata_graph, expression, FABIO.hasDOI()) ||
          first_value(metadata_graph, expression, BIBO.doi()) ||
          first_value(metadata_graph, expression, PRISM.doi()),
      isbn: first_value(metadata_graph, expression, PRISM.isbn())
    }
  end

  defp metadata_links(metadata) do
    [
      doi_link(metadata.doi),
      identifier_link("isbn", metadata.isbn)
    ]
    |> Enum.reject(&blank?/1)
  end

  defp doi_link(nil), do: ""
  defp doi_link(""), do: ""

  defp doi_link(doi) do
    href = "https://doi.org/#{String.trim_leading(doi, "https://doi.org/")}"
    ~s(<link rel="cite-as" href="#{escape(href)}">)
  end

  defp identifier_link(_name, nil), do: ""
  defp identifier_link(_name, ""), do: ""

  defp identifier_link(name, value) do
    ~s(<meta name="#{escape(name)}" content="#{escape(value)}">)
  end

  defp source_label(nil, _expression, fallback), do: fallback_label(fallback)
  defp source_label(_graph, nil, fallback), do: fallback_label(fallback)

  defp source_label(graph, expression, fallback) do
    graph
    |> objects(expression, RDF.type())
    |> Enum.find_value(&source_type_label/1)
    |> Kernel.||(fallback_label(fallback))
  end

  defp source_type_label(type) do
    case type
         |> term_value()
         |> to_string()
         |> String.split(["#", "/"])
         |> List.last() do
      "Book" -> "Book"
      "BookChapter" -> "Book chapter"
      "JournalArticle" -> "Journal article"
      "ResearchPaper" -> "Journal article"
      "PositionPaper" -> "Position paper"
      "DoctoralThesis" -> "Thesis"
      "ComputerFile" -> "Computer file"
      _other -> nil
    end
  end

  defp fallback_label(:paper), do: "Journal article"
  defp fallback_label(:literature), do: "Publication"
  defp fallback_label(:thesis), do: "Thesis"
  defp fallback_label(:transcript), do: "Transcript"
  defp fallback_label(:spreadsheet), do: "Spreadsheet"
  defp fallback_label(_kind), do: "Source"

  defp authors(nil, _expression), do: []
  defp authors(_graph, nil), do: []

  defp authors(graph, expression) do
    graph
    |> objects(expression, DCTERMS.creator())
    |> Enum.flat_map(fn
      %RDF.Literal{} = literal -> [RDF.Literal.lexical(literal)]
      author -> first_value(graph, author, FOAF.name()) |> List.wrap()
    end)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp fetch_metadata_graph do
    case Sheaf.fetch_graph(Sheaf.Repo.metadata_graph()) do
      {:ok, %Graph{} = graph} -> graph
      _error -> nil
    end
  end

  defp first(nil, _subject, _predicate), do: nil
  defp first(_graph, nil, _predicate), do: nil

  defp first(graph, subject, predicate) do
    graph
    |> Graph.description(subject)
    |> Description.first(predicate)
  end

  defp first_value(graph, subject, predicate) do
    graph
    |> first(subject, predicate)
    |> term_value()
  end

  defp objects(nil, _subject, _predicate), do: []

  defp objects(graph, subject, predicate) do
    graph
    |> Graph.description(subject)
    |> Description.get(predicate, [])
  end

  defp term_value(nil), do: nil

  defp term_value(term) do
    term
    |> RDF.Term.value()
    |> to_string()
  end

  defp read_path(id), do: "/read/#{URI.encode(id, &URI.char_unreserved?/1)}"

  defp representation(conn) do
    if markdown_requested?(conn), do: :markdown, else: :html
  end

  defp content_type(:markdown), do: "text/markdown"
  defp content_type(:html), do: "text/html"

  defp markdown_requested?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(fn accept ->
      accept
      |> String.downcase()
      |> String.contains?("text/markdown")
    end)
  end

  @doc false
  def escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  @doc false
  def style do
    """
    <style>
      :root { color-scheme: light dark; }
      body { max-width: 42rem; margin: 4rem auto; padding: 0 1rem; font: 1.125rem/1.65 Georgia, serif; }
      .source { margin-bottom: 2.5rem; border-bottom: 1px solid color-mix(in srgb, CanvasText 18%, Canvas); padding-bottom: 1rem; }
      h1, h2 { line-height: 1.15; font-weight: 500; }
      h1 { font-size: 1.25rem; margin: 0 0 .35rem; }
      h2 { font-size: 1.35rem; margin: 2rem 0 1rem; }
      .source h2 { font-size: 1.1rem; margin: 0 0 .35rem; }
      a { color: inherit; text-decoration-thickness: .08em; text-underline-offset: .18em; }
      .source-label { margin: 0 0 .35rem; text-transform: uppercase; letter-spacing: .08em; }
      .meta, .source-label, nav { color: color-mix(in srgb, CanvasText 65%, Canvas); font-size: .95rem; }
      .meta { margin: 0 0 .75rem; }
      nav ol { display: flex; flex-wrap: wrap; gap: .25rem .5rem; padding: 0; list-style: none; }
      nav li:not(:last-child)::after { content: "›"; margin-left: .5rem; }
      ol { padding-left: 1.5rem; }
      article, .section-link { margin: 1.2rem 0; }
      .result { margin: 2.5rem 0; }
      .result + .result { border-top: 1px solid color-mix(in srgb, CanvasText 14%, Canvas); padding-top: 2.5rem; }
    </style>
    """
  end
end
