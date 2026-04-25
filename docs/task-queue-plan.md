# SQLite Task Queue Plan

Goal: add a small durable queue for slow metadata work without turning Sheaf
into a job platform. RDF stays the semantic source of truth; SQLite stores
execution state, retries, locks, and cached service responses.

## Shape

Use the existing embeddings SQLite database path at first. Add general tables:

- `task_batches`: one row per requested batch of work.
- `tasks`: one row per unit of work.

Each batch and task should also have a minted Sheaf IRI. Store that IRI in
SQLite, and write durable public facts to a named jobs graph, for example
`https://less.rest/sheaf/jobs`.

SQLite fields hold operational details:

- queue, kind, status, priority
- subject IRI, unique key
- attempts, max attempts, run after
- locked by, locked until
- input/result/error JSON
- inserted, updated, finished timestamps

RDF facts hold inspectable corpus history:

- batch/task resource type
- target document or metadata resource
- requested operation
- created/started/completed timestamps
- final status
- links from batch to member tasks

## Metadata Workflow

Use separate task kinds so risky mutation is last:

1. `metadata.scan_identifiers`
   Read bounded bibliographic text from a document. Find DOI/ISBN candidates
   with page/chunk context. No network and no RDF mutation.

2. `metadata.crossref.lookup`
   Query Crossref for deduplicated DOI/ISBN candidates. Rate limit this queue
   and cache misses as well as hits.

3. `metadata.match_candidate`
   Compare Crossref metadata against the Sheaf title and local clues. Produce
   confidence and reasons.

4. `metadata.import_crossref`
   Only for high-confidence matches or explicit review acceptance. Merge
   Crossref metadata into the metadata graph.

## Runner

Start with Mix tasks, not a supervised always-on worker:

- `mix sheaf.tasks.enqueue_metadata_scan`
- `mix sheaf.tasks.work metadata --limit 100`
- `mix sheaf.tasks.list metadata`

Workers claim work with `BEGIN IMMEDIATE`: find runnable task, mark it running,
set a lease, then commit. Completion updates SQLite first, then writes final RDF
facts. Failed attempts get `run_after` backoff; terminal failures stay visible.

## Rules

- Never import metadata from a raw DOI regex hit alone.
- Prefer first-page DOI hits; treat last-page-only hits as likely references.
- Crossref title matching decides automatic import eligibility.
- Keep queue rows idempotent with `unique_key`, especially for
  `{kind, subject_iri, identifier}`.
- Back up RDF before mutation batches.
