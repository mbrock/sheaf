defmodule Sheaf.TextUnits do
  @moduledoc """
  Reads text-bearing RDF units from a dataset with one linear graph walk.

  This is the shared boring path for derived text indexes. It keeps the data as
  RDF terms until callers choose their own projection.
  """

  alias RDF.{BlankNode, Graph, IRI}
  alias RDF.NS.RDFS
  alias Sheaf.NS.{DOC, PROV}

  @valid_kinds ~w(paragraph sourceHtml row)

  def fetch_rows(opts \\ []) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap()

    with {:ok, dataset} <- fetch_dataset(kinds) do
      {:ok, rows(dataset, Keyword.put(opts, :kinds, kinds))}
    end
  end

  def rows(dataset, opts \\ []) do
    kinds = opts |> Keyword.get(:kinds, @valid_kinds) |> List.wrap() |> MapSet.new()
    excluded = excluded_documents(dataset)

    dataset
    |> RDF.Dataset.graphs()
    |> Enum.reject(&(is_nil(&1.name) or MapSet.member?(excluded, &1.name)))
    |> Enum.flat_map(&graph_rows(&1, kinds))
  end

  defp fetch_dataset(kinds) do
    kinds = MapSet.new(kinds)

    patterns =
      [
        {nil, DOC.excludesDocument(), nil, RDF.iri(Sheaf.Workspace.graph())},
        {nil, RDFS.label(), nil, nil},
        {nil, DOC.children(), nil, nil},
        {nil, RDF.first(), nil, nil},
        {nil, RDF.rest(), nil, nil}
      ] ++
        if MapSet.member?(kinds, "paragraph") do
          [
            {nil, DOC.paragraph(), nil, nil},
            {nil, DOC.text(), nil, nil},
            {nil, PROV.wasInvalidatedBy(), nil, nil}
          ]
        else
          []
        end ++
        if MapSet.member?(kinds, "sourceHtml") or MapSet.member?(kinds, "row") do
          [
            {nil, DOC.sourceHtml(), nil, nil},
            {nil, DOC.text(), nil, nil},
            {nil, RDF.type(), RDF.iri(DOC.Row), nil},
            {nil, DOC.sourceBlockType(), nil, nil},
            {nil, DOC.sourcePage(), nil, nil},
            {nil, DOC.spreadsheetRow(), nil, nil},
            {nil, DOC.spreadsheetSource(), nil, nil},
            {nil, DOC.codeCategoryTitle(), nil, nil}
          ]
        else
          []
        end

    patterns
    |> Enum.reduce_while({:ok, RDF.dataset()}, fn pattern, {:ok, dataset} ->
      case Sheaf.Repo.match(pattern) do
        {:ok, part} -> {:cont, {:ok, merge_dataset(dataset, part)}}
        error -> {:halt, error}
      end
    end)
  end

  defp merge_dataset(left, right) do
    right
    |> RDF.Dataset.graphs()
    |> Enum.reduce(left, &RDF.Dataset.add(&2, &1))
  end

  defp graph_rows(graph, kinds) do
    triples = Graph.triples(graph)
    index = index(triples)
    doc_title = first(index, graph.name, RDFS.label())
    paragraph_predicate = DOC.paragraph()
    source_html_predicate = DOC.sourceHtml()
    text_predicate = DOC.text()
    active_subjects = active_subjects(graph, index)

    triples
    |> Enum.flat_map(fn
      {iri, ^paragraph_predicate, paragraph} ->
        if MapSet.member?(kinds, "paragraph") and
             active?(active_subjects, iri) and
             not present?(index, paragraph, PROV.wasInvalidatedBy()) do
          case first(index, paragraph, DOC.text()) do
            nil ->
              []

            text ->
              [
                %{
                  "iri" => iri,
                  "kind" => RDF.literal("paragraph"),
                  "text" => text,
                  "doc" => graph.name,
                  "docTitle" => doc_title
                }
              ]
          end
        else
          []
        end

      {iri, ^source_html_predicate, text} ->
        source_block_type = first(index, iri, DOC.sourceBlockType())

        if MapSet.member?(kinds, "sourceHtml") and active?(active_subjects, iri) and
             source_block_type in [nil, RDF.literal("Text")] and not source_html_noise?(text) do
          [
            %{
              "iri" => iri,
              "kind" => RDF.literal("sourceHtml"),
              "text" => text,
              "doc" => graph.name,
              "docTitle" => doc_title,
              "sourcePage" => first(index, iri, DOC.sourcePage()),
              "sourceBlockType" => source_block_type,
              "spreadsheetRow" => first(index, iri, DOC.spreadsheetRow()),
              "spreadsheetSource" => first(index, iri, DOC.spreadsheetSource()),
              "codeCategoryTitle" => first(index, iri, DOC.codeCategoryTitle())
            }
          ]
        else
          []
        end

      {iri, ^text_predicate, text} ->
        if MapSet.member?(kinds, "row") and active?(active_subjects, iri) and row?(index, iri) do
          [
            %{
              "iri" => iri,
              "kind" => RDF.literal("row"),
              "text" => text,
              "doc" => graph.name,
              "docTitle" => doc_title,
              "spreadsheetRow" => first(index, iri, DOC.spreadsheetRow()),
              "spreadsheetSource" => first(index, iri, DOC.spreadsheetSource()),
              "codeCategoryTitle" => first(index, iri, DOC.codeCategoryTitle())
            }
          ]
        else
          []
        end

      _triple ->
        []
    end)
  end

  defp index(triples) do
    Enum.reduce(triples, %{}, fn {subject, predicate, object}, index ->
      Map.update(index, {subject, predicate}, [object], &[object | &1])
    end)
  end

  defp first(index, subject, predicate) do
    index
    |> Map.get({subject, predicate}, [])
    |> List.first()
  end

  defp present?(index, subject, predicate), do: Map.has_key?(index, {subject, predicate})

  defp active_subjects(%Graph{name: nil}, _index), do: nil

  defp active_subjects(%Graph{name: root}, index) do
    if present?(index, root, DOC.children()) do
      reachable_subjects(index, [root], MapSet.new())
    else
      nil
    end
  end

  defp reachable_subjects(_index, [], visited), do: visited

  defp reachable_subjects(index, [subject | rest], visited) do
    if MapSet.member?(visited, subject) do
      reachable_subjects(index, rest, visited)
    else
      next =
        index
        |> outgoing_objects(subject)
        |> Enum.flat_map(&resource_objects/1)

      reachable_subjects(index, next ++ rest, MapSet.put(visited, subject))
    end
  end

  defp outgoing_objects(index, subject) do
    index
    |> Enum.flat_map(fn
      {{^subject, _predicate}, objects} -> objects
      _entry -> []
    end)
  end

  defp resource_objects(%IRI{} = iri), do: [iri]
  defp resource_objects(%BlankNode{} = blank_node), do: [blank_node]
  defp resource_objects(_term), do: []

  defp active?(nil, _iri), do: true
  defp active?(active_subjects, iri), do: MapSet.member?(active_subjects, iri)

  defp row?(index, iri) do
    present?(index, iri, DOC.spreadsheetRow()) or
      index |> Map.get({iri, RDF.type()}, []) |> Enum.member?(RDF.iri(DOC.Row))
  end

  defp excluded_documents(dataset) do
    workspace = RDF.Dataset.graph(dataset, Sheaf.Workspace.graph()) || Graph.new()
    excludes_document = DOC.excludesDocument()

    workspace
    |> Graph.triples()
    |> Enum.flat_map(fn
      {_workspace, ^excludes_document, doc} -> [doc]
      _triple -> []
    end)
    |> MapSet.new()
  end

  defp source_html_noise?(term) do
    text = term_value(term)

    is_binary(text) and
      (String.contains?(text, ";base64,") or String.contains?(text, "data:image/"))
  end

  defp term_value(nil), do: nil
  defp term_value(term), do: term |> RDF.Term.value() |> to_string()
end
