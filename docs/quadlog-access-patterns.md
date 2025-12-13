# Quadlog Access Patterns

Quadlog is not a SPARQL server. Treat it as an RDF graph log with indexed quad
patterns and a small in-memory working set.

## Rules

- Use `Sheaf.Repo.match/1` for broad derived indexes. Load the exact predicate
  or graph slices needed, merge those slices, then walk RDF graphs once.
- Use `Sheaf.Repo.load_once/1` for request-time neighborhoods that should stay
  cached for repeated UI reads.
- Avoid `Sheaf.fetch_dataset/0` in request-time code and derived index code
  unless the actual operation is whole-dataset export, backup, or diagnostics.
- Prefer graph-shaped helpers returning `RDF.Graph` or `RDF.Dataset` over
  SPARQL-like row maps. Only project to rows at module boundaries such as SQLite
  sidecar insertion.
- When walking a graph, build a small `{subject, predicate} -> objects` index if
  more than one lookup per subject is needed. Do not call `Graph.triples/1`
  repeatedly inside another `Graph.triples/1` scan.
- Keep domain modules meaningful: describe resources and neighborhoods, do not
  recreate a query engine or maintain large parallel structs that mirror RDF.

## Current Baseline

On the dev dataset imported from Fuseki on 2026-04-28:

- Quadlog current quads: 479,268.
- Document index: about 365 ms warm.
- Text unit extraction for search/embeddings: about 1.9 s for 25,399 units.

Text unit extraction is suitable for sync/rebuild jobs, not page requests.
