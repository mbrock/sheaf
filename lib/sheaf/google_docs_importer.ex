defmodule Sheaf.GoogleDocsImporter do
  @moduledoc """
  Imports a Google Docs `documents.get` JSON payload as a Sheaf document graph.
  """

  require OpenTelemetry.Tracer, as: Tracer
  require RDF.Graph

  alias RDF.{BlankNode, Dataset, Graph, IRI}
  alias RDF.NS.RDFS
  alias Sheaf.NS.{BIRO, CITO, DOC, FABIO, FRBR}

  @default_title "Circulation of Things in a Swapshop in Riga, Latvia"
  @default_previous_document_id "35MZYM"
  @default_expression_id "BHFQTW"

  @doc """
  Imports an accepted-suggestions Google Docs API JSON file into Sheaf.

  Returns `{:ok, summary}` where `summary.document` is the new document IRI.
  """
  def import_file(path, opts \\ []) do
    Tracer.with_span "sheaf.google_docs_importer.import_file", %{
      kind: :internal,
      attributes: [
        {"sheaf.google_docs_importer.path", path},
        {"sheaf.google_docs_importer.title", Keyword.get(opts, :title, @default_title)}
      ]
    } do
      with {:ok, summary} <- build_file(path, opts),
           :ok <- put_document_graph(summary.document, summary.graph),
           :ok <- assert_metadata(summary.document, expression_iri(opts)) do
        {:ok, Map.drop(summary, [:graph])}
      end
    end
  end

  @doc """
  Builds the document graph without writing it.
  """
  def build_file(path, opts \\ []) do
    Tracer.with_span "sheaf.google_docs_importer.build_file", %{
      kind: :internal,
      attributes: [{"sheaf.google_docs_importer.path", path}]
    } do
      with {:ok, bytes} <- File.read(path),
           {:ok, json} <- Jason.decode(bytes) do
        build(json, Keyword.put(opts, :source_path, path))
      end
    end
  end

  @doc """
  Builds a Sheaf document graph from a decoded Google Docs API document.
  """
  def build(json, opts \\ []) when is_map(json) do
    Tracer.with_span "sheaf.google_docs_importer.build", %{kind: :internal} do
      old_document = previous_document_iri(opts)
      document = Keyword.get(opts, :document_iri) || Sheaf.mint()
      reference_index = reference_index(old_document)
      doc_tab = document_tab(json)
      footnotes = Map.get(doc_tab, "footnotes", %{})

      state = %{
        graph: root_graph(document, json, opts),
        root: document,
        stack: [],
        footnotes: footnotes,
        reference_index: reference_index,
        references: %{},
        bibliography?: false,
        blocks_by_parent: %{document => []}
      }

      state =
        doc_tab
        |> get_in(["body", "content"])
        |> List.wrap()
        |> Enum.reduce(state, &add_structural_element/2)
        |> materialize_children()

      references = state.references |> Map.values() |> Enum.uniq()
      graph = add_root_citations(state.graph, document, references)

      summary = %{
        document: document,
        graph: graph,
        title: Keyword.get(opts, :title, @default_title),
        source_url: source_url(json, opts),
        statement_count: RDF.Data.statement_count(graph),
        references_linked: map_size(state.references),
        cited_documents: references,
        cited_document_count: length(references),
        previous_document: old_document,
        expression: expression_iri(opts)
      }

      Tracer.set_attribute("sheaf.statement_count", summary.statement_count)
      Tracer.set_attribute("sheaf.references_linked", summary.references_linked)
      Tracer.set_attribute("sheaf.cited_document_count", summary.cited_document_count)

      {:ok, summary}
    end
  end

  @doc """
  Builds a dry-run replacement plan for swapping one section subtree.

  The plan does not write to Quadlog. It contains:

  * `:retract` - only the current parent `doc:children` list statements
  * `:assert` - a new parent `doc:children` list plus the imported section subtree
  * `:new_section_graph` - the coherent recursive subtree for the imported section
  * `:provenance` - workspace-graph PROV facts for the revision activity

  Existing section resources are left untouched by the planned retraction. They
  become unreachable from the parent list, but remain in the named graph.
  """
  def build_section_replacement_file(path, opts) do
    Tracer.with_span "sheaf.google_docs_importer.build_section_replacement_file", %{
      kind: :internal,
      attributes: [
        {"sheaf.google_docs_importer.path", path},
        {"sheaf.google_docs_importer.old_section_title", Keyword.get(opts, :old_section_title)},
        {"sheaf.google_docs_importer.new_section_title", Keyword.get(opts, :new_section_title)}
      ]
    } do
      document =
        Keyword.get(opts, :document_iri) || Sheaf.Id.iri(Keyword.fetch!(opts, :document_id))

      parent = Keyword.get(opts, :parent_iri, document)
      old_title = Keyword.fetch!(opts, :old_section_title)
      new_title = Keyword.fetch!(opts, :new_section_title)

      with {:ok, existing_graph} <- Sheaf.fetch_graph(document),
           {:ok, imported} <- build_file(path, Keyword.put(opts, :document_iri, document)),
           {:ok, old_section} <- section_iri_by_title(existing_graph, old_title),
           {:ok, new_section} <- section_iri_by_title(imported.graph, new_title),
           {:ok, plan} <-
             section_replacement_plan(
               existing_graph,
               parent,
               old_section,
               imported.graph,
               new_section,
               Keyword.merge(opts,
                 source_url: imported.source_url,
                 source_path: Keyword.get(opts, :source_path, path)
               )
             ) do
        {:ok,
         plan
         |> Map.put(:document, document)
         |> Map.put(:import_summary, Map.drop(imported, [:graph]))}
      end
    end
  end

  @doc """
  Finds a section resource by exact `rdfs:label`.
  """
  def section_iri_by_title(%Graph{} = graph, title) when is_binary(title) do
    matches =
      graph
      |> Graph.triples()
      |> Enum.flat_map(fn
        {subject, predicate, object} ->
          if predicate == RDFS.label() and RDF.Term.value(object) == title and
               Sheaf.Document.block_type(graph, subject) == :section do
            [subject]
          else
            []
          end
      end)
      |> Enum.uniq()

    case matches do
      [section] -> {:ok, section}
      [] -> {:error, {:section_not_found, title}}
      sections -> {:error, {:ambiguous_section_title, title, sections}}
    end
  end

  @doc """
  Returns the recursive RDF subgraph rooted at a section.

  This follows outgoing resource links from the section, which captures nested
  sections, paragraphs, paragraph revisions, RDF list nodes, footnotes, and
  citation/reference links present in the document graph.
  """
  def section_subgraph(%Graph{} = graph, section) do
    resource_subgraph(graph, RDF.iri(section))
  end

  @doc """
  Builds the graphs needed to unlink `old_section` from `parent` and link in
  `new_section` from an imported graph.

  The returned changes are suitable for a later explicit
  `Sheaf.Repo.transact(tx, [{:retract, plan.retract}, {:assert, plan.assert}, {:assert, plan.provenance}])`.
  """
  def section_replacement_plan(
        %Graph{} = existing_graph,
        parent,
        old_section,
        %Graph{} = imported_graph,
        new_section,
        opts \\ []
      ) do
    parent = RDF.iri(parent)
    old_section = RDF.iri(old_section)
    new_section = RDF.iri(new_section)

    with {:ok, old_children} <- children_containing(existing_graph, parent, old_section),
         {:ok, current_parent_list} <- children_list_iri(existing_graph, parent) do
      new_children = Enum.map(old_children, &if(&1 == old_section, do: new_section, else: &1))
      retract = list_link_graph(existing_graph, parent, current_parent_list)
      parent_assert = parent_children_graph(existing_graph, parent, new_children)
      new_section_graph = section_subgraph(imported_graph, new_section)
      assert_graph = Graph.add(parent_assert, new_section_graph)
      provenance_graph = section_replacement_provenance(old_section, new_section, opts)

      {:ok,
       %{
         parent: parent,
         old_section: old_section,
         new_section: new_section,
         old_children: old_children,
         new_children: new_children,
         retract: retract,
         assert: assert_graph,
         provenance: provenance_graph,
         new_section_graph: new_section_graph,
         retract_statement_count: RDF.Data.statement_count(retract),
         assert_statement_count: RDF.Data.statement_count(assert_graph),
         provenance_statement_count: RDF.Data.statement_count(provenance_graph),
         new_section_statement_count: RDF.Data.statement_count(new_section_graph)
       }}
    end
  end

  defp put_document_graph(document, graph) do
    Sheaf.put_graph(document, graph)
  end

  defp assert_metadata(document, expression) do
    graph =
      Graph.new(
        [{document, FABIO.isRepresentationOf(), expression}],
        name: RDF.iri(Sheaf.Repo.metadata_graph())
      )

    Sheaf.Repo.assert(graph)
  end

  defp root_graph(document, json, opts) do
    title = Keyword.get(opts, :title, @default_title)

    Graph.new(name: document)
    |> Graph.add({document, RDF.type(), DOC.Document})
    |> Graph.add({document, RDF.type(), DOC.Thesis})
    |> Graph.add({document, RDFS.label(), RDF.literal(title)})
    |> add_optional_literal(document, DOC.sourceKey(), source_url(json, opts))
  end

  defp add_structural_element(%{"paragraph" => paragraph} = element, state) do
    paragraph = normalize_paragraph(element, paragraph)

    cond do
      paragraph.text == "" ->
        state

      heading_level = heading_level(paragraph) ->
        add_heading(state, paragraph, heading_level)

      true ->
        add_paragraph(state, paragraph)
    end
  end

  defp add_structural_element(_element, state), do: state

  defp add_heading(state, paragraph, level) do
    title = heading_title(paragraph.text)

    if title == "" do
      state
    else
      parent = heading_parent(state.stack, level) || state.root
      section = Sheaf.mint()

      graph =
        state.graph
        |> Graph.add({section, RDF.type(), DOC.Section})
        |> Graph.add({section, RDFS.label(), RDF.literal(title)})
        |> Graph.add({section, DOC.sourceKey(), RDF.literal(source_key(paragraph))})
        |> Graph.add({section, DOC.sourceBlockType(), RDF.literal(paragraph.style)})

      %{
        state
        | graph: graph,
          stack: push_heading(state.stack, %{iri: section, level: level}),
          bibliography?: String.downcase(title) in ["list of sources", "literature sources"],
          blocks_by_parent: append_child(state.blocks_by_parent, parent, section)
      }
      |> ensure_parent(section)
    end
  end

  defp add_paragraph(state, paragraph) do
    parent = current_parent(state)
    block = Sheaf.mint()
    revision = Sheaf.mint()
    markup = paragraph_markup(paragraph, state.footnotes)
    reference = if state.bibliography?, do: match_reference(state.reference_index, paragraph.text)

    graph =
      state.graph
      |> Graph.add({block, RDF.type(), DOC.ParagraphBlock})
      |> Graph.add({block, DOC.paragraph(), revision})
      |> Graph.add({block, DOC.sourceKey(), RDF.literal(source_key(paragraph))})
      |> Graph.add({block, DOC.sourceBlockType(), RDF.literal(paragraph.style)})
      |> Graph.add({revision, RDF.type(), DOC.Paragraph})
      |> Graph.add({revision, DOC.text(), RDF.literal(paragraph.text)})
      |> add_optional_literal(block, DOC.markup(), markup)
      |> add_reference(block, reference)
      |> add_footnotes(block, paragraph, state.footnotes)

    references =
      if reference, do: Map.put(state.references, block, reference), else: state.references

    %{
      state
      | graph: graph,
        references: references,
        blocks_by_parent: append_child(state.blocks_by_parent, parent, block)
    }
  end

  defp materialize_children(state) do
    graph =
      Enum.reduce(state.blocks_by_parent, state.graph, fn
        {_parent, []}, graph ->
          graph

        {parent, children}, graph ->
          list = Sheaf.mint()

          children
          |> RDF.list(graph: Graph.new({parent, DOC.children(), list}), head: list)
          |> Map.fetch!(:graph)
          |> then(&Graph.add(graph, &1))
      end)

    %{state | graph: graph}
  end

  defp resource_subgraph(%Graph{} = graph, root) do
    subjects =
      graph
      |> reachable_subjects([root], MapSet.new())

    triples =
      graph
      |> Graph.triples()
      |> Enum.filter(fn {subject, _predicate, _object} -> MapSet.member?(subjects, subject) end)

    Graph.new(triples, name: Graph.name(graph))
  end

  defp reachable_subjects(_graph, [], visited), do: visited

  defp reachable_subjects(graph, [subject | rest], visited) do
    if MapSet.member?(visited, subject) do
      reachable_subjects(graph, rest, visited)
    else
      next =
        graph
        |> Graph.triples()
        |> Enum.flat_map(fn
          {^subject, _predicate, object} -> resource_objects(object)
          _triple -> []
        end)

      reachable_subjects(graph, next ++ rest, MapSet.put(visited, subject))
    end
  end

  defp resource_objects(%IRI{} = iri), do: [iri]
  defp resource_objects(%BlankNode{} = blank_node), do: [blank_node]
  defp resource_objects(_term), do: []

  defp section_replacement_provenance(old_section, new_section, opts) do
    activity = Keyword.get_lazy(opts, :activity_iri, &Sheaf.mint/0)
    generated_at = Keyword.get_lazy(opts, :generated_at, &now/0)
    source_url = Keyword.get(opts, :source_url)
    source_path = Keyword.get(opts, :source_path)

    RDF.Graph.build activity: activity,
                    old_section: old_section,
                    new_section: new_section,
                    generated_at: generated_at do
      activity
      |> a(Sheaf.NS.PROV.Activity)
      |> RDFS.label("Google Docs section import")
      |> Sheaf.NS.PROV.used(old_section)
      |> Sheaf.NS.PROV.generated(new_section)
      |> Sheaf.NS.PROV.invalidated(old_section)
      |> Sheaf.NS.PROV.endedAtTime(generated_at)

      new_section
      |> Sheaf.NS.PROV.wasRevisionOf(old_section)
      |> Sheaf.NS.PROV.wasGeneratedBy(activity)
      |> Sheaf.NS.PROV.generatedAtTime(generated_at)

      old_section
      |> Sheaf.NS.PROV.wasInvalidatedBy(activity)
      |> Sheaf.NS.PROV.invalidatedAtTime(generated_at)
    end
    |> Graph.change_name(RDF.iri(Sheaf.Repo.workspace_graph()))
    |> add_optional_literal(activity, DOC.sourceKey(), source_url || source_path)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp children_containing(graph, parent, child) do
    children = Sheaf.Document.children(graph, parent)

    if child in children do
      {:ok, children}
    else
      {:error, {:section_not_child, parent, child}}
    end
  end

  defp children_list_iri(graph, parent) do
    case object(graph, parent, DOC.children()) do
      nil -> {:error, {:children_list_not_found, parent}}
      list -> {:ok, list}
    end
  end

  defp parent_children_graph(existing_graph, parent, children) do
    list = Sheaf.mint()

    children
    |> RDF.list(
      graph: Graph.new({parent, DOC.children(), list}, name: Graph.name(existing_graph)),
      head: list
    )
    |> Map.fetch!(:graph)
  end

  defp list_link_graph(graph, parent, list) do
    triples =
      [{parent, DOC.children(), list} | list_triples(graph, list)]
      |> Enum.uniq()

    Graph.new(triples, name: Graph.name(graph))
  end

  defp list_triples(graph, list) do
    list_triples(graph, list, MapSet.new())
  end

  defp list_triples(_graph, nil, _visited), do: []

  defp list_triples(graph, list, visited) do
    cond do
      list == RDF.nil() ->
        []

      MapSet.member?(visited, list) ->
        []

      true ->
        triples =
          graph
          |> Graph.triples()
          |> Enum.filter(fn {subject, predicate, _object} ->
            subject == list and predicate in [RDF.first(), RDF.rest()]
          end)

        rest = object(Graph.new(triples), list, RDF.rest())

        triples ++ list_triples(graph, rest, MapSet.put(visited, list))
    end
  end

  defp object(graph, subject, predicate) do
    Enum.find_value(Graph.triples(graph), fn
      {^subject, ^predicate, object} -> object
      _triple -> nil
    end)
  end

  defp add_root_citations(graph, document, references) do
    Enum.reduce(references, graph, &Graph.add(&2, {document, CITO.cites(), &1}))
  end

  defp add_reference(graph, _block, nil), do: graph

  defp add_reference(graph, block, reference),
    do: Graph.add(graph, {block, BIRO.references(), reference})

  defp add_footnotes(graph, block, paragraph, footnotes) do
    paragraph.footnote_references
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(graph, fn ref, graph ->
      footnote = Sheaf.mint()
      text = footnote_text(Map.get(footnotes, ref.id, %{}))
      markup = footnote_markup(Map.get(footnotes, ref.id, %{}))

      graph
      |> Graph.add({block, DOC.hasFootnote(), footnote})
      |> Graph.add({footnote, RDF.type(), DOC.ParagraphBlock})
      |> Graph.add({footnote, DOC.sourceKey(), RDF.literal("google-docs:footnote:#{ref.id}")})
      |> Graph.add({footnote, DOC.text(), RDF.literal(text)})
      |> add_optional_literal(footnote, DOC.markup(), markup)
    end)
  end

  defp add_optional_literal(graph, _subject, _predicate, nil), do: graph
  defp add_optional_literal(graph, _subject, _predicate, ""), do: graph

  defp add_optional_literal(graph, subject, predicate, value),
    do: Graph.add(graph, {subject, predicate, RDF.literal(value)})

  defp normalize_paragraph(element, paragraph) do
    elements = Map.get(paragraph, "elements", [])
    text = plain_text(elements)

    %{
      start_index: Map.get(element, "startIndex"),
      end_index: Map.get(element, "endIndex"),
      style: get_in(paragraph, ["paragraphStyle", "namedStyleType"]) || "NORMAL_TEXT",
      text: text,
      elements: elements,
      footnote_references: footnote_references(elements)
    }
  end

  defp plain_text(elements) do
    elements
    |> Enum.map_join("", fn
      %{"textRun" => %{"content" => content}} -> content
      %{"footnoteReference" => %{"footnoteNumber" => number}} -> number
      _element -> ""
    end)
    |> clean_text()
  end

  defp clean_text(text) do
    text
    |> String.replace(<<11>>, "")
    |> String.replace(~r/\n$/, "")
    |> String.trim()
  end

  defp heading_level(%{style: "HEADING_" <> level}) do
    case Integer.parse(level) do
      {level, ""} -> level
      _other -> nil
    end
  end

  defp heading_level(%{style: "NORMAL_TEXT", text: text}) do
    case Regex.run(~r/^\d+(?:\.\d+)+\.?\s+\S/u, text) do
      nil -> nil
      _match -> 1 + length(Regex.run(~r/^(\d+(?:\.\d+)+)/, text) |> hd() |> String.split("."))
    end
  end

  defp heading_level(_paragraph), do: nil

  defp heading_title(text) do
    text
    |> String.replace(<<11>>, "")
    |> String.trim()
    |> String.replace(~r/^Chapter\s+\d+\.?\s*/iu, "")
    |> String.replace(~r/^\d+(?:\.\d+)*\.?\s*/u, "")
    |> String.trim()
  end

  defp heading_parent(stack, level) do
    stack
    |> Enum.find(fn heading -> heading.level < level end)
    |> case do
      nil -> nil
      heading -> heading.iri
    end
  end

  defp push_heading(stack, heading) do
    [heading | Enum.reject(stack, &(&1.level >= heading.level))]
  end

  defp current_parent(%{stack: [%{iri: iri} | _rest]}), do: iri
  defp current_parent(%{root: root}), do: root

  defp append_child(blocks_by_parent, parent, child) do
    Map.update(blocks_by_parent, parent, [child], &(&1 ++ [child]))
  end

  defp ensure_parent(state, parent) do
    %{state | blocks_by_parent: Map.put_new(state.blocks_by_parent, parent, [])}
  end

  defp source_key(paragraph) do
    "google-docs:#{paragraph.start_index || "?"}-#{paragraph.end_index || "?"}"
  end

  defp paragraph_markup(paragraph, footnotes) do
    markup =
      paragraph.elements
      |> Enum.map_join("", &element_markup(&1, footnotes))
      |> String.replace(~r/\n$/, "")
      |> String.trim()

    plain = Phoenix.HTML.html_escape(paragraph.text) |> Phoenix.HTML.safe_to_string()

    if markup == "" or markup == plain, do: nil, else: markup
  end

  defp element_markup(%{"textRun" => %{"content" => content} = run}, _footnotes) do
    content
    |> String.replace(<<11>>, "")
    |> html_text_escape()
    |> wrap_text_style(Map.get(run, "textStyle", %{}))
  end

  defp element_markup(
         %{"footnoteReference" => %{"footnoteId" => id, "footnoteNumber" => number}},
         _footnotes
       ) do
    ~s(<sup data-footnote="#{html_attr(number || id)}"></sup>)
  end

  defp element_markup(_element, _footnotes), do: ""

  defp wrap_text_style(markup, style) do
    markup
    |> maybe_wrap("strong", Map.get(style, "bold") == true)
    |> maybe_wrap("em", Map.get(style, "italic") == true)
    |> maybe_wrap("u", Map.get(style, "underline") == true)
    |> maybe_wrap("mark", marked?(style))
    |> maybe_link(style)
  end

  defp maybe_wrap(markup, _tag, false), do: markup
  defp maybe_wrap(markup, tag, true), do: "<#{tag}>#{markup}</#{tag}>"

  defp maybe_link(markup, %{"link" => %{"url" => url}}) when is_binary(url) do
    ~s(<a href="#{html_attr(url)}">#{markup}</a>)
  end

  defp maybe_link(markup, _style), do: markup

  defp marked?(%{"backgroundColor" => %{"color" => %{"rgbColor" => rgb}}}) do
    (Map.get(rgb, "red") || 0) >= 0.95 and
      (Map.get(rgb, "green") || 0) >= 0.85 and
      (Map.get(rgb, "blue") || 0) <= 0.85
  end

  defp marked?(_style), do: false

  defp footnote_references(elements) do
    Enum.flat_map(elements, fn
      %{"footnoteReference" => %{"footnoteId" => id, "footnoteNumber" => number}} ->
        [%{id: id, number: number}]

      _element ->
        []
    end)
  end

  defp footnote_text(%{"content" => content}) do
    content
    |> Enum.flat_map(fn block -> get_in(block, ["paragraph", "elements"]) || [] end)
    |> plain_text()
  end

  defp footnote_text(_footnote), do: ""

  defp footnote_markup(%{"content" => content}) do
    markup =
      content
      |> Enum.flat_map(fn block -> get_in(block, ["paragraph", "elements"]) || [] end)
      |> Enum.map_join("", &element_markup(&1, %{}))
      |> String.replace(~r/\n$/, "")
      |> String.trim()

    text = footnote_text(%{"content" => content})
    plain = Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()

    if markup == "" or markup == plain, do: nil, else: markup
  end

  defp footnote_markup(_footnote), do: nil

  defp match_reference(index, text) do
    doi = doi_from_text(text)

    cond do
      doi && Map.has_key?(index.by_doi, doi) ->
        Map.fetch!(index.by_doi, doi)

      reference_key(text) ->
        text
        |> reference_keys()
        |> Enum.find_value(&Map.get(index.by_key, &1))

      true ->
        nil
    end
  end

  defp reference_index(previous_document) do
    :ok = Sheaf.Repo.load_once({nil, nil, nil, RDF.iri(Sheaf.Repo.metadata_graph())})
    {:ok, old_graph} = Sheaf.fetch_graph(previous_document)

    metadata = Dataset.graph(Sheaf.Repo.dataset(), Sheaf.Repo.metadata_graph()) || Graph.new()
    old_cited = cited_documents(old_graph, previous_document)

    %{
      by_doi: doi_reference_index(metadata, old_cited, local_papers(metadata)),
      by_key: text_reference_index(old_graph)
    }
  end

  defp cited_documents(graph, document) do
    cites = CITO.cites()

    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {^document, ^cites, object} -> [object]
      _triple -> []
    end)
    |> MapSet.new()
  end

  defp doi_reference_index(metadata, old_cited, local_papers) do
    has_doi = FABIO.hasDOI()

    expressions_by_doi =
      metadata
      |> Graph.triples()
      |> Enum.reduce(%{}, fn
        {expression, ^has_doi, object}, acc ->
          Map.put(acc, normalize_doi(RDF.Term.value(object)), expression)

        _triple, acc ->
          acc
      end)

    Map.new(expressions_by_doi, fn {doi, expression} ->
      candidates = reference_candidates(metadata, expression)
      {doi, preferred_reference(candidates, old_cited, local_papers)}
    end)
    |> Enum.reject(fn {_doi, reference} -> is_nil(reference) end)
    |> Map.new()
  end

  defp local_papers(metadata) do
    paper = RDF.iri(DOC.Paper)
    rdf_type = RDF.type()

    metadata
    |> Graph.triples()
    |> Enum.flat_map(fn
      {subject, ^rdf_type, ^paper} -> [subject]
      _triple -> []
    end)
    |> MapSet.new()
  end

  defp reference_candidates(metadata, expression) do
    is_representation_of = FABIO.isRepresentationOf()
    realization_of = FRBR.realizationOf()

    metadata
    |> Graph.triples()
    |> Enum.flat_map(fn
      {doc, ^is_representation_of, ^expression} -> [doc]
      {^expression, ^realization_of, work} -> [work]
      _triple -> []
    end)
    |> Enum.uniq()
  end

  defp preferred_reference(candidates, old_cited, local_papers) do
    Enum.find(candidates, &MapSet.member?(local_papers, &1)) ||
      Enum.find(candidates, &MapSet.member?(old_cited, &1)) ||
      List.first(candidates)
  end

  defp text_reference_index(old_graph) do
    references = BIRO.references()

    old_graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {block, ^references, reference} ->
        old_graph
        |> Sheaf.Document.paragraph_text(block)
        |> reference_keys()
        |> Enum.map(&{&1, reference})

      _triple ->
        []
    end)
    |> Map.new()
  end

  defp reference_key(text), do: text |> reference_keys() |> List.first()

  defp reference_keys(text) do
    normalized = normalize_reference_text(text)

    with [_, author, year, rest] <- Regex.run(~r/^([a-z0-9]+).*?\b(\d{4})\b(.*)$/u, normalized) do
      words =
        rest
        |> String.split(~r/[^a-z0-9]+/u, trim: true)
        |> Enum.reject(&(&1 in ["a", "an", "and", "the", "of", "in", "on", "pp", "ed", "eds"]))

      5..2//-1
      |> Enum.flat_map(fn count ->
        words
        |> Enum.take(count)
        |> case do
          words when length(words) >= 2 -> [Enum.join([author, year | words], ":")]
          _words -> []
        end
      end)
    else
      _other -> []
    end
  end

  defp normalize_reference_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[“”‘’"']/u, "")
    |> String.replace(~r/https?:\/\/\S+/u, "")
  end

  defp doi_from_text(text) do
    case Regex.run(~r/10\.\d{4,9}\/[-._;()\/:A-Z0-9]+/i, text) do
      [doi] -> normalize_doi(doi)
      _other -> nil
    end
  end

  defp normalize_doi(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[.,;:\]\)\}>]+$/, "")
  end

  defp document_tab(%{"tabs" => [tab | _]}) do
    Map.fetch!(tab, "documentTab")
  end

  defp document_tab(json), do: json

  defp source_url(json, opts) do
    Keyword.get(opts, :source_url) ||
      case Map.get(json, "documentId") do
        nil -> configured_source_url()
        id -> "https://docs.google.com/document/d/#{id}/edit?tab=t.0"
      end
  end

  defp configured_source_url do
    :sheaf
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:source_url)
  end

  defp previous_document_iri(opts),
    do:
      opts |> Keyword.get(:previous_document_id, @default_previous_document_id) |> Sheaf.Id.iri()

  defp expression_iri(opts),
    do: opts |> Keyword.get(:expression_id, @default_expression_id) |> Sheaf.Id.iri()

  defp html_escape(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp html_attr(value), do: value |> to_string() |> html_escape()

  defp html_text_escape(value) do
    value
    |> to_string()
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
