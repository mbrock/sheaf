# RDF Data Working Notes

Wide multi-way joins with `OPTIONAL` branches and embedded subqueries are
exactly the kind of plan that a general-purpose triple store handles poorly
compared with retrieving a bounded graph neighborhood and reading it.

In practice it is often faster to pull a larger but simpler patch of graph and
walk it in Elixir than to ask SPARQL to compute exactly the answer through a
clever narrow query.

Complex SPARQL queries are also usually hard to understand and debug.

We don't need to optimize our system for web scale, but the real dataset even
with a single user has hundreds of thousands of triples across hundreds of
named graphs.

Code quality is more important than performance, but since SPARQL queries so
easily become tediously slow, we should (1) look at the telemetry to see how
our queries perform; and (2) stick to simple access patterns that don't cause
extreme stupidity in Fuseki's query planner.

Domain modules should have code that is mostly meaningful logic about the
domain. If you find yourself writing or working with a domain model that has
pages of code just translating data between different shapes, take this
seriously and flag it to the programmer so you can make decisions about how to
restructure it.

It is often not necessary to invent domain model struct representations that
mirror the graph data. Instead the domain model can use an `RDF.Data` subset
as its representation and provide functions that access it.

There is no particular reason why even Phoenix views can't use such models
in assigns, etc.

A common RDF operation should be boring:

1. Start with one resource, a set of resources, or all resources of a type.
2. Construct a graph containing their direct descriptions.
3. Optionally include direct inbound links to those resources.
4. Optionally include a bounded neighborhood: labels, parents, children,
   source files, agent/session context, work/expression links, or provenance
   activity.
5. Return one of the `RDF.Data` structures (description, graph, or dataset)
   that the caller can use to continue working with the data.

In that pattern, a query does not need to flatten the world into columns. It
retrieves a useful patch of graph, and the rest of the code continues to speak
RDF.

Prefer:

- RDF graphs and descriptions inside domain modules.
- `CONSTRUCT` when the result is knowledge.
- `SELECT` when the result is a search table, aggregate, or intentionally flat
  projection.

Be suspicious of:

- `SELECT` queries that merely rebuild resource descriptions.
- Row grouping code that recreates graph structure by hand.
