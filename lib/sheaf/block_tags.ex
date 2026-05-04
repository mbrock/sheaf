defmodule Sheaf.BlockTags do
  @moduledoc """
  Workspace-local tags attached directly to document blocks.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.Graph
  alias Sheaf.{Corpus, Document, Id}
  alias Sheaf.NS.{AS, DOC}

  @tags [
    {"placeholder", RDF.iri(DOC.PlaceholderTag)},
    {"needs_evidence", RDF.iri(DOC.NeedsEvidenceTag)},
    {"needs_revision", RDF.iri(DOC.NeedsRevisionTag)},
    {"fragment", RDF.iri(DOC.FragmentTag)}
  ]

  @tag_names Enum.map(@tags, &elem(&1, 0))
  @tag_index Map.new(@tags)
  @tag_info_by_iri Map.new(@tags, fn {name, iri} ->
                     {iri,
                      %{name: name, label: String.replace(name, "_", " "), iri: to_string(iri)}}
                   end)

  def tag_names, do: @tag_names

  def label(tag_name) do
    tag_name
    |> to_string()
    |> String.replace("_", " ")
  end

  @doc """
  Returns writing tags attached to paragraph blocks reachable in a document graph.

  The result is keyed by short block id:

      %{"PAR111" => [%{name: "needs_evidence", label: "needs evidence", iri: "..."}]}
  """
  def for_document(%Graph{} = graph, root, opts \\ []) do
    root = RDF.iri(root)

    Tracer.with_span "sheaf.block_tags.for_document", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "match"},
        {"sheaf.document", to_string(root)},
        {"sheaf.graph", to_string(Sheaf.Workspace.graph())}
      ]
    } do
      blocks = paragraph_blocks_in_graph(graph, root)

      with {:ok, workspace} <- workspace_graph(opts) do
        tags = tags_for_blocks(workspace, blocks)
        Tracer.set_attribute("sheaf.tagged_block_count", map_size(tags))
        {:ok, tags}
      end
    end
  end

  @doc """
  Attaches writing tags to one or more paragraph blocks in the workspace graph.
  """
  def attach(block_ids, tags, opts \\ []) do
    block_ids = normalize_block_ids(block_ids)
    tag_names = normalize_tag_names(tags)

    Tracer.with_span "sheaf.block_tags.attach", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "assert"},
        {"sheaf.block_ids", Enum.join(block_ids, ",")},
        {"sheaf.tags", Enum.join(tag_names, ",")},
        {"sheaf.graph", to_string(Sheaf.Workspace.graph())}
      ]
    } do
      with :ok <- require_nonempty(block_ids, "blocks is required"),
           :ok <- require_nonempty(tag_names, "tags is required"),
           {:ok, tag_iris} <- tag_iris(tag_names),
           {:ok, blocks} <- paragraph_blocks(block_ids, opts),
           graph = tag_graph(blocks, tag_iris),
           :ok <- persist(graph, opts) do
        statement_count = RDF.Data.statement_count(graph)
        Tracer.set_attribute("sheaf.statement_count", statement_count)

        {:ok,
         %{
           block_ids: Enum.map(blocks, &Id.id_from_iri/1),
           tags: tag_names,
           tag_iris: Enum.map(tag_iris, &to_string/1),
           statement_count: statement_count
         }}
      end
    end
  end

  defp normalize_block_ids(block_ids) do
    block_ids
    |> List.wrap()
    |> Enum.flat_map(&normalize_block_id/1)
    |> Enum.uniq()
  end

  defp normalize_block_id(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("#")

    cond do
      value == "" -> []
      String.starts_with?(value, ["http://", "https://"]) -> [Id.id_from_iri(value)]
      true -> [value]
    end
  end

  defp normalize_block_id(%RDF.IRI{} = iri), do: [Id.id_from_iri(iri)]
  defp normalize_block_id(_value), do: []

  defp normalize_tag_names(tags) do
    tags
    |> List.wrap()
    |> Enum.flat_map(&normalize_tag_name/1)
    |> Enum.uniq()
  end

  defp normalize_tag_name(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("#")
      |> Id.id_from_iri()
      |> Macro.underscore()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    if value == "", do: [], else: [value]
  end

  defp normalize_tag_name(%RDF.IRI{} = iri), do: normalize_tag_name(to_string(iri))
  defp normalize_tag_name(_value), do: []

  defp require_nonempty([], message), do: {:error, message}
  defp require_nonempty(_values, _message), do: :ok

  defp tag_iris(tag_names) do
    invalid = Enum.reject(tag_names, &Map.has_key?(@tag_index, &1))

    case invalid do
      [] -> {:ok, Enum.map(tag_names, &Map.fetch!(@tag_index, &1))}
      _ -> {:error, "unknown writing tag(s): #{Enum.join(invalid, ", ")}"}
    end
  end

  defp workspace_graph(opts) do
    case Keyword.fetch(opts, :workspace_graph) do
      {:ok, %Graph{} = graph} ->
        {:ok, graph}

      :error ->
        workspace = RDF.iri(Sheaf.Workspace.graph())

        with :ok <- Sheaf.Repo.load_once({nil, AS.tag(), nil, workspace}) do
          graph =
            Sheaf.Repo.ask(fn dataset ->
              RDF.Dataset.graph(dataset, workspace) || Graph.new(name: workspace)
            end)

          {:ok, graph}
        end
    end
  end

  defp paragraph_blocks_in_graph(graph, root) do
    root
    |> reachable_blocks(graph)
    |> Enum.filter(&(Document.block_type(graph, &1) == :paragraph))
    |> MapSet.new()
  end

  defp reachable_blocks(root, graph) do
    graph
    |> Document.children(root)
    |> Enum.flat_map(fn child -> [child | reachable_blocks(child, graph)] end)
  end

  defp tags_for_blocks(workspace, blocks) do
    tag_order = Map.new(Enum.with_index(@tag_names))
    tag_predicate = AS.tag()

    workspace
    |> Graph.triples()
    |> Enum.reduce(%{}, fn
      {block, ^tag_predicate, tag}, acc ->
        if MapSet.member?(blocks, block) and Map.has_key?(@tag_info_by_iri, tag) do
          Map.update(acc, Id.id_from_iri(block), [Map.fetch!(@tag_info_by_iri, tag)], fn tags ->
            [Map.fetch!(@tag_info_by_iri, tag) | tags]
          end)
        else
          acc
        end

      _triple, acc ->
        acc
    end)
    |> Map.new(fn {block_id, tags} ->
      tags =
        tags
        |> Enum.uniq_by(& &1.name)
        |> Enum.sort_by(&Map.fetch!(tag_order, &1.name))

      {block_id, tags}
    end)
  end

  defp paragraph_blocks(block_ids, opts) do
    resolver = Keyword.get(opts, :document_resolver, &Corpus.find_document/1)
    graph_fetcher = Keyword.get(opts, :graph_fetcher, &Corpus.graph/1)

    block_ids
    |> Enum.reduce_while({:ok, [], %{}}, fn block_id, {:ok, blocks, graphs} ->
      with {:ok, document_id} <- document_id(block_id, resolver),
           {:ok, graph, graphs} <- document_graph(document_id, graphs, graph_fetcher),
           block = Id.iri(block_id),
           :ok <- require_paragraph_block(block_id, block, graph) do
        {:cont, {:ok, [block | blocks], graphs}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, blocks, _graphs} -> {:ok, Enum.reverse(blocks)}
      error -> error
    end
  end

  defp document_id(block_id, resolver) do
    case resolver.(block_id) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      nil ->
        {:error, "block #{block_id} not found"}

      {:error, reason} ->
        {:error, "could not resolve block #{block_id}: #{inspect(reason)}"}

      other ->
        {:error, "could not resolve block #{block_id}: unexpected result #{inspect(other)}"}
    end
  end

  defp document_graph(document_id, graphs, graph_fetcher) do
    case Map.fetch(graphs, document_id) do
      {:ok, graph} ->
        {:ok, graph, graphs}

      :error ->
        case graph_fetcher.(document_id) do
          {:ok, %Graph{} = graph} ->
            {:ok, graph, Map.put(graphs, document_id, graph)}

          {:error, reason} ->
            {:error, "could not fetch document #{document_id}: #{inspect(reason)}"}

          other ->
            {:error,
             "could not fetch document #{document_id}: unexpected result #{inspect(other)}"}
        end
    end
  end

  defp require_paragraph_block(block_id, block, graph) do
    case Document.block_type(graph, block) do
      :paragraph -> :ok
      nil -> {:error, "block #{block_id} is not a document block"}
      type -> {:error, "block #{block_id} is a #{type}, not a paragraph"}
    end
  end

  defp tag_graph(blocks, tag_iris) do
    Enum.reduce(blocks, Graph.new(name: Sheaf.Workspace.graph()), fn block, graph ->
      Enum.reduce(tag_iris, graph, fn tag, graph ->
        Graph.add(graph, {block, AS.tag(), tag})
      end)
    end)
  end

  defp persist(%Graph{} = graph, opts) do
    persist = Keyword.get(opts, :persist, &Sheaf.Repo.assert/1)

    case persist.(graph) do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_persist_result, other}}
    end
  end
end
