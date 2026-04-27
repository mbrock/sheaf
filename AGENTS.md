# Sheaf Agent Notes

Sheaf is a Phoenix LiveView app backed by RDF data in Fuseki. It is small, but
it has real runtime state, so orient yourself before changing behavior.

## Start Here

Sheaf commands expect the environment to already be loaded. Human shells should
use direnv (`.envrc` sources `.env`); agent harnesses usually should prefix
commands with `bin/env`, for example `bin/env bin/status` or
`bin/env mix precommit`. If you do not use direnv or `bin/env`, export while
sourcing `.env` with `set -a; . .env; set +a` before running Sheaf commands.
Normal commands run `bin/env check` and fail
immediately if the current environment is missing or diverges from `.env`, so
agents do not accidentally operate against default or stale endpoints.

Run `bin/status` early. It prints the facts an agent usually needs: service
mode, node name, URLs, health, RDF base IRIs, related deployed instances,
SPARQL/Fuseki endpoints, dataset diagnostics, triple count, and current
process status.

```console
$ bin/status
Sheaf environment
  App root:          /Users/mbrock/sheaf
  Service mode:      tmux
  Node:              sheaf@temple
  Public URL:        https://sheaf.localhost/
  Phoenix HTTP:      http://127.0.0.1:4042/
  Resource base:     https://sheaf.less.rest/
  Ontology base:     https://less.rest/sheaf/
  Health check:      200 http://127.0.0.1:4042/health

Related instances
production
  Public URL:        https://sheaf.less.rest/
  SSH host:          igloo
  App root:          /home/mbrock/sheaf
  Env file:          /home/mbrock/sheaf/.env
  Service:           systemd sheaf.service
  SPARQL dataset:    http://localhost:3030/sheaf
  Fuseki container:  fuseki
staging
  Public URL:        https://devsheaf.less.rest/
  SSH host:          igloo
  App root:          /home/mbrock/sheaf.dev
  Env file:          /home/mbrock/sheaf.dev/.env
  Service:           systemd sheaf-dev.service
  SPARQL dataset:    http://localhost:3031/sheaf
  Fuseki container:  sheaf-fuseki-dev

SPARQL / Fuseki
  Dataset:           http://localhost:3030/sheaf
  Fuseki server:     reachable http://localhost:3030
  Fuseki version:    5.1.0
  Datasets:          /kg, /sheaf
  Triples:           197

Service process
Sheaf is running in tmux session: sheaf-dev
```

## Development Rules

Instrument code with OpenTelemetry spans to make it easier to understand and
debug. Include significant parameters and values as attributes. Avoid
truncating metadata values or formatting them in arbitrary ways; access to
full values is invaluable for debugging and analysis.

For HTTP requests in Elixir, prefer `Req`. It takes care of telemetry for the
HTTP request and responses, but it's usually good to wrap such low level spans
in meaningful domain spans.

When the dev server is running, do not run `bin/deploy`, `mix compile`, or
other manual compile/reload commands for changes that Phoenix's dev reloader
handles. It recompiles modified Elixir modules and rebuilds CSS/JS assets
automatically. (It does not restart GenServers or other long-running
processes.)

For Python commands, always use `uv` or `uvx`; do not call `python`,
`python3`, or `pip` directly.

Client JavaScript assets are installed with Bun.

Bun is also the preferred JS runtime rather than Node in case you want to run
JS code in the shell.

Sheaf's triple store is Dockerized Fuseki. Use `bin/triplestore` rather than
inventing ad hoc Docker commands when checking status, logs, datasets, or
restarting it.

In tests, prefer `start_supervised!/1` for OTP processes so ExUnit owns
cleanup. Avoid fixed sleeps when a monitor, message assertion, or explicit
readiness check will do.

Codex agents: note that your shell tool lets you run commands in parallel,
which is efficient but only makes sense when the commands are causally
independent.

Keep deployment-specific hosts and secrets out of tracked files. See `.env`
for local `PHX_HOST`, ports, SPARQL endpoints, and other machine-specific
settings.

Commit liberally when you've completed a task. Even if the user may want to
change something or continue working, it's good to have checkpoints. It's also
fine to commit in the middle of a complex task when the code is in a coherent
state and you're about to embark on a new sub-task.

## Local Commands

`bin/start` starts the configured local service mode and waits for `/health`.

```console
$ bin/start
Started Sheaf in tmux session: sheaf-dev
Waiting for Sheaf health check: http://127.0.0.1:4042/health
Sheaf health check is ready: http://127.0.0.1:4042/health
```

`bin/restart` restarts the service and waits until the app is ready again. Use
this after dependency, config, supervision tree, or startup changes.

```console
$ bin/restart
Stopped Sheaf tmux session: sheaf-dev
Started Sheaf in tmux session: sheaf-dev
Waiting for Sheaf health check: http://127.0.0.1:4042/health
Sheaf health check is ready: http://127.0.0.1:4042/health
```

`bin/stop` stops the configured service.

```console
$ bin/stop
Stopped Sheaf tmux session: sheaf-dev
```

`bin/logs` prints recent service output.

```console
$ bin/logs
[info] Running SheafWeb.Endpoint with Bandit at 127.0.0.1:4042 (http)
[info] GET /health
[info] Sent 200 in 1ms
```

Sheaf emits OpenTelemetry spans. The `bin/otel` tool is a great way to see
what's happening in the running service.

```console
$ bin/otel # shows a good amount of recent telemetry
[...]
1kq6yr2ye GET  962.55ms  T+0.0s
  ¶ returned status 101
  ¶ had method GET
  ¶ at 127.0.0.1
  ¶ on port 4042
1kq6yr48g SheafWeb.DocumentIndexLive.mount  1.34s  T+0.0s
  1kq6yr43a sheaf.select  1.17s  T+0.0s
    ¶ statement size 6551 bytes
    ¶ returned 334 rows
    ¶ did select
    ¶ spoke to fuseki
    ¶ at http://localhost:3030/sheaf/sparql
    1kq6yr42c HTTP POST  1.15s  T+0.0s
      ¶ peered with localhost
      ¶ via port 3030
    1kq6yr43a sheaf.sparql.parse  22.90ms  T+1.1s
      ¶ returned 334 rows
      ¶ response size 357857 bytes
      ¶ decoded "application/sparql-results+json; charset=utf-8"
      ¶ did select
      ¶ spoke to fuseki
[...]
```

See `bin/otel --help` for more options (raw JSON output, span details by ID,
etc).

`bin/rpc` evaluates Elixir on the running Sheaf node. Use this to inspect live
state without starting a second application instance.

```console
$ bin/rpc 'Node.self()'
:sheaf@temple

$ bin/rpc 'Process.whereis(Sheaf.Supervisor)'
#PID<12496.294.0>
```

Use `bin/docs` to learn about modules and functions in both Sheaf and its
dependencies. It is designed for agent use. This is much faster than searching
the web and a great way to get oriented before going to the source code.

```console
$ bin/docs
# Sheaf module overview

Sheaf modules
- Sheaf - Core helpers for minting resource IRIs and working with the Graph Store.
  - Sheaf.NS - RDF vocabularies used by Sheaf.
  - Sheaf.Document - RDF navigation helpers for reader document graphs.

$ bin/docs :rdf
# Rdf module overview

Rdf modules
- RDF - The top-level module of RDF.ex.
  - RDF.Graph - A set of RDF triples with an optional name.

$ bin/docs --source Sheaf.mint/0
# Sheaf.mint/0
Signature: mint()
Generates a new unique IRI for a resource.
Source excerpt 11-40:
  11:   @doc """
  14:   def mint do
```

`bin/deploy` builds assets, compiles, and hot-reloads modified/new BEAM
modules on the running node. Do not run it for ordinary local development
changes while the dev server is running; Phoenix already recompiles and
live-reloads those changes, and an extra deploy causes annoying double
reloads. Reserve `bin/deploy` for explicit deploy/hot-reload requests or
situations where the dev server's normal reload path is not in use.

```console
$ bin/deploy
Building assets and compiling...
Checking live node for reloadable code changes...
No BEAM code changes to reload. Asset build completed.
:ok
```

Run `mix precommit` before committing. It runs compile checks, formatting,
schema upload, and tests.

For browser checks, use Playwright with Chrome via `uvx`/`uv` against the
service URL. Browser automation is appropriate for nondestructive UI checks,
visual inspection, and screenshots of the running service.

`bin/show [count]` captures one or more screenshots from the running service
and sends them to the configured Telegram chat using the Bot API. If the user
requests screenshot updates, use this after visual changes. [TODO: it should
take a request path argument]

## RDF Notes

Read `docs/rdf-ex.md` for the Elixir RDF cheat sheet: builder DSL, IRI
vocabulary namespace modules, graph/dataset structures, literals, and common
RDF.ex idioms.

Read `docs/ontology-labeling.md` before designing or changing RDF schemas,
vocabulary terms, RDF data representations, or labels. The most important
principles:

- Labels are human terms, not machine identifiers; do not expose code spelling
  or compact IRI mechanics as the preferred label.
- Class labels should normally be singular lowercase common nouns or noun
  phrases, with capitals reserved for proper names, standards, protocols, and
  established acronyms.
- Property labels should read as relations or attributes, such as
  `has source file`, `mentions`, `is subclass of`, or `is same as`; avoid bare
  field names when the property denotes a relation.
- Prefer ontologically explicit labels when a word is ambiguous or a mass
  noun; name the countable entity or relation the data actually represents.
- Keep preferred labels univocal. If two meanings diverge, split the terms
  rather than overloading one label.
- Put usage notes, import quirks, and UI concerns in comments or definitions,
  not in the label itself.

Do not invent custom IRIs for resources. Use `Sheaf.mint/0` to make new IRIs
in the configured resource base.

The schema is defined in `priv/sheaf-schema.ttl`. Keep it up to date when the
RDF vocabulary changes.

External vocabulary labels, local alignments, and small extensions for
imported ontologies live in `priv/sheaf-ext.ttl`. Use it when Sheaf needs
display labels or bridge facts for terms from RDF/RDFS/OWL/SKOS/PROV,
bibliographic vocabularies, BFO, or other non-Sheaf namespaces. Do not put
external term labels in `priv/sheaf-schema.ttl`; keep that file for the Sheaf
vocabulary itself. `bin/sheaf-admin schema upload` uploads both the Sheaf
schema graph and the external extension graph.

To change RDF data or its schema, there is no need to write enduring migration
modules. Run `bin/sheaf-admin backup`, then alter the dataset in whatever way
is most convenient.

Mutating RDF data is mostly for migrations and error corrections. Design
actual domain operations so they add new facts to the graph monotonically
rather than relying on destructive mutation.

## RDF Data Backup and Comparison

When comparing or backing up real data, run backup commands on the host that
owns the target Fuseki container. `bin/triplestore backup` accepts named
instances and uses SSH plus SCP for remote backups.

The custom `bin/rdf` tool can diff such N-Quads files with blank-node
normalization.

## RDF Data Access Patterns

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

There is no particular reason why even Phoenix views can't use such models in
assigns, etc.

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
