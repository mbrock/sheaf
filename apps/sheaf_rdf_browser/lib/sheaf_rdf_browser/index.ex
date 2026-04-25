defmodule SheafRDFBrowser.Index do
  @moduledoc """
  Generic ontology/index view derived from a snapshot `RDF.Dataset`.
  """

  alias RDF.{Dataset, Literal}
  alias RDF.NS.{OWL, RDFS, SKOS}

  @rdf_type RDF.type() |> to_string()
  @rdfs_label RDFS.label() |> to_string()
  @skos_pref_label SKOS.prefLabel() |> to_string()
  @dcterms_title "http://purl.org/dc/terms/title"
  @rdfs_comment RDFS.comment() |> to_string()
  @skos_definition SKOS.definition() |> to_string()
  @dcterms_description "http://purl.org/dc/terms/description"
  @rdfs_subclass RDFS.subClassOf() |> to_string()
  @rdfs_subproperty RDFS.subPropertyOf() |> to_string()
  @rdfs_domain RDFS.domain() |> to_string()
  @rdfs_range RDFS.range() |> to_string()
  @owl_class OWL.Class |> to_string()
  @rdfs_class RDFS.Class |> to_string()
  @bfo_entity "https://node.town/bfo#Entity"
  @owl_object_property OWL.ObjectProperty |> to_string()
  @owl_datatype_property OWL.DatatypeProperty |> to_string()
  @owl_annotation_property OWL.AnnotationProperty |> to_string()
  @rdf_property "http://www.w3.org/1999/02/22-rdf-syntax-ns#Property"
  @hidden_overview_namespaces [
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "http://www.w3.org/2000/01/rdf-schema#",
    "http://www.w3.org/2002/07/owl#",
    "http://www.w3.org/2003/11/swrl#"
  ]

  @label_priority %{
    @skos_pref_label => 0,
    @rdfs_label => 1,
    @dcterms_title => 2
  }

  @comment_priority %{
    @skos_definition => 0,
    @rdfs_comment => 1,
    @dcterms_description => 2
  }

  defstruct labels: %{},
            comments: %{},
            class_counts: %{},
            class_members: %{},
            subclass_edges: MapSet.new(),
            subproperty_edges: MapSet.new(),
            domains: %{},
            ranges: %{},
            graph_counts: %{},
            predicate_counts: %{},
            property_terms: MapSet.new(),
            class_terms: MapSet.new()

  def empty, do: %__MODULE__{}

  def build(dataset) do
    dataset
    |> Dataset.quads()
    |> Enum.reduce(empty(), &index_statement/2)
    |> finalize_sets()
  end

  def build_from_rows(rows) when is_map(rows) do
    empty()
    |> put_counts(:class_counts, Map.get(rows, :class_counts, %{}))
    |> put_counts(:predicate_counts, Map.get(rows, :predicate_counts, %{}))
    |> put_counts(:graph_counts, Map.get(rows, :graph_counts, %{}))
    |> index_label_rows(Map.get(rows, :labels, []))
    |> index_comment_rows(Map.get(rows, :comments, []))
    |> index_type_rows(Map.get(rows, :ontology_types, []))
    |> index_edge_rows(:subclass_edges, :class_terms, Map.get(rows, :subclass_edges, []))
    |> index_edge_rows(:subproperty_edges, :property_terms, Map.get(rows, :subproperty_edges, []))
    |> index_map_set_rows(:domains, :property_terms, :class_terms, Map.get(rows, :domains, []))
    |> index_map_set_rows(:ranges, :property_terms, :class_terms, Map.get(rows, :ranges, []))
    |> with_predicate_counts(Map.get(rows, :predicate_counts, %{}))
    |> mark_counted_classes()
    |> finalize_sets()
  end

  def with_predicate_counts(%__MODULE__{} = index, predicate_counts)
      when is_map(predicate_counts) do
    %{
      index
      | predicate_counts: Map.merge(index.predicate_counts, predicate_counts),
        property_terms:
          predicate_counts
          |> Map.keys()
          |> Enum.reduce(index.property_terms, &MapSet.put(&2, &1))
    }
  end

  def class_rows(%__MODULE__{} = index, limit \\ 120) do
    index.class_terms
    |> Enum.reject(&hidden_overview_term?/1)
    |> Enum.map(fn class ->
      class_row(index, class)
    end)
    |> Enum.sort_by(&property_namespace_label_sort_key/1)
    |> Enum.take(limit)
  end

  def class_tree(%__MODULE__{} = index) do
    relevant_classes = instance_relevant_classes(index)

    visible_classes =
      MapSet.reject(relevant_classes, fn class ->
        blank_node?(class) or hidden_overview_term?(class)
      end)

    children_by_parent =
      index.subclass_edges
      |> Enum.filter(fn {child, parent} ->
        MapSet.member?(visible_classes, child) and MapSet.member?(visible_classes, parent)
      end)
      |> Enum.reduce(%{}, fn {child, parent}, acc ->
        Map.update(acc, parent, MapSet.new([child]), &MapSet.put(&1, child))
      end)

    roots =
      visible_classes
      |> Enum.reject(
        &(parents(index.subclass_edges, &1)
          |> Enum.any?(fn parent -> MapSet.member?(visible_classes, parent) end))
      )
      |> sort_terms(index)
      |> prioritize_bfo_entity()

    roots =
      if roots == [] do
        visible_classes
        |> sort_terms(index)
        |> prioritize_bfo_entity()
        |> Enum.take(80)
      else
        roots
      end

    Enum.map(roots, &class_node(index, &1, children_by_parent, MapSet.new()))
  end

  def class_detail(%__MODULE__{} = index, class) when is_binary(class) do
    class_row(index, class)
  end

  def property_rows(%__MODULE__{} = index, limit \\ 120) do
    index.property_terms
    |> Enum.filter(&(Map.get(index.predicate_counts, &1, 0) > 0))
    |> Enum.reject(&hidden_overview_term?/1)
    |> Enum.map(fn property ->
      property_row(index, property, Map.get(index.predicate_counts, property, 0))
    end)
    |> Enum.sort_by(&property_namespace_label_sort_key/1)
    |> Enum.take(limit)
  end

  def property_usage_rows(%__MODULE__{} = index, usage_rows, limit \\ 120)
      when is_list(usage_rows) do
    usage_rows
    |> Enum.map(fn usage ->
      index
      |> property_row(usage.property, usage.count)
      |> Map.merge(%{
        subject_count: usage.subject_count,
        object_count: usage.object_count
      })
    end)
    |> Enum.sort_by(&{-&1.count, String.downcase(&1.label), &1.id})
    |> Enum.take(limit)
  end

  def label(%__MODULE__{} = index, term) do
    Map.get(index.labels, term) || compact(term)
  end

  def compact(term) when is_binary(term) do
    prefixes()
    |> Enum.find_value(fn {prefix, iri} ->
      if String.starts_with?(term, iri), do: prefix <> ":" <> String.replace_prefix(term, iri, "")
    end)
    |> case do
      nil -> short_iri(term)
      compact -> compact
    end
  end

  def display_term(%__MODULE__{} = index, term) do
    label = Map.get(index.labels, term)

    cond do
      label ->
        %{
          label: label,
          name: label,
          prefix: term_prefix(term),
          namespace: term_namespace(term),
          compact: compact(term),
          labeled?: true
        }

      blank_node?(term) ->
        %{
          label: "blank node",
          name: "blank node",
          prefix: nil,
          namespace: nil,
          compact: term,
          labeled?: false
        }

      true ->
        case split_term(term) do
          {prefix, name} ->
            %{
              label: compact(term),
              name: name,
              prefix: prefix,
              namespace: nil,
              compact: compact(term),
              labeled?: false
            }

          {nil, namespace, name} ->
            %{
              label: compact(term),
              name: name,
              prefix: nil,
              namespace: namespace,
              compact: compact(term),
              labeled?: false
            }

          nil ->
            %{
              label: compact(term),
              name: compact(term),
              prefix: nil,
              namespace: nil,
              compact: compact(term),
              labeled?: false
            }
        end
    end
  end

  defp index_statement({s, p, o, g}, index) do
    s = term_id(s)
    p = term_id(p)
    o_id = term_id(o)
    g = term_id(g)

    index
    |> update_in([Access.key!(:graph_counts), g], &((&1 || 0) + 1))
    |> update_in([Access.key!(:predicate_counts), p], &((&1 || 0) + 1))
    |> index_by_predicate(s, p, o, o_id, g)
  end

  defp put_counts(index, field, counts) do
    put_in(index, [Access.key!(field)], counts)
  end

  defp index_label_rows(index, rows) do
    Enum.reduce(rows, index, fn row, acc ->
      put_ranked_literal(acc, :labels, row.s, row.p, row.o, row.g, @label_priority)
    end)
  end

  defp index_comment_rows(index, rows) do
    Enum.reduce(rows, index, fn row, acc ->
      put_ranked_literal(acc, :comments, row.s, row.p, row.o, row.g, @comment_priority)
    end)
  end

  defp index_type_rows(index, rows) do
    Enum.reduce(rows, index, fn %{s: term, class: class}, acc ->
      maybe_mark_ontology_term(acc, term, class)
    end)
  end

  defp index_edge_rows(index, edge_field, term_field, rows) do
    Enum.reduce(rows, index, fn %{child: child, parent: parent}, acc ->
      acc
      |> update_set(edge_field, {child, parent})
      |> update_set(term_field, child)
      |> update_set(term_field, parent)
    end)
  end

  defp index_map_set_rows(index, map_field, subject_field, object_field, rows) do
    Enum.reduce(rows, index, fn %{s: subject, o: object}, acc ->
      acc
      |> update_set(map_field, subject, object)
      |> update_set(subject_field, subject)
      |> update_set(object_field, object)
    end)
  end

  defp mark_counted_classes(index) do
    index.class_counts
    |> Map.keys()
    |> Enum.reduce(index, &update_set(&2, :class_terms, &1))
  end

  defp class_node(index, class, children_by_parent, path) do
    row = class_row(index, class)

    children =
      if MapSet.member?(path, class) do
        []
      else
        children_by_parent
        |> Map.get(class, MapSet.new())
        |> sort_terms(index)
        |> Enum.map(&class_node(index, &1, children_by_parent, MapSet.put(path, class)))
      end

    Map.put(row, :children, children)
  end

  defp class_row(index, class) do
    display = display_term(index, class)

    %{
      id: class,
      label: display.label,
      name: display.name,
      prefix: display.prefix,
      namespace: display.namespace,
      labeled?: display.labeled?,
      compact: compact(class),
      count: Map.get(index.class_counts, class, 0),
      comment: Map.get(index.comments, class),
      parents: visible_parents(index.subclass_edges, class)
    }
  end

  defp property_row(index, property, count) do
    display = display_term(index, property)

    %{
      id: property,
      label: display.label,
      name: display.name,
      prefix: display.prefix,
      namespace: display.namespace,
      labeled?: display.labeled?,
      compact: compact(property),
      count: count,
      comment: Map.get(index.comments, property),
      domains: Map.get(index.domains, property, MapSet.new()) |> Enum.map(&label(index, &1)),
      ranges: Map.get(index.ranges, property, MapSet.new()) |> Enum.map(&label(index, &1)),
      parents: parents(index.subproperty_edges, property)
    }
  end

  defp sort_terms(terms, index) do
    terms
    |> Enum.sort_by(fn term ->
      {String.downcase(label(index, term)), term}
    end)
  end

  defp property_namespace_label_sort_key(property) do
    namespace = property.prefix || property.namespace || ""
    label = Map.get(property, :name) || property.label || property.id

    {String.downcase(namespace), String.downcase(label), -property.count, property.id}
  end

  defp prioritize_bfo_entity(terms) do
    case Enum.split_with(terms, &(&1 == @bfo_entity)) do
      {[], terms} -> terms
      {entities, rest} -> entities ++ rest
    end
  end

  defp instance_relevant_classes(index) do
    parent_map =
      index.subclass_edges
      |> Enum.reduce(%{}, fn {child, parent}, acc ->
        Map.update(acc, child, MapSet.new([parent]), &MapSet.put(&1, parent))
      end)

    index.class_counts
    |> Enum.filter(fn {_class, count} -> count > 0 end)
    |> Enum.map(fn {class, _count} -> class end)
    |> Enum.reduce(MapSet.new(), fn class, relevant ->
      add_with_ancestors(class, parent_map, relevant, MapSet.new())
    end)
  end

  defp add_with_ancestors(class, parent_map, relevant, seen) do
    if MapSet.member?(seen, class) do
      relevant
    else
      seen = MapSet.put(seen, class)
      relevant = MapSet.put(relevant, class)

      parent_map
      |> Map.get(class, MapSet.new())
      |> Enum.reduce(relevant, fn parent, acc ->
        add_with_ancestors(parent, parent_map, acc, seen)
      end)
    end
  end

  defp index_by_predicate(index, s, @rdf_type, _o, class, _graph) do
    index
    |> update_in([Access.key!(:class_counts), class], &((&1 || 0) + 1))
    |> update_set(:class_members, class, s)
    |> update_set(:class_terms, class)
    |> maybe_mark_ontology_term(s, class)
  end

  defp index_by_predicate(index, s, p, o, _o_id, graph)
       when p in [@skos_pref_label, @rdfs_label, @dcterms_title] do
    put_ranked_literal(index, :labels, s, p, o, graph, @label_priority)
  end

  defp index_by_predicate(index, s, p, o, _o_id, graph)
       when p in [@skos_definition, @rdfs_comment, @dcterms_description] do
    put_ranked_literal(index, :comments, s, p, o, graph, @comment_priority)
  end

  defp index_by_predicate(index, child, @rdfs_subclass, _o, parent, _graph) do
    index
    |> update_set(:subclass_edges, {child, parent})
    |> update_set(:class_terms, child)
    |> update_set(:class_terms, parent)
  end

  defp index_by_predicate(index, child, @rdfs_subproperty, _o, parent, _graph) do
    index
    |> update_set(:subproperty_edges, {child, parent})
    |> update_set(:property_terms, child)
    |> update_set(:property_terms, parent)
  end

  defp index_by_predicate(index, property, @rdfs_domain, _o, domain, _graph) do
    index
    |> update_set(:domains, property, domain)
    |> update_set(:property_terms, property)
    |> update_set(:class_terms, domain)
  end

  defp index_by_predicate(index, property, @rdfs_range, _o, range, _graph) do
    index
    |> update_set(:ranges, property, range)
    |> update_set(:property_terms, property)
    |> update_set(:class_terms, range)
  end

  defp index_by_predicate(index, _s, p, _o, _o_id, _graph) do
    update_set(index, :property_terms, p)
  end

  defp maybe_mark_ontology_term(index, term, class)
       when class in [
              @owl_class,
              @rdfs_class
            ] do
    update_set(index, :class_terms, term)
  end

  defp maybe_mark_ontology_term(index, term, class)
       when class in [
              @owl_object_property,
              @owl_datatype_property,
              @owl_annotation_property,
              @rdf_property
            ] do
    update_set(index, :property_terms, term)
  end

  defp maybe_mark_ontology_term(index, _term, _class), do: index

  defp put_ranked_literal(index, field, subject, predicate, object, graph, priorities) do
    value = literal_text(object)
    priority = {Map.fetch!(priorities, predicate), graph_label_priority(subject, graph)}
    existing = index |> Map.fetch!(field) |> Map.get(subject)

    if value && better_literal?(priority, value, existing) do
      put_in(index, [Access.key!(field), subject], {priority, value})
    else
      index
    end
  end

  defp better_literal?(_priority, _value, nil), do: true
  defp better_literal?(priority, _value, {existing_priority, _}), do: priority < existing_priority

  defp graph_label_priority(subject, graph) when is_binary(subject) and is_binary(graph) do
    if String.starts_with?(subject, graph), do: 0, else: 1
  end

  defp graph_label_priority(_subject, _graph), do: 1

  defp finalize_sets(index) do
    %{
      index
      | labels: unwrap_ranked(index.labels),
        comments: unwrap_ranked(index.comments)
    }
  end

  defp unwrap_ranked(values) do
    Map.new(values, fn {key, {_priority, value}} -> {key, value} end)
  end

  defp update_set(index, field, value) do
    update_in(index, [Access.key!(field)], &MapSet.put(&1, value))
  end

  defp update_set(index, field, key, value) do
    update_in(index, [Access.key!(field), key], fn
      nil -> MapSet.new([value])
      set -> MapSet.put(set, value)
    end)
  end

  defp parents(edges, term) do
    edges
    |> Enum.flat_map(fn
      {^term, parent} -> [parent]
      _ -> []
    end)
    |> Enum.sort()
  end

  defp visible_parents(edges, term) do
    edges
    |> parents(term)
    |> Enum.reject(&blank_node?/1)
  end

  defp term_id(%Literal{} = literal), do: literal_text(literal)
  defp term_id(nil), do: nil
  defp term_id(term), do: to_string(term)

  defp literal_text(%Literal{} = literal), do: to_string(Literal.lexical(literal))
  defp literal_text(value) when is_binary(value), do: value
  defp literal_text(_), do: nil

  defp blank_node?(term) when is_binary(term), do: String.starts_with?(term, "_:")
  defp blank_node?(_term), do: false

  defp hidden_overview_term?(term) when is_binary(term) do
    Enum.any?(@hidden_overview_namespaces, &String.starts_with?(term, &1))
  end

  defp hidden_overview_term?(_term), do: false

  defp split_compact(term) do
    prefixes()
    |> Enum.find_value(fn {prefix, iri} ->
      if String.starts_with?(term, iri), do: {prefix, String.replace_prefix(term, iri, "")}
    end)
  end

  defp term_prefix(term) do
    case split_compact(term) do
      {prefix, _name} -> prefix
      nil -> nil
    end
  end

  defp term_namespace(term) do
    if term_prefix(term) do
      nil
    else
      case split_namespace(term) do
        {namespace, _name} -> namespace
        nil -> nil
      end
    end
  end

  defp split_term(term) do
    case split_compact(term) do
      {prefix, name} ->
        {prefix, name}

      nil ->
        case split_namespace(term) do
          {namespace, name} -> {nil, namespace, name}
          nil -> nil
        end
    end
  end

  defp split_namespace(term) when is_binary(term) do
    term
    |> namespace_separator_index()
    |> case do
      nil ->
        nil

      index ->
        {String.slice(term, 0..index), String.slice(term, (index + 1)..-1//1)}
    end
  end

  defp namespace_separator_index(term) do
    term
    |> :binary.matches(["#", "/"])
    |> Enum.map(fn {index, 1} -> index end)
    |> Enum.max(fn -> nil end)
  end

  defp short_iri(term) do
    term
    |> String.trim_leading("_:")
    |> String.split(["#", "/"], trim: true)
    |> List.last()
    |> case do
      nil -> term
      "" -> term
      value -> value
    end
  end

  defp prefixes do
    [
      {"rdf", "http://www.w3.org/1999/02/22-rdf-syntax-ns#"},
      {"rdfs", "http://www.w3.org/2000/01/rdf-schema#"},
      {"owl", "http://www.w3.org/2002/07/owl#"},
      {"xsd", "http://www.w3.org/2001/XMLSchema#"},
      {"skos", "http://www.w3.org/2004/02/skos/core#"},
      {"dc", "http://purl.org/dc/elements/1.1/"},
      {"dcterms", "http://purl.org/dc/terms/"},
      {"geo", "http://www.w3.org/2003/01/geo/wgs84_pos#"},
      {"bfo", "https://node.town/bfo#"},
      {"prov", "http://www.w3.org/ns/prov#"},
      {"foaf", "http://xmlns.com/foaf/0.1/"},
      {"bibo", "http://purl.org/ontology/bibo/"},
      {"biro", "http://purl.org/spar/biro/"},
      {"c4o", "http://purl.org/spar/c4o/"},
      {"cito", "http://purl.org/spar/cito/"},
      {"deo", "http://purl.org/spar/deo/"},
      {"doco", "http://purl.org/spar/doco/"},
      {"fabio", "http://purl.org/spar/fabio/"},
      {"frbr", "http://purl.org/vocab/frbr/core#"},
      {"prism", "http://prismstandard.org/namespaces/basic/2.0/"},
      {"prism", "http://prismstandard.org/namespaces/basic/2.1/"},
      {"pro", "http://purl.org/spar/pro/"},
      {"pso", "http://purl.org/spar/pso/"},
      {"pwo", "http://purl.org/spar/pwo/"},
      {"vann", "http://purl.org/vocab/vann/"},
      {"sheaf", "https://less.rest/sheaf/"}
    ]
  end
end
