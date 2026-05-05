defmodule Sheaf.DocumentEdits do
  @moduledoc """
  Transactional edits for Sheaf document block graphs.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias RDF.Graph
  alias RDF.NS.RDFS
  alias Sheaf.{Corpus, Document, Id}
  alias Sheaf.NS.{DOC, PROV}

  @text_block_types [:paragraph, :extracted, :row]

  @doc """
  PubSub topic used for document graph change notifications.
  """
  def topic(document_id), do: "document:#{normalize_id(document_id)}"

  @doc """
  Replaces a paragraph block's text or a section block's heading.
  """
  def replace_block_text(block_id, text, opts \\ []) when is_binary(text) do
    block_id = normalize_id(block_id)

    Tracer.with_span "sheaf.document_edits.replace_block_text", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "transact"},
        {"sheaf.block_id", block_id},
        {"sheaf.text_chars", String.length(text)}
      ]
    } do
      with :ok <- require_id(block_id, "block is required"),
           {:ok, document_id, graph} <- graph_for_block(block_id, opts),
           block = Id.iri(block_id),
           {:ok, type} <- editable_block_type(graph, block_id, block),
           {:ok, result} <-
             replace_block_text_by_type(graph, document_id, block, type, text, opts) do
        Tracer.set_attribute("sheaf.document", document_id)
        Tracer.set_attribute("sheaf.block_type", Atom.to_string(type))
        Tracer.set_attribute("sheaf.statement_count", Map.get(result, :statement_count, 0))
        notify_document_changed(result)
        {:ok, result}
      end
    end
  end

  @doc """
  Replaces a paragraph block's inline markup and matching plain-text revision.
  """
  def replace_block_markup(block_id, markup, opts \\ []) when is_binary(markup) do
    block_id = normalize_id(block_id)

    Tracer.with_span "sheaf.document_edits.replace_block_markup", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "transact"},
        {"sheaf.block_id", block_id},
        {"sheaf.markup_chars", String.length(markup)}
      ]
    } do
      with :ok <- require_id(block_id, "block is required"),
           {:ok, document_id, graph} <- graph_for_block(block_id, opts),
           block = Id.iri(block_id),
           {:ok, :paragraph} <- editable_markup_block_type(graph, block_id, block),
           {:ok, result} <- replace_block_markup(graph, document_id, block, markup, opts) do
        Tracer.set_attribute("sheaf.document", document_id)
        Tracer.set_attribute("sheaf.statement_count", Map.get(result, :statement_count, 0))
        notify_document_changed(result)
        {:ok, result}
      end
    end
  end

  @doc """
  Moves a block relative to another block in the same document.
  """
  def move_block(block_id, target_id, position, opts \\ []) do
    block_id = normalize_id(block_id)
    target_id = normalize_id(target_id)
    position = normalize_position(position)

    Tracer.with_span "sheaf.document_edits.move_block", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "transact"},
        {"sheaf.block_id", block_id},
        {"sheaf.target_id", target_id},
        {"sheaf.position", position || ""}
      ]
    } do
      with :ok <- require_id(block_id, "block is required"),
           :ok <- require_id(target_id, "target is required"),
           {:ok, position} <- require_position(position),
           {:ok, document_id, graph} <- graph_for_block(block_id, opts),
           {:ok, ^document_id, _target_graph} <- graph_for_block(target_id, opts),
           block = Id.iri(block_id),
           target = Id.iri(target_id),
           :ok <- require_document_block(graph, block_id, block),
           :ok <- require_document_block(graph, target_id, target),
           :ok <- reject_root_move(document_id, block_id),
           :ok <- reject_self_or_descendant_target(graph, block, target),
           {:ok, old_parent} <- parent_of(graph, block),
           {:ok, new_parent} <- placement_parent(graph, target, position),
           {:ok, changes} <-
             move_children_changes(graph, old_parent, new_parent, block, target, position),
           {:ok, statement_count} <- transact(changes, opts, "move document block") do
        result = %{
          action: :move_block,
          document_id: document_id,
          block_id: block_id,
          target_id: target_id,
          position: position,
          affected_blocks: text_block_ids_in_subtree(graph, block),
          statement_count: statement_count
        }

        notify_document_changed(result)
        {:ok, result}
      end
    end
  end

  @doc """
  Inserts a new paragraph block relative to an existing block.
  """
  def insert_paragraph(target_id, position, text, opts \\ []) when is_binary(text) do
    target_id = normalize_id(target_id)
    position = normalize_position(position)

    Tracer.with_span "sheaf.document_edits.insert_paragraph", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "transact"},
        {"sheaf.target_id", target_id},
        {"sheaf.position", position || ""},
        {"sheaf.text_chars", String.length(text)}
      ]
    } do
      with :ok <- require_id(target_id, "target is required"),
           {:ok, position} <- require_position(position),
           {:ok, document_id, graph} <- graph_for_block(target_id, opts),
           target = Id.iri(target_id),
           :ok <- require_document_block(graph, target_id, target),
           {:ok, parent} <- placement_parent(graph, target, position),
           {:ok, changes, block_id} <-
             insert_paragraph_changes(graph, parent, target, position, text),
           {:ok, statement_count} <- transact(changes, opts, "insert paragraph block") do
        result = %{
          action: :insert_paragraph,
          document_id: document_id,
          block_id: block_id,
          target_id: target_id,
          position: position,
          text: text,
          affected_blocks: [block_id],
          statement_count: statement_count
        }

        notify_document_changed(result)
        {:ok, result}
      end
    end
  end

  @doc """
  Deletes a block and its descendant document blocks.
  """
  def delete_block(block_id, opts \\ []) do
    block_id = normalize_id(block_id)

    Tracer.with_span "sheaf.document_edits.delete_block", %{
      kind: :internal,
      attributes: [
        {"db.system", "quadlog"},
        {"db.operation", "transact"},
        {"sheaf.block_id", block_id}
      ]
    } do
      with :ok <- require_id(block_id, "block is required"),
           {:ok, document_id, graph} <- graph_for_block(block_id, opts),
           block = Id.iri(block_id),
           :ok <- require_document_block(graph, block_id, block),
           :ok <- reject_root_delete(document_id, block_id),
           {:ok, parent} <- parent_of(graph, block),
           affected_blocks = text_block_ids_in_subtree(graph, block),
           {:ok, changes} <- delete_block_changes(graph, parent, block),
           {:ok, statement_count} <- transact(changes, opts, "delete document block") do
        Tracer.set_attribute("sheaf.document", document_id)
        Tracer.set_attribute("sheaf.affected_blocks", Enum.join(affected_blocks, ","))
        Tracer.set_attribute("sheaf.statement_count", statement_count)

        result = %{
          action: :delete_block,
          document_id: document_id,
          block_id: block_id,
          affected_blocks: affected_blocks,
          statement_count: statement_count
        }

        notify_document_changed(result)
        {:ok, result}
      end
    end
  end

  @doc """
  Expands block ids to text-bearing blocks affected by search index updates.
  """
  def text_block_ids(block_ids, opts \\ []) do
    block_ids
    |> List.wrap()
    |> Enum.map(&normalize_id/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, MapSet.new()}, fn block_id, {:ok, acc} ->
      case graph_for_block(block_id, opts) do
        {:ok, _document_id, graph} ->
          block = Id.iri(block_id)
          ids = text_block_ids_in_subtree(graph, block)
          {:cont, {:ok, Enum.reduce(ids, acc, &MapSet.put(&2, &1))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, MapSet.to_list(ids)}
      error -> error
    end
  end

  defp replace_block_text_by_type(graph, document_id, block, :paragraph, text, opts) do
    active_revisions = active_paragraphs(graph, block)
    revision = mint(opts)
    activity = mint(opts)
    generated_at = now()

    assert =
      Graph.new(name: Graph.name(graph))
      |> Graph.add({block, DOC.paragraph(), revision})
      |> Graph.add({revision, RDF.type(), DOC.Paragraph})
      |> Graph.add({revision, DOC.text(), RDF.literal(text)})
      |> Graph.add({revision, PROV.wasGeneratedBy(), activity})
      |> Graph.add({revision, PROV.generatedAtTime(), RDF.literal(generated_at)})
      |> Graph.add({activity, RDF.type(), PROV.Activity})
      |> Graph.add({activity, RDFS.label(), RDF.literal("Assistant paragraph edit")})
      |> add_revision_links(revision, active_revisions)
      |> add_invalidations(activity, active_revisions, generated_at)

    retract = predication_graph(graph, block, DOC.markup())

    changes = compact_changes([{:retract, retract}, {:assert, assert}])

    with {:ok, statement_count} <- transact(changes, opts, "replace paragraph text") do
      {:ok,
       %{
         action: :replace_paragraph_text,
         document_id: document_id,
         block_id: Id.id_from_iri(block),
         block_type: :paragraph,
         text: text,
         previous_text: Document.paragraph_text(graph, block),
         affected_blocks: [Id.id_from_iri(block)],
         statement_count: statement_count
       }}
    end
  end

  defp replace_block_text_by_type(graph, document_id, block, :section, text, opts) do
    retract = predication_graph(graph, block, RDFS.label())

    assert =
      Graph.new({block, RDFS.label(), RDF.literal(text)}, name: Graph.name(graph))

    changes = compact_changes([{:retract, retract}, {:assert, assert}])

    with {:ok, statement_count} <- transact(changes, opts, "change section heading") do
      {:ok,
       %{
         action: :change_section_heading,
         document_id: document_id,
         block_id: Id.id_from_iri(block),
         block_type: :section,
         text: text,
         previous_text: Document.heading(graph, block),
         affected_blocks: [],
         statement_count: statement_count
       }}
    end
  end

  defp replace_block_markup(graph, document_id, block, markup, opts) do
    text = Document.inline_markup_text(markup)
    markup = Document.sanitize_inline_markup(markup)
    active_revisions = active_paragraphs(graph, block)
    revision = mint(opts)
    activity = mint(opts)
    generated_at = now()

    assert =
      Graph.new(name: Graph.name(graph))
      |> Graph.add({block, DOC.markup(), RDF.literal(markup)})
      |> Graph.add({block, DOC.paragraph(), revision})
      |> Graph.add({revision, RDF.type(), DOC.Paragraph})
      |> Graph.add({revision, DOC.text(), RDF.literal(text)})
      |> Graph.add({revision, PROV.wasGeneratedBy(), activity})
      |> Graph.add({revision, PROV.generatedAtTime(), RDF.literal(generated_at)})
      |> Graph.add({activity, RDF.type(), PROV.Activity})
      |> Graph.add({activity, RDFS.label(), RDF.literal("Paragraph markup edit")})
      |> add_revision_links(revision, active_revisions)
      |> add_invalidations(activity, active_revisions, generated_at)

    retract = predication_graph(graph, block, DOC.markup())

    changes = compact_changes([{:retract, retract}, {:assert, assert}])

    with {:ok, statement_count} <- transact(changes, opts, "replace paragraph markup") do
      {:ok,
       %{
         action: :replace_paragraph_markup,
         document_id: document_id,
         block_id: Id.id_from_iri(block),
         block_type: :paragraph,
         markup: markup,
         text: text,
         previous_markup: Document.paragraph_markup(graph, block),
         previous_text: Document.paragraph_text(graph, block),
         affected_blocks: [Id.id_from_iri(block)],
         statement_count: statement_count
       }}
    end
  end

  defp editable_markup_block_type(graph, block_id, block) do
    case Document.block_type(graph, block) do
      :paragraph -> {:ok, :paragraph}
      nil -> {:error, "block #{block_id} is not a document block"}
      type -> {:error, "block #{block_id} is a #{type}, not a markup paragraph"}
    end
  end

  defp editable_block_type(graph, block_id, block) do
    case Document.block_type(graph, block) do
      type when type in [:paragraph, :section] -> {:ok, type}
      nil -> {:error, "block #{block_id} is not a document block"}
      type -> {:error, "block #{block_id} is a #{type}, not a paragraph or section"}
    end
  end

  defp active_paragraphs(graph, block) do
    graph
    |> objects(block, DOC.paragraph())
    |> Enum.reject(&invalidated?(graph, &1))
  end

  defp invalidated?(graph, iri), do: objects(graph, iri, PROV.wasInvalidatedBy()) != []

  defp add_revision_links(graph, _revision, []), do: graph

  defp add_revision_links(graph, revision, old_revisions) do
    Enum.reduce(old_revisions, graph, fn old_revision, graph ->
      Graph.add(graph, {revision, PROV.wasRevisionOf(), old_revision})
    end)
  end

  defp add_invalidations(graph, _activity, [], _generated_at), do: graph

  defp add_invalidations(graph, activity, old_revisions, generated_at) do
    Enum.reduce(old_revisions, graph, fn old_revision, graph ->
      graph
      |> Graph.add({old_revision, PROV.wasInvalidatedBy(), activity})
      |> Graph.add({old_revision, PROV.invalidatedAtTime(), RDF.literal(generated_at)})
    end)
  end

  defp move_children_changes(graph, old_parent, new_parent, block, target, position) do
    old_children = Document.children(graph, old_parent)
    new_children = Document.children(graph, new_parent)

    old_children_after_remove = Enum.reject(old_children, &(&1 == block))

    base_new_children =
      if old_parent == new_parent, do: old_children_after_remove, else: new_children

    with {:ok, new_children_after_insert} <-
           insert_child(base_new_children, block, target, position) do
      parent_children =
        [{old_parent, old_children_after_remove}, {new_parent, new_children_after_insert}]
        |> Enum.reverse()
        |> Enum.uniq_by(&elem(&1, 0))

      changes =
        parent_children
        |> Enum.flat_map(fn {parent, children} ->
          replace_children_changes(graph, parent, children)
        end)
        |> compact_changes()

      {:ok, changes}
    end
  end

  defp insert_paragraph_changes(graph, parent, target, position, text) do
    block = mint()
    revision = mint()

    new_block_graph =
      Graph.new(name: Graph.name(graph))
      |> Graph.add({block, RDF.type(), DOC.ParagraphBlock})
      |> Graph.add({block, DOC.paragraph(), revision})
      |> Graph.add({revision, RDF.type(), DOC.Paragraph})
      |> Graph.add({revision, DOC.text(), RDF.literal(text)})

    with {:ok, children} <-
           insert_child(Document.children(graph, parent), block, target, position) do
      changes =
        graph
        |> replace_children_changes(parent, children)
        |> Kernel.++([{:assert, new_block_graph}])
        |> compact_changes()

      {:ok, changes, Id.id_from_iri(block)}
    end
  end

  defp delete_block_changes(graph, parent, block) do
    children = Document.children(graph, parent)

    if block in children do
      changes =
        graph
        |> replace_children_changes(parent, Enum.reject(children, &(&1 == block)))
        |> Kernel.++([{:retract, deleted_subtree_graph(graph, block)}])
        |> compact_changes()

      {:ok, changes}
    else
      {:error, "block #{Id.id_from_iri(block)} is not a child of its parent"}
    end
  end

  defp deleted_subtree_graph(graph, block) do
    subjects =
      graph
      |> deleted_subtree_subjects(block)
      |> MapSet.new()

    graph
    |> Graph.triples()
    |> Enum.filter(fn {subject, _predicate, _object} -> MapSet.member?(subjects, subject) end)
    |> Graph.new(name: Graph.name(graph))
  end

  defp deleted_subtree_subjects(graph, block) do
    blocks = [block | descendant_blocks(graph, block)]

    list_subjects =
      blocks
      |> Enum.flat_map(fn block ->
        case object(graph, block, DOC.children()) do
          nil -> []
          list -> [list | list_node_subjects(graph, list)]
        end
      end)

    paragraph_revisions =
      Enum.flat_map(blocks, &objects(graph, &1, DOC.paragraph()))

    provenance_activities =
      paragraph_revisions
      |> Enum.flat_map(fn revision ->
        objects(graph, revision, PROV.wasGeneratedBy()) ++
          objects(graph, revision, PROV.wasInvalidatedBy())
      end)

    blocks ++ list_subjects ++ paragraph_revisions ++ provenance_activities
  end

  defp list_node_subjects(graph, list), do: list_node_subjects(graph, list, MapSet.new())
  defp list_node_subjects(_graph, nil, _visited), do: []

  defp list_node_subjects(graph, list, visited) do
    cond do
      list == RDF.nil() ->
        []

      MapSet.member?(visited, list) ->
        []

      true ->
        rest = object(graph, list, RDF.rest())
        [list | list_node_subjects(graph, rest, MapSet.put(visited, list))]
    end
  end

  defp insert_child(children, child, target, "before") do
    insert_adjacent(children, child, target, :before)
  end

  defp insert_child(children, child, target, "after") do
    insert_adjacent(children, child, target, :after)
  end

  defp insert_child(children, child, _target, "first_child"), do: {:ok, [child | children]}
  defp insert_child(children, child, _target, "last_child"), do: {:ok, children ++ [child]}

  defp insert_adjacent(children, child, target, side) do
    if target in children do
      children =
        Enum.flat_map(children, fn
          ^target when side == :before -> [child, target]
          ^target -> [target, child]
          other -> [other]
        end)

      {:ok, children}
    else
      {:error, "target block #{Id.id_from_iri(target)} is not a child of the destination parent"}
    end
  end

  defp placement_parent(graph, target, position) when position in ["before", "after"] do
    parent_of(graph, target)
  end

  defp placement_parent(_graph, target, position)
       when position in ["first_child", "last_child"] do
    {:ok, target}
  end

  defp parent_of(graph, child) do
    graph
    |> Graph.triples()
    |> Enum.find_value(fn {subject, predicate, _object} ->
      if predicate == DOC.children() and child in Document.children(graph, subject) do
        subject
      end
    end)
    |> case do
      nil -> {:error, "block #{Id.id_from_iri(child)} has no parent list"}
      parent -> {:ok, parent}
    end
  end

  defp replace_children_changes(graph, parent, children) do
    [
      {:retract, current_children_graph(graph, parent)},
      {:assert, parent_children_graph(graph, parent, children)}
    ]
  end

  defp current_children_graph(graph, parent) do
    case object(graph, parent, DOC.children()) do
      nil -> Graph.new(name: Graph.name(graph))
      list -> list_link_graph(graph, parent, list)
    end
  end

  defp parent_children_graph(graph, parent, []) do
    Graph.new({parent, DOC.children(), RDF.nil()}, name: Graph.name(graph))
  end

  defp parent_children_graph(graph, parent, children) do
    list = mint()

    children
    |> RDF.list(
      graph: Graph.new({parent, DOC.children(), list}, name: Graph.name(graph)),
      head: list
    )
    |> Map.fetch!(:graph)
  end

  defp list_link_graph(graph, parent, list) do
    [{parent, DOC.children(), list} | list_triples(graph, list)]
    |> Enum.uniq()
    |> Graph.new(name: Graph.name(graph))
  end

  defp list_triples(graph, list), do: list_triples(graph, list, MapSet.new())
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

  defp predication_graph(graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.filter(fn
      {^subject, ^predicate, _object} -> true
      _triple -> false
    end)
    |> Graph.new(name: Graph.name(graph))
  end

  defp compact_changes(changes) do
    Enum.reject(changes, fn {_op, graph} -> Graph.empty?(graph) end)
  end

  defp transact([], _opts, _label), do: {:ok, 0}

  defp transact(changes, opts, label) do
    tx = Keyword.get_lazy(opts, :tx, &Sheaf.mint/0)
    transact = Keyword.get(opts, :transact, &Sheaf.Repo.transact/3)

    statement_count =
      Enum.sum(Enum.map(changes, fn {_op, graph} -> RDF.Data.statement_count(graph) end))

    case transact.(tx, changes, [
           {"sheaf.change", label},
           {"sheaf.statement_count", statement_count}
         ]) do
      :ok -> {:ok, statement_count}
      {:ok, _result} -> {:ok, statement_count}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_transact_result, other}}
    end
  end

  defp notify_document_changed(%{document_id: document_id} = result) do
    if Process.whereis(Sheaf.PubSub) do
      Phoenix.PubSub.broadcast(Sheaf.PubSub, topic(document_id), {:document_changed, result})
    end

    :ok
  end

  defp graph_for_block(block_id, opts) do
    resolver = Keyword.get(opts, :document_resolver, &Corpus.find_document/1)
    graph_fetcher = Keyword.get(opts, :graph_fetcher, &Corpus.graph/1)

    case resolver.(block_id) do
      id when is_binary(id) and id != "" ->
        case graph_fetcher.(id) do
          {:ok, %Graph{} = graph} -> {:ok, id, graph}
          {:error, reason} -> {:error, "could not fetch document #{id}: #{inspect(reason)}"}
          other -> {:error, "could not fetch document #{id}: unexpected result #{inspect(other)}"}
        end

      nil ->
        {:error, "block #{block_id} not found"}

      {:error, reason} ->
        {:error, "could not resolve block #{block_id}: #{inspect(reason)}"}

      other ->
        {:error, "could not resolve block #{block_id}: unexpected result #{inspect(other)}"}
    end
  end

  defp require_document_block(graph, block_id, block) do
    cond do
      Graph.name(graph) == block -> :ok
      Document.block_type(graph, block) != nil -> :ok
      true -> {:error, "block #{block_id} is not a document block"}
    end
  end

  defp reject_root_move(document_id, block_id) do
    if document_id == block_id do
      {:error, "cannot move a document root"}
    else
      :ok
    end
  end

  defp reject_root_delete(document_id, block_id) do
    if document_id == block_id do
      {:error, "cannot delete a document root"}
    else
      :ok
    end
  end

  defp reject_self_or_descendant_target(graph, block, target) do
    cond do
      block == target ->
        {:error, "cannot place a block relative to itself"}

      target in descendant_blocks(graph, block) ->
        {:error, "cannot move a block relative to its own descendant"}

      true ->
        :ok
    end
  end

  defp text_block_ids_in_subtree(graph, block) do
    [block | descendant_blocks(graph, block)]
    |> Enum.filter(&(Document.block_type(graph, &1) in @text_block_types))
    |> Enum.map(&Id.id_from_iri/1)
  end

  defp descendant_blocks(graph, block) do
    graph
    |> Document.children(block)
    |> Enum.flat_map(fn child -> [child | descendant_blocks(graph, child)] end)
  end

  defp object(graph, subject, predicate) do
    Enum.find_value(Graph.triples(graph), fn
      {^subject, ^predicate, object} -> object
      _triple -> nil
    end)
  end

  defp objects(graph, subject, predicate) do
    graph
    |> Graph.triples()
    |> Enum.flat_map(fn
      {^subject, ^predicate, object} -> [object]
      _triple -> []
    end)
  end

  defp require_id("", message), do: {:error, message}
  defp require_id(_id, _message), do: :ok

  defp normalize_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> Id.id_from_iri()
  end

  defp normalize_id(%RDF.IRI{} = iri), do: Id.id_from_iri(iri)
  defp normalize_id(_value), do: ""

  defp normalize_position(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "before" -> "before"
      "previous_sibling" -> "before"
      "after" -> "after"
      "next_sibling" -> "after"
      "first_child" -> "first_child"
      "prepend_child" -> "first_child"
      "last_child" -> "last_child"
      "append_child" -> "last_child"
      _other -> nil
    end
  end

  defp normalize_position(value) when value in [:before, :previous_sibling], do: "before"
  defp normalize_position(value) when value in [:after, :next_sibling], do: "after"
  defp normalize_position(value) when value in [:first_child, :prepend_child], do: "first_child"
  defp normalize_position(value) when value in [:last_child, :append_child], do: "last_child"
  defp normalize_position(_value), do: nil

  defp require_position(nil),
    do: {:error, "position must be before, after, first_child, or last_child"}

  defp require_position(position), do: {:ok, position}

  defp mint(opts \\ []) do
    case Keyword.get(opts, :mint) do
      fun when is_function(fun, 0) -> fun.()
      nil -> Sheaf.mint()
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
