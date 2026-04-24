# RDF Data Working Notes

These notes are not a finished architecture. They are a way to hold onto a
recurring feeling in the codebase: when a module needs a large bespoke SPARQL
string, a pile of variable bindings, and then a second pile of code to turn rows
back into Elixir maps, something may have gone slightly off course.

The discomfort is not only about laziness in the simple sense. It is the stronger
kind of laziness where even already-written code can look too effortful to keep.
If a thing feels like too much machinery, it is worth asking whether the system
is making us restate facts that RDF already knows how to carry.

## The Shape We Want

Sheaf wants a fairly uniform data world. Most things should be resources:
documents, files, sections, paragraphs, assistant notes, research sessions,
agents, activities, works, expressions, PDF conversions, uploads, and derived
metadata. They can have RDF descriptions, links to other resources, containment
relations, provenance, labels, timestamps, and typed roles.

That uniformity matters for the application, but it matters even more for
agents. An agent can work well when it can inspect a resource, follow links,
name exact blocks, create new linked notes, and later recover what happened. The
block model already shows how powerful this is: durable, specific references are
not just citations. They are new facts in the graph.

The ideal is that a lot of code can ask: "What resources am I looking at, and
what descriptions do I need around them?" rather than: "What bespoke result row
shape should this module invent?"

## A Preferred Query Pattern

A common RDF operation should be boring:

1. Start with one resource, a set of resources, or all resources of a type.
2. Construct a graph containing their direct descriptions.
3. Optionally include direct inbound links to those resources.
4. Optionally include a bounded neighborhood: labels, parents, children, source
   files, agent/session context, work/expression links, or provenance activity.
5. Return an RDF graph, then let the caller use `RDF.Data.description/2`,
   `RDF.Data.descriptions/1`, `RDF.Description.first/3`, and
   `RDF.Description.get/3`.

In that pattern, a query does not need to flatten the world into columns. It
retrieves a useful patch of graph, and the rest of the code continues to speak
RDF.

Something like this is the mental model:

```sparql
CONSTRUCT {
  ?resource ?p ?o .
  ?incoming ?incomingP ?resource .
  ?incoming rdfs:label ?incomingLabel .
}
WHERE {
  VALUES ?resource { ... }

  { ?resource ?p ?o }
  UNION
  {
    ?incoming ?incomingP ?resource .
    OPTIONAL { ?incoming rdfs:label ?incomingLabel }
  }
}
```

That exact query is not a universal abstraction. The point is the posture:
retrieve graph neighborhoods when graph neighborhoods are what the program
actually wants.

## When Big SPARQL Is Still Real

Large SPARQL queries are not automatically wrong. Some operations are genuinely
queries in the database sense: full-text-ish search, ranking, filtering,
aggregation, counting pages, discovering candidate resources, or computing a
specific index. `SELECT` rows can be the right result for search hits or compact
API projections.

But those cases should feel named and intentional. The query should be doing
something that RDF graph access does not already give us cheaply. If the query is
mostly spelling out a resource description by hand, then converting those rows
back into something that resembles a description, it is probably paying an
avoidable tax.

## Documents As A Test Case

The document index is a good place to keep asking this question. Today, a list of
documents wants labels, kinds, metadata title, authors, DOI, venue, publisher,
page count, and paths. It is easy to respond by writing a large `SELECT` query
and a row hydrator.

Another way to think about it:

- First discover the document resources.
- Construct their descriptions.
- Pull a bounded metadata neighborhood through representation/work/expression
  links.
- Treat page count as a derived fact if it is important enough to display often,
  instead of recomputing it as a subquery every time.
- Let the UI read descriptions and linked descriptions, only turning into text at
  the rendering edge.

This does not mean every view must become verbose RDF traversal code. It means
the primary domain object can remain the graph. Small view helpers that read
descriptions are different from domain modules that erase RDF semantics and
invent a private map format.

## Provenance And Activity

The provenance angle fits naturally here. Uploading a file, converting a PDF,
extracting metadata, asking an LLM, resolving a DOI, importing Crossref metadata,
and writing an assistant note are all activities. Their results can be linked
with `prov:wasGeneratedBy`, `prov:used`, `prov:wasDerivedFrom`, ActivityStreams
objects, timestamps, agents, and user/session context.

This makes partially completed workflows inspectable. A PDF that is half
ingested should not require a special dashboard to understand. It should be a
resource with neighboring facts: this upload activity produced this file; this
conversion job used it; this extracted JSON was derived from it; this agent
created this note because of this research session.

That is the richer version of "everything is a resource". Not everything is the
same type of thing, but everything can participate in the same graph.

## Boundaries

Elixir maps are not bad. JSON APIs, LiveView assigns, tool responses, and small
display payloads sometimes need plain data. The important distinction is where
the conversion happens and why.

Prefer:

- RDF graphs and descriptions inside domain modules.
- `CONSTRUCT` when the result is knowledge.
- `SELECT` when the result is a search table, aggregate, or intentionally flat
  projection.
- Small RDF-reading helpers near the UI or tool boundary.
- Derived facts in the graph when a computed value becomes part of the durable
  application model.

Be suspicious of:

- `SELECT` queries that merely rebuild resource descriptions.
- Row grouping code that recreates graph structure by hand.
- Private map schemas that are not documented, typed, or clearly an edge
  payload.
- Modules that know many namespaces only to flatten them into string keys.

## Open Questions

Can Sheaf have one or two pleasant graph-neighborhood query helpers without
recreating a vague custom ORM?

Should common index views be backed by stored derived facts, so the display path
is mostly graph reading instead of repeated aggregation?

What is the smallest useful vocabulary for jobs and activities so PDF ingestion,
metadata resolution, Crossref import, and assistant notes all feel like one
workflow rather than separate scripts?

How far can the web UI go by passing `RDF.Graph` and `RDF.Description` values
directly, with maps reserved for API edges?

The attractive possibility is that the code becomes simpler because the data
model is richer, not poorer. We do less translation, keep more semantics alive,
and make the graph itself the thing that both humans and agents can explore.
