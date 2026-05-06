defmodule Sheaf.BlockPreviews do
  @moduledoc """
  Small previews for block references rendered in assistant Markdown.
  """

  alias RDF.{Description, Graph, Literal}
  alias Sheaf.{Corpus, Document, Id}
  alias Sheaf.NS.{DCTERMS, FABIO, FOAF}
  alias RDF.NS.RDFS

  require OpenTelemetry.Tracer, as: Tracer

  @spec for_ids([String.t()]) :: map()
  def for_ids(ids) when is_list(ids) do
    Tracer.with_span "sheaf.block_previews.for_ids", %{kind: :internal} do
      ids = ids |> Enum.map(&to_string/1) |> Enum.uniq()
      Tracer.set_attribute("sheaf.block_count", length(ids))

      documents_by_id = Corpus.find_documents(ids)

      ids
      |> Enum.flat_map(fn id ->
        case Map.fetch(documents_by_id, id) do
          {:ok, doc_id} -> [{id, doc_id}]
          :error -> []
        end
      end)
      |> Enum.group_by(fn {_id, doc_id} -> doc_id end, fn {id, _doc_id} ->
        id
      end)
      |> previews_for_documents()
      |> Map.new()
    end
  end

  @spec get(String.t()) :: map() | nil
  def get(id) when is_binary(id) do
    Tracer.with_span "sheaf.block_previews.get", %{kind: :internal} do
      Tracer.set_attribute("sheaf.block_id", id)

      id
      |> List.wrap()
      |> for_ids()
      |> Map.get(id)
    end
  end

  defp previews_for_documents(grouped_ids) when map_size(grouped_ids) == 0,
    do: []

  defp previews_for_documents(grouped_ids) do
    metadata_graph = metadata_graph()

    Enum.flat_map(grouped_ids, fn {doc_id, ids} ->
      previews_for_document(doc_id, ids, metadata_graph)
    end)
  end

  defp previews_for_document(doc_id, ids, metadata_graph) do
    case Corpus.graph(doc_id) do
      {:ok, graph} ->
        document_metadata = document_metadata(graph, metadata_graph, doc_id)

        ids
        |> Enum.map(fn id ->
          {id, preview_from_graph(graph, doc_id, id, document_metadata)}
        end)
        |> Enum.reject(fn {_id, preview} -> is_nil(preview) end)

      {:error, _reason} ->
        []
    end
  end

  defp preview_from_graph(graph, doc_id, id, document_metadata) do
    with iri = Id.iri(id),
         type when not is_nil(type) <- Document.block_type(graph, iri),
         text when text != "" <- block_text(graph, iri, type) do
      ancestry = Corpus.ancestry(graph, Id.iri(doc_id), iri)
      document = Enum.find(ancestry, &(&1.type == :document))

      section =
        ancestry |> Enum.reverse() |> Enum.find(&(&1.type == :section))

      %{
        id: id,
        type: type,
        text: text,
        document_id: doc_id,
        document_title: entry_title(document, doc_id),
        document_authors: document_authors(document_metadata),
        document_year: document_year(document_metadata),
        document_status: document_status(document_metadata),
        section_id: entry_id(section),
        section_number:
          section_number(graph, Id.iri(doc_id), entry_id(section)),
        section_title: entry_title(section, nil),
        path: block_path(doc_id, id)
      }
    else
      _other -> nil
    end
  end

  defp metadata_graph do
    case Sheaf.fetch_graph(Sheaf.Repo.metadata_graph()) do
      {:ok, %Graph{} = graph} -> graph
      {:error, _reason} -> Graph.new()
    end
  end

  defp document_metadata(%Graph{} = graph, %Graph{} = metadata, doc_id) do
    doc = Id.iri(doc_id)
    description = RDF.Data.description(graph, doc)
    expression = Description.first(description, FABIO.isRepresentationOf())

    expression =
      expression || first_object(metadata, doc, FABIO.isRepresentationOf())

    %{
      authors: author_names(metadata, expression),
      status: document_status(metadata, expression),
      year:
        first_object(metadata, expression, FABIO.hasPublicationYear())
        |> term_value()
    }
  end

  defp document_authors(%{authors: authors}) when is_list(authors),
    do: authors

  defp document_authors(_metadata), do: []

  defp document_year(%{year: year}) when not is_nil(year), do: to_string(year)
  defp document_year(_metadata), do: nil

  defp document_status(%{status: status}), do: status
  defp document_status(_metadata), do: nil

  defp document_status(_metadata, nil), do: nil

  defp document_status(metadata, expression) do
    status = first_object(metadata, expression, bibo_status())
    label = first_object(metadata, status, RDFS.label())

    (label || status)
    |> status_name()
  end

  defp section_number(_graph, _root, nil), do: nil

  defp section_number(graph, root, section_id) do
    graph
    |> Document.toc(root)
    |> find_section_number(section_id)
    |> case do
      nil -> nil
      number -> Enum.join(number, ".")
    end
  end

  defp find_section_number(entries, section_id) do
    Enum.find_value(entries, fn entry ->
      if entry.id == section_id do
        entry.number
      else
        find_section_number(entry.children, section_id)
      end
    end)
  end

  defp author_names(_metadata, nil), do: []

  defp author_names(metadata, expression) do
    metadata
    |> objects_for(expression, DCTERMS.creator())
    |> Enum.flat_map(fn
      %Literal{} = literal -> [Literal.lexical(literal)]
      author -> first_object(metadata, author, FOAF.name()) |> List.wrap()
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&term_value/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp first_object(_graph, nil, _predicate), do: nil

  defp first_object(graph, subject, predicate) do
    graph
    |> objects_for(subject, predicate)
    |> List.first()
  end

  defp objects_for(_graph, nil, _predicate), do: []

  defp objects_for(%Graph{} = graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {^subject, ^predicate, object} -> [object]
      _triple -> []
    end)
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()

  defp status_name(nil), do: nil

  defp status_name(status) do
    status
    |> term_value()
    |> String.split(["#", "/"])
    |> List.last()
    |> String.replace("-", " ")
    |> String.downcase()
  end

  defp bibo_status, do: RDF.iri("http://purl.org/ontology/bibo/status")

  defp block_text(graph, iri, :paragraph),
    do: Document.paragraph_text(graph, iri)

  defp block_text(graph, iri, :section), do: section_text(graph, iri)
  defp block_text(graph, iri, :row), do: Document.text(graph, iri)

  defp block_text(graph, iri, :extracted),
    do: graph |> Document.source_html(iri) |> plain_text()

  defp block_text(_graph, _iri, _type), do: ""

  defp section_text(graph, iri) do
    graph
    |> section_text_blocks(iri)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp section_text_blocks(graph, iri) do
    heading = Document.heading(graph, iri) |> normalize_plain_text()

    child_blocks =
      graph
      |> Document.children(iri)
      |> Enum.flat_map(&block_text_blocks(graph, &1))

    [heading | child_blocks]
  end

  defp block_text_blocks(graph, iri) do
    case Document.block_type(graph, iri) do
      :section ->
        section_text_blocks(graph, iri)

      :paragraph ->
        [Document.paragraph_text(graph, iri) |> normalize_plain_text()]

      :row ->
        [Document.text(graph, iri) |> normalize_plain_text()]

      :extracted ->
        [graph |> Document.source_html(iri) |> plain_text()]

      _other ->
        []
    end
  end

  defp block_path(doc_id, id) when doc_id == id, do: "/#{doc_id}"
  defp block_path(doc_id, id), do: "/#{doc_id}?block=#{id}#block-#{id}"

  defp entry_id(nil), do: nil
  defp entry_id(%{id: id}), do: id

  defp entry_title(nil, fallback), do: fallback

  defp entry_title(%{title: title}, fallback) when title in [nil, ""],
    do: fallback

  defp entry_title(%{title: title}, _fallback), do: title

  defp plain_text(html) do
    html
    |> to_string()
    |> String.replace(~r/<br\s*\/?>/i, " ")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> normalize_plain_text()
  end

  defp normalize_plain_text(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
