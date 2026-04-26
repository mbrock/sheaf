defmodule SheafRDFBrowser.Index do
  @moduledoc """
  Generic ontology/index view derived from a snapshot `RDF.Dataset`.
  """

  alias RDF.{Dataset, Literal}
  alias RDF.NS.{OWL, RDFS, SKOS}

  @rdf_type RDF.type() |> to_string()
  @rdfs_label RDFS.label() |> to_string()
  @skos_pref_label SKOS.prefLabel() |> to_string()
  @dc_title "http://purl.org/dc/elements/1.1/title"
  @dcterms_title "http://purl.org/dc/terms/title"
  @rdfs_comment RDFS.comment() |> to_string()
  @skos_definition SKOS.definition() |> to_string()
  @skos_scope_note "http://www.w3.org/2004/02/skos/core#scopeNote"
  @skos_editorial_note "http://www.w3.org/2004/02/skos/core#editorialNote"
  @dc_description "http://purl.org/dc/elements/1.1/description"
  @dcterms_description "http://purl.org/dc/terms/description"
  @prov_definition "http://www.w3.org/ns/prov#definition"
  @prov_editors_definition "http://www.w3.org/ns/prov#editorsDefinition"
  @rdfs_subclass RDFS.subClassOf() |> to_string()
  @rdfs_subproperty RDFS.subPropertyOf() |> to_string()
  @rdfs_domain RDFS.domain() |> to_string()
  @rdfs_range RDFS.range() |> to_string()
  @owl_ontology "http://www.w3.org/2002/07/owl#Ontology"
  @owl_imports "http://www.w3.org/2002/07/owl#imports"
  @owl_thing "http://www.w3.org/2002/07/owl#Thing"
  @owl_class OWL.Class |> to_string()
  @rdfs_class RDFS.Class |> to_string()
  @bfo_entity "https://node.town/bfo#Entity"
  @owl_object_property OWL.ObjectProperty |> to_string()
  @owl_datatype_property OWL.DatatypeProperty |> to_string()
  @owl_annotation_property OWL.AnnotationProperty |> to_string()
  @rdf_property "http://www.w3.org/1999/02/22-rdf-syntax-ns#Property"
  @vann_preferred_namespace_prefix "http://purl.org/vocab/vann/preferredNamespacePrefix"
  @vann_preferred_namespace_uri "http://purl.org/vocab/vann/preferredNamespaceUri"
  @hidden_overview_namespaces [
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
    "http://www.w3.org/2000/01/rdf-schema#",
    "http://www.w3.org/2002/07/owl#",
    "http://www.w3.org/2003/11/swrl#"
  ]

  @label_priority %{
    @skos_pref_label => 0,
    @rdfs_label => 1,
    @dc_title => 2,
    @dcterms_title => 3
  }

  @comment_priority %{
    @skos_definition => 0,
    @prov_definition => 1,
    @rdfs_comment => 2,
    @dc_description => 3,
    @dcterms_description => 4,
    @skos_scope_note => 5,
    @skos_editorial_note => 6,
    @prov_editors_definition => 7
  }

  defstruct labels: %{},
            comments: %{},
            notes: %{},
            ontologies: %{},
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
    |> index_ontology_rows(Map.get(rows, :ontologies, []))
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

  def class_schema_property_rows(%__MODULE__{} = index, class) when is_binary(class) do
    %{
      domain: schema_property_rows(index, index.domains, class),
      range: schema_property_rows(index, index.ranges, class)
    }
  end

  def ontology_rows(%__MODULE__{} = index) do
    index.ontologies
    |> Map.values()
    |> Enum.map(&ontology_row(index, &1))
    |> Enum.reject(&(Enum.empty?(&1.class_tree) and Enum.empty?(&1.property_tree)))
    |> Enum.sort_by(fn ontology ->
      {String.downcase(ontology.prefix || ""), String.downcase(ontology.label), ontology.id}
    end)
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
      acc
      |> put_ranked_literal(:comments, row.s, row.p, row.o, row.g, @comment_priority)
      |> put_note(row.s, row.p, row.o, row.g)
    end)
  end

  defp index_ontology_rows(index, rows) do
    Enum.reduce(rows, index, fn %{ontology: ontology, p: predicate, o: object}, acc ->
      acc
      |> ensure_ontology(ontology)
      |> update_ontology_metadata(ontology, predicate, object)
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
      notes: Map.get(index.notes, class, %{}) |> note_rows(index),
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
      notes: Map.get(index.notes, property, %{}) |> note_rows(index),
      domains: Map.get(index.domains, property, MapSet.new()) |> Enum.map(&label(index, &1)),
      ranges: Map.get(index.ranges, property, MapSet.new()) |> Enum.map(&label(index, &1)),
      parents: parents(index.subproperty_edges, property)
    }
  end

  defp ontology_row(index, ontology) do
    display = display_term(index, ontology.id)
    namespaces = ontology_namespaces(ontology)
    class_terms = terms_in_namespaces(index.class_terms, namespaces)
    property_terms = terms_in_namespaces(index.property_terms, namespaces)

    %{
      id: ontology.id,
      label: display.label,
      name: display.name,
      prefix: ontology.preferred_namespace_prefix || display.prefix,
      namespace: ontology.preferred_namespace_uri || display.namespace,
      namespaces: namespaces,
      labeled?: display.labeled?,
      compact: compact(ontology.id),
      comment: Map.get(index.comments, ontology.id),
      notes: Map.get(index.notes, ontology.id, %{}) |> note_rows(index),
      imports: ontology.imports |> Enum.sort() |> Enum.map(&display_import(index, &1)),
      class_tree: class_tree_with_external_ancestors(index, class_terms),
      property_tree:
        term_tree(index, property_terms, index.subproperty_edges, fn index, property ->
          property_row(index, property, Map.get(index.predicate_counts, property, 0))
        end)
    }
  end

  defp display_import(index, iri) do
    index
    |> display_term(iri)
    |> Map.put(:id, iri)
  end

  defp class_tree_with_external_ancestors(index, class_terms) do
    terms =
      class_terms
      |> Enum.reduce(class_terms, fn class, acc ->
        add_class_ancestors(index, class, acc, MapSet.new())
      end)

    term_tree(index, terms, index.subclass_edges, fn index, class ->
      index
      |> class_row(class)
      |> Map.put(:external_ancestor?, not MapSet.member?(class_terms, class))
    end)
  end

  defp add_class_ancestors(index, class, terms, seen) do
    if MapSet.member?(seen, class) do
      terms
    else
      seen = MapSet.put(seen, class)

      index.subclass_edges
      |> parents(class)
      |> Enum.reject(&excluded_external_parent?/1)
      |> Enum.reduce(terms, fn parent, acc ->
        index
        |> add_class_ancestors(parent, MapSet.put(acc, parent), seen)
      end)
    end
  end

  defp term_tree(index, terms, edges, row_fun) do
    visible_terms =
      terms
      |> Enum.reject(&blank_node?/1)
      |> MapSet.new()

    children_by_parent =
      edges
      |> Enum.filter(fn {child, parent} ->
        MapSet.member?(visible_terms, child) and MapSet.member?(visible_terms, parent)
      end)
      |> Enum.reduce(%{}, fn {child, parent}, acc ->
        Map.update(acc, parent, MapSet.new([child]), &MapSet.put(&1, child))
      end)

    visible_terms
    |> Enum.reject(fn term ->
      parents(edges, term)
      |> Enum.any?(&MapSet.member?(visible_terms, &1))
    end)
    |> sort_terms(index)
    |> Enum.map(&term_node(index, &1, children_by_parent, MapSet.new(), row_fun))
  end

  defp term_node(index, term, children_by_parent, path, row_fun) do
    row = row_fun.(index, term)

    children =
      if MapSet.member?(path, term) do
        []
      else
        children_by_parent
        |> Map.get(term, MapSet.new())
        |> sort_terms(index)
        |> Enum.map(&term_node(index, &1, children_by_parent, MapSet.put(path, term), row_fun))
      end

    Map.put(row, :children, children)
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

  defp schema_property_rows(index, property_class_map, class) do
    property_class_map
    |> Enum.filter(fn {_property, classes} -> MapSet.member?(classes, class) end)
    |> Enum.map(fn {property, _classes} ->
      property_row(index, property, Map.get(index.predicate_counts, property, 0))
    end)
    |> Enum.sort_by(&property_namespace_label_sort_key/1)
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
       when p in [@skos_pref_label, @rdfs_label, @dc_title, @dcterms_title] do
    put_ranked_literal(index, :labels, s, p, o, graph, @label_priority)
  end

  defp index_by_predicate(index, s, p, o, _o_id, graph)
       when p in [
              @skos_definition,
              @prov_definition,
              @rdfs_comment,
              @dc_description,
              @dcterms_description,
              @skos_scope_note,
              @skos_editorial_note,
              @prov_editors_definition
            ] do
    index
    |> put_ranked_literal(:comments, s, p, o, graph, @comment_priority)
    |> put_note(s, p, o, graph)
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

  defp index_by_predicate(index, ontology, predicate, _o, object, _graph)
       when predicate in [
              @vann_preferred_namespace_prefix,
              @vann_preferred_namespace_uri,
              @owl_imports
            ] do
    index
    |> ensure_ontology(ontology)
    |> update_ontology_metadata(ontology, predicate, object)
  end

  defp index_by_predicate(index, _s, p, _o, _o_id, _graph) do
    update_set(index, :property_terms, p)
  end

  defp maybe_mark_ontology_term(index, term, @owl_ontology) do
    ensure_ontology(index, term)
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

  defp ensure_ontology(index, ontology) when is_binary(ontology) do
    update_in(index, [Access.key!(:ontologies), ontology], fn
      nil ->
        %{
          id: ontology,
          preferred_namespace_prefix: nil,
          preferred_namespace_uri: nil,
          imports: MapSet.new()
        }

      existing ->
        existing
    end)
  end

  defp ensure_ontology(index, _ontology), do: index

  defp update_ontology_metadata(index, ontology, @vann_preferred_namespace_prefix, prefix) do
    put_in(index, [Access.key!(:ontologies), ontology, :preferred_namespace_prefix], prefix)
  end

  defp update_ontology_metadata(index, ontology, @vann_preferred_namespace_uri, namespace) do
    put_in(index, [Access.key!(:ontologies), ontology, :preferred_namespace_uri], namespace)
  end

  defp update_ontology_metadata(index, ontology, @owl_imports, imported) do
    update_in(index, [Access.key!(:ontologies), ontology, :imports], &MapSet.put(&1, imported))
  end

  defp update_ontology_metadata(index, _ontology, _predicate, _object), do: index

  defp ontology_namespaces(ontology) do
    ontology.preferred_namespace_uri
    |> namespace_candidates(ontology.id)
    |> Enum.uniq()
  end

  defp namespace_candidates(nil, ontology_id), do: fallback_namespace_candidates(ontology_id)
  defp namespace_candidates("", ontology_id), do: fallback_namespace_candidates(ontology_id)

  defp namespace_candidates(namespace, ontology_id) do
    ([namespace] ++ fallback_namespace_candidates(ontology_id))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp fallback_namespace_candidates(ontology_id) when is_binary(ontology_id) do
    cond do
      String.ends_with?(ontology_id, ["/", "#"]) ->
        [ontology_id]

      true ->
        [ontology_id <> "/", ontology_id <> "#"]
    end
  end

  defp fallback_namespace_candidates(_ontology_id), do: []

  defp terms_in_namespaces(terms, namespaces) do
    terms
    |> Enum.filter(fn term ->
      is_binary(term) and Enum.any?(namespaces, &String.starts_with?(term, &1))
    end)
    |> MapSet.new()
  end

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
        comments: unwrap_ranked(index.comments),
        notes: unwrap_notes(index.notes)
    }
  end

  defp unwrap_ranked(values) do
    Map.new(values, fn {key, {_priority, value}} -> {key, value} end)
  end

  defp put_note(index, subject, predicate, object, graph) do
    value = literal_text(object)

    if value do
      priority = graph_label_priority(subject, graph)

      update_in(index, [Access.key!(:notes), subject], fn by_predicate ->
        by_predicate = by_predicate || %{}
        values = Map.get(by_predicate, predicate, %{})
        Map.put(by_predicate, predicate, Map.put(values, {priority, value}, value))
      end)
    else
      index
    end
  end

  defp unwrap_notes(notes) do
    Map.new(notes, fn {subject, by_predicate} ->
      {
        subject,
        Map.new(by_predicate, fn {predicate, values} ->
          values =
            values
            |> Map.keys()
            |> Enum.sort()
            |> Enum.map(fn {_priority, value} -> normalize_note_value(value) end)
            |> Enum.uniq()

          {predicate, values}
        end)
      }
    end)
  end

  defp note_rows(notes, index) do
    notes
    |> Enum.map(fn {predicate, values} ->
      %{
        id: predicate,
        label: note_label(index, predicate),
        values: values
      }
    end)
    |> Enum.sort_by(fn note ->
      {Map.get(@comment_priority, note.id, 99), String.downcase(note.label), note.id}
    end)
  end

  defp note_label(_index, @skos_definition), do: "definition"
  defp note_label(_index, @prov_definition), do: "PROV definition"
  defp note_label(_index, @rdfs_comment), do: "comment"
  defp note_label(_index, @dc_description), do: "description"
  defp note_label(_index, @dcterms_description), do: "description"
  defp note_label(_index, @skos_scope_note), do: "scope note"
  defp note_label(_index, @skos_editorial_note), do: "editorial note"
  defp note_label(_index, @prov_editors_definition), do: "editors' definition"
  defp note_label(index, predicate), do: label(index, predicate)

  defp normalize_note_value(value) do
    String.trim(value)
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

  defp excluded_external_parent?(term), do: blank_node?(term) or term == @owl_thing

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
      {"co", "http://purl.org/co/"},
      {"deo", "http://purl.org/spar/deo/"},
      {"doco", "http://purl.org/spar/doco/"},
      {"event", "http://purl.org/NET/c4dm/event.owl#"},
      {"fabio", "http://purl.org/spar/fabio/"},
      {"frbr", "http://purl.org/vocab/frbr/core#"},
      {"orb", "http://purl.org/orb/1.0/"},
      {"po", "http://www.essepuntato.it/2008/12/pattern#"},
      {"prism", "http://prismstandard.org/namespaces/basic/2.0/"},
      {"prism", "http://prismstandard.org/namespaces/basic/2.1/"},
      {"pro", "http://purl.org/spar/pro/"},
      {"pso", "http://purl.org/spar/pso/"},
      {"pwo", "http://purl.org/spar/pwo/"},
      {"tvc", "http://www.essepuntato.it/2012/04/tvc/"},
      {"agentrole", "http://www.ontologydesignpatterns.org/cp/owl/agentrole.owl#"},
      {"basicplan", "http://www.ontologydesignpatterns.org/cp/owl/basicplan.owl#"},
      {"bpd", "http://www.ontologydesignpatterns.org/cp/owl/basicplandescription.owl#"},
      {"bpe", "http://www.ontologydesignpatterns.org/cp/owl/basicplanexecution.owl#"},
      {"cpann", "http://www.ontologydesignpatterns.org/schemas/cpannotationschema.owl#"},
      {"discourse", "http://purl.org/swan/2.0/discourse-relationships/"},
      {"description", "http://www.ontologydesignpatterns.org/cp/owl/description.owl#"},
      {"objectrole", "http://www.ontologydesignpatterns.org/cp/owl/objectrole.owl#"},
      {"parameter", "http://www.ontologydesignpatterns.org/cp/owl/parameter.owl#"},
      {"participation", "http://www.ontologydesignpatterns.org/cp/owl/participation.owl#"},
      {"region", "http://www.ontologydesignpatterns.org/cp/owl/region.owl#"},
      {"sequence", "http://www.ontologydesignpatterns.org/cp/owl/sequence.owl#"},
      {"situation", "http://www.ontologydesignpatterns.org/cp/owl/situation.owl#"},
      {"taskrole", "http://www.ontologydesignpatterns.org/cp/owl/taskrole.owl#"},
      {"timeinterval", "http://www.ontologydesignpatterns.org/cp/owl/timeinterval.owl#"},
      {"tis", "http://www.ontologydesignpatterns.org/cp/owl/timeindexedsituation.owl#"},
      {"vann", "http://purl.org/vocab/vann/"},
      {"sheaf", "https://less.rest/sheaf/"}
    ]
  end
end
