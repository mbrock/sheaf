# RDF.ex Cheat Sheet

Concise, code-first notes distilled from `docs/rdf-elixir/content/rdf-ex/*.md`.

## Start Here

```elixir
use RDF
alias RDF.NS.{RDFS}
alias MyApp.NS.EX
```

`use RDF` is the happy path: it brings in the useful sigils, top-level constructors, and common aliases.

## Terms

```elixir
# IRIs
RDF.iri("http://example.com/foo")
~I<http://example.com/foo>
~i<http://example.com/#{slug}>

# Blank nodes
RDF.bnode()
RDF.bnode(:temp)
~B<temp>

# Literals
RDF.literal("plain string")
~L"plain string"

RDF.literal("hello", language: "en")
~L"hello"en

RDF.literal(42)
XSD.integer(42)
RDF.literal("0042", datatype: XSD.byte)

RDF.json(%{foo: 42})
```

```elixir
# Back to Elixir values
RDF.Term.value(~I<http://example.com/foo>)   #=> "http://example.com/foo"
RDF.Term.value(~L"hello")                    #=> "hello"
RDF.Term.value(XSD.integer(42))              #=> 42
```

## Namespaces

Use vocabulary modules instead of raw strings when you can. You get shorter code and compile-time checks.

```elixir
alias RDF.NS.RDFS
alias MyApp.NS.EX

EX.Person      # resource term
EX.name()      # property term
RDF.type       # rdf:type is available directly on RDF
RDFS.label     # built-in vocabularies live under RDF.NS
```

```elixir
# Namespace terms work anywhere an IRI is expected
RDF.iri(EX.Person)
RDF.iri(EX.name())

# Property functions double as description builders
EX.Person |> EX.name("Alice")
```

```elixir
# Pattern matching with namespace terms
use RDF

case term do
  term_to_iri(EX.Person) -> :person
  term_to_iri(RDFS.Class) -> :class
end
```

## Statements

```elixir
RDF.triple(EX.S, EX.p, 1)
RDF.quad(EX.S, EX.p, 1, EX.Graph)
RDF.quad(EX.S, EX.p, 1, nil) # nil = default graph
```

`RDF.triple/3` and `RDF.quad/4` coerce inputs into proper RDF terms and reject invalid predicates.

## Description DSL

This is the nicest way to build triples about one subject.

```elixir
EX.Foo
|> RDF.type(EX.Bar)
|> EX.label("Foo")
|> EX.count(42)
|> EX.tag(["one", "two"])
```

That returns an `RDF.Description`.

## Core Data Structures

```elixir
desc =
  RDF.description(EX.Foo, init: {EX.label, "Foo"})

graph =
  RDF.graph(init: {EX.Foo, EX.label, "Foo"})

dataset =
  RDF.dataset(init: {EX.Foo, EX.label, "Foo", EX.Graph})
```

Useful input forms:

```elixir
RDF.graph([
  {EX.S, EX.p, EX.O},
  {EX.S, EX.tag, ["one", "two"]},
  %{EX.Other => %{name: "Alice"}}
], context: %{name: EX.name})
```

## Add, Put, Update, Delete

```elixir
graph =
  graph
  |> RDF.Graph.add({EX.S, EX.p2, EX.O2})
  |> RDF.Graph.put(%{EX.S => %{name: "New"}}, context: %{name: EX.name})
```

`add` merges statements.

`put` overwrites more aggressively:

- `RDF.Description.put/3` overwrites matching subject + predicate.
- `RDF.Graph.put/3` and `RDF.Dataset.put/3` overwrite by subject.

If you only want predicate-level overwrite on a graph or dataset, use `put_properties`.

```elixir
RDF.Graph.put_properties(graph, %{EX.S => %{name: "New"}}, context: %{name: EX.name})
```

```elixir
RDF.Description.update(desc, EX.count, fn [n] -> XSD.Integer.value(n) + 1 end)
RDF.Graph.delete(graph, {EX.S, EX.p, EX.O})
```

## Accessing Data

```elixir
RDF.Description.get(desc, EX.label)
RDF.Description.first(desc, EX.label)

RDF.Graph.get(graph, EX.S)
RDF.Dataset.graph(dataset, EX.Graph)
RDF.Dataset.default_graph(dataset)
```

All three structures implement `Access`, so this also works:

```elixir
desc[EX.label]
graph[EX.S]
dataset[EX.Graph]
```

## The `RDF.Data` API

Reach for `RDF.Data` when you want code that works on descriptions, graphs, or datasets without caring which one you have.

```elixir
RDF.Data.subjects(graph)
RDF.Data.predicates(graph)
RDF.Data.objects(graph)
RDF.Data.resources(graph, predicates: true)

RDF.Data.include?(graph, {EX.S, EX.p, EX.O})
RDF.Data.describes?(graph, EX.S)

RDF.Data.merge(desc1, desc2)
RDF.Data.delete(graph, other_graph)

RDF.Data.to_graph(dataset)
RDF.Data.to_dataset(graph)
RDF.Data.equal?(desc, graph)
```

## Mapping RDF Back To Elixir

```elixir
RDF.Description.values(desc, context: [label: EX.label])
RDF.Graph.values(graph)
RDF.Dataset.values(dataset)
```

```elixir
RDF.Graph.map(graph, fn
  {:predicate, predicate} ->
    predicate
    |> to_string()
    |> String.split("/")
    |> List.last()
    |> String.to_atom()

  {_, term} ->
    RDF.Term.value(term)
end)
```

## Property Maps And `context:`

This is one of the best ergonomics features in the library.

```elixir
context = RDF.property_map(name: EX.name, tag: EX.tag)

RDF.Description.add(desc, [name: "Alice", tag: ["one", "two"]], context: context)
RDF.Graph.add(graph, %{EX.S => %{name: "Alice"}}, context: context)
```

## Graph Builder DSL

Use this when the RDF is mostly static or declarative.

```elixir
use RDF

RDF.Graph.build do
  @base EX
  @prefix ex: EX
  @prefix RDFS

  ~I<#alice>
  |> a(EX.Person)
  |> EX.name("Alice")
  |> RDFS.label("Alice")
end
```

Inside `RDF.Graph.build`:

- `a(...)` is shorthand for `rdf:type`
- `@prefix` defines aliases and graph prefixes
- `@base` sets the base IRI
- arbitrary Elixir expressions are allowed as long as they return RDF data
- `nil` and `:ok` results are ignored, which makes conditionals convenient

## Querying Graphs

Basic graph pattern queries are built in.

```elixir
RDF.Graph.query!(graph, [
  {:s?, RDFS.label, "Alice"},
  {:s?, :p?, :o?}
])
```

Variables are atoms ending in `?`. Blank-node-like atoms such as `:_tmp` act like anonymous variables.

```elixir
path = RDF.Query.path([EX.Alice, EX.knows, RDFS.label, :name?])
RDF.Graph.query!(graph, path)
```

## Lists

```elixir
list = RDF.list(["foo", EX.Bar, ~B<tmp>, [1, 2, 3]])
RDF.List.values(list)
```

`RDF.list/1` builds RDF collections and handles nested lists too.

## Serializations

```elixir
{:ok, graph} = RDF.read_file("/tmp/data.ttl")
ttl = RDF.write_string!(graph, format: :turtle)

RDF.write_file!(graph, "/tmp/data.nt.gz")
RDF.read_file!("/tmp/data.jsonld")
```

Useful facts:

- format can be inferred from file extension
- gzip is supported
- built-in formats include N-Triples, N-Quads, Turtle, and TriG
- JSON-LD and RDF/XML need extra deps

Prefixes and base IRIs live on graphs:

```elixir
graph
|> RDF.Graph.add_prefixes(ex: EX)
|> RDF.Graph.set_base_iri(EX)
```

## RDF-star

Quoted triples are just triples used as subjects or objects of other triples.

```elixir
quoted = {EX.Employee38, EX.jobTitle(), "Assistant Designer"}

RDF.triple({quoted, EX.accordingTo(), EX.Employee22})
```

Annotations are the common case:

```elixir
graph =
  RDF.graph()
  |> RDF.Graph.add_annotations(
    {EX.S, EX.p, EX.O},
    %{EX.source() => EX.Doc}
  )
```

```elixir
RDF.Graph.annotations(graph)
RDF.Graph.without_annotations(graph)
```

## Equality, Isomorphism, And Test-Friendly Checks

```elixir
RDF.Graph.equal?(graph1, graph2)   # graph-aware equality
RDF.Data.equal?(desc, graph)       # cross-structure equality
RDF.Graph.isomorphic?(g1, g2)      # ignore blank-node IDs
RDF.Graph.canonical_hash(graph)
```

If your tests compare graphs with blank nodes, prefer isomorphism:

```elixir
assert_rdf_isomorphic actual_graph, expected_graph
```

## Less-Obvious Good Stuff

```elixir
# Resource identifiers with configurable generators
RDF.Resource.Generator.generate(generator: RDF.BlankNode)

RDF.Resource.Generator.generate(
  [generator: RDF.IRI.UUID.Generator, prefix: "https://example.com/"],
  "alice"
)
```

```elixir
# RDF values from graph-ish data
RDF.Graph.values(graph)

# Filter or transform generically
RDF.Data.filter(graph, fn {_, p, _} -> p == EX.keep() end)
RDF.Data.map(graph, fn {s, p, _o} -> {s, p, EX.NewObject} end)
```

## Rules Of Thumb

- Prefer vocab modules and namespace terms over raw IRI strings.
- Use the description DSL for one subject and `RDF.Graph.build` for declarative graph literals.
- Use `RDF.Data.*` when you want generic code across descriptions, graphs, and datasets.
- Use `put_properties` when you want to overwrite one predicate without blowing away the rest of a subject.
- Use `context:` with `RDF.PropertyMap`s to keep inputs short and readable.
- Use `RDF.Term.value/1`, `values/1`, and `map/2` at the edge where RDF becomes normal Elixir data.
- Use `RDF.Graph.isomorphic?/2` or `assert_rdf_isomorphic/2` in tests that involve blank nodes.
- Use `RDF.Graph.add_annotations/3` or `add_annotations:` when you want RDF-star metadata on triples.
