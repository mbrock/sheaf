# Sheaf Agent Notes

Sheaf is a Phoenix LiveView app backed by RDF data in Fuseki. It is small, but
it has real runtime state, so orient yourself before changing behavior.

## Start Here

Run `bin/status` early. It prints the facts an agent usually needs: service
mode, node name, URLs, health, RDF base IRIs, related deployed instances,
SPARQL/Fuseki endpoints, dataset diagnostics, triple count, and current process
status.

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

## Deployed Instances

The real production instance is on the Tailscale host `igloo`. SSH access works
with `ssh igloo` and does not require an interactive passphrase. The production
checkout is `/home/mbrock/sheaf`; the staging checkout is the adjacent
`/home/mbrock/sheaf.dev`.

Local `.env` records non-secret orientation pointers for these instances under
`SHEAF_PRODUCTION_*` and `SHEAF_STAGING_*`. Use those pointers to find the right
host, checkout, service unit, public URL, and remote `.env`; do not copy remote
secrets into tracked files.

When comparing or backing up real data, run backup commands on the host that
owns the target Fuseki container. `bin/triplestore backup` accepts named
instances and uses SSH plus SCP for remote backups:

```console
$ bin/triplestore backup --instance local output/backups/local/
$ bin/triplestore backup --instance staging output/backups/staging/
$ bin/triplestore backup --instance production output/backups/production/
```

Fuseki backup files are N-Quads gzip files, so a first-pass dataset diff can
sort both exports with `LC_ALL=C sort` and compare the sorted files.

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

`bin/triplestore` manages the Dockerized Fuseki dependency. Sheaf is expected to
use Docker for the triple store in local and deployed environments.

```console
$ bin/triplestore status
NAMES          IMAGE              STATUS
sheaf-fuseki   stain/jena-fuseki  Up 2 minutes
{
  "version": "5.1.0",
  "datasets": [{"ds.name": "/sheaf"}]
}

$ bin/triplestore restart
Stopped triple store container: sheaf-fuseki
Started triple store container: sheaf-fuseki
Waiting for Fuseki: http://127.0.0.1:3030/$/server
Fuseki is ready: http://127.0.0.1:3030/$/server
```

`bin/rdf` runs the local Rust RDF utility in `tools/rdfknife`. It is useful for
backup-level dataset inspection and semantic-ish diffs that handle ordinary
blank-node trees better than raw N-Quads line diffs.

```console
$ bin/rdf analyze-bnodes output/backups/local/sheaf.nq.gz
$ bin/rdf diff output/backups/production/sheaf.nq.gz output/backups/local/sheaf.nq.gz --output output/backups/diff/diff.trig
$ bin/rdf diff output/backups/production/sheaf.nq.gz output/backups/local/sheaf.nq.gz --output output/backups/diff/diff.trig --pretty output/backups/diff/diff.txt
```

`bin/rpc` evaluates Elixir on the running Sheaf node. Use this to inspect live
state without starting a second application instance.

```console
$ bin/rpc 'Node.self()'
:sheaf@temple

$ bin/rpc 'Process.whereis(Sheaf.Supervisor)'
#PID<12496.294.0>
```

`bin/docs` asks the running node for module and function docs. It is a quick way
to discover Sheaf modules and dependency APIs.

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

`bin/deploy` builds assets, compiles, and hot-reloads modified/new BEAM modules
on the running node. Do not run it for ordinary local development changes while
the dev server is running; Phoenix already recompiles and live-reloads those
changes, and an extra deploy causes annoying double reloads. Reserve `bin/deploy`
for explicit deploy/hot-reload requests or situations where the dev server's
normal reload path is not in use.

```console
$ bin/deploy
Building assets and compiling...
Checking live node for reloadable code changes...
No BEAM code changes to reload. Asset build completed.
:ok
```

Run `mix precommit` before committing. It runs compile checks, formatting,
schema upload, and tests.

```console
$ mix precommit
...
```

For browser checks, use Playwright with Chrome via `uvx`/`uv` against the
service URL reported by `bin/status` (`Public URL` or `Phoenix HTTP`). Browser
automation is appropriate for nondestructive UI checks, visual inspection, and
screenshots of the running service.

Sheaf can emit OpenTelemetry spans via a custom span processor
(`Sheaf.Tracing.RedisSinkProcessor`) that ships every ended span to a Redis
Stream as JSON. The Go CLI in `tools/otel-tail` (built into `bin/otel-tail`)
tails the stream live and prints colorized two-line summaries — that's the
primary way to inspect spans during development, in place of any web UI.

Tracing is opt-in. To enable it, set `SHEAF_OTEL_REDIS_URL` in `.env` to your
Redis URL (e.g. `redis://localhost:6379`). When that variable is unset, the
instrumentation handlers don't attach, no `RedisSink` GenServer starts, and
no spans are produced. Setting `OTEL_SDK_DISABLED=true` (or
`SHEAF_OTEL_DISABLED=true`) is a manual override that turns tracing off even
when a Redis URL is configured.

The stream name defaults to `otel:spans:<SHEAF_NODE_BASENAME>` so two Sheaf
instances on the same Redis server (e.g. production and staging both on
`igloo`) write to separate streams and don't evict each other's spans through
`MAXLEN`. With the default `SHEAF_NODE_BASENAME=sheaf` production lands on
`otel:spans:sheaf`; staging's `SHEAF_NODE_BASENAME=sheaf_dev` lands on
`otel:spans:sheaf_dev`. Override the full stream name with `SHEAF_OTEL_STREAM`
when you want explicit control.

`bin/otel-tail` is a Go binary that auto-loads `.env` from its enclosing
checkout before reading these vars, so running it in an interactive shell on
a host that runs Sheaf as a systemd service still picks up the right stream
without needing to source `.env` first.

```console
$ bin/otel-tail
16:14:19.426  sheaf.select                              123.88ms  client
  row_count: 334   operation: select   system: fuseki   address: http://localhost:3031/sheaf/sparql
16:14:19.447  SheafWeb.DocumentIndexLive.mount          144.71ms  server
16:14:19.463  GET /                                     471.42ms  server
  status_code: 200   method: GET   route: /   address: 127.0.0.1   port: 4043
```

`bin/otel-tail --backfill N` prints the last N spans before tailing live;
`--json` emits one JSON object per line for piping into `jq`; `-v` shows all
attributes, not just the promoted ones; `--no-color` disables ANSI styling.

Service name and deployment environment are settable via the standard
`OTEL_SERVICE_NAME` env var (or `SHEAF_OTEL_SERVICE_NAME` /
`SHEAF_OTEL_ENVIRONMENT`). Span retention is bounded by Redis Streams'
`MAXLEN ~ 1000000` trim — adjust in `Sheaf.Tracing.RedisSink` if needed.

If you want tracing locally, install Redis as a system service
(`apt install redis-server`) and add `SHEAF_OTEL_REDIS_URL=redis://localhost:6379`
to `.env`. `systemctl is-active redis-server` should then report `active`.

`bin/show [count]` captures one or more screenshots from the running service and
sends them to the configured Telegram chat using the Bot API. It reads
`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` from `.env`; if the chat id is
missing, it tries to discover it with `getUpdates` after the user has messaged
the bot. It is always good to show UI: after visual/layout changes, prefer
running `bin/show` so the user can quickly inspect the result.

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
- Property labels should read as relations or attributes, such as `has source
  file`, `mentions`, `is subclass of`, or `is same as`; avoid bare field names
  when the property denotes a relation.
- Prefer ontologically explicit labels when a word is ambiguous or a mass noun;
  name the countable entity or relation the data actually represents.
- Keep preferred labels univocal. If two meanings diverge, split the terms
  rather than overloading one label.
- Put usage notes, import quirks, and UI concerns in comments or definitions,
  not in the label itself.

Do not invent custom IRIs for resources. Use `Sheaf.mint/0` to make new IRIs in
the configured resource base.

The schema is defined in `priv/sheaf-schema.ttl`. Keep it up to date when the
RDF vocabulary changes.

External vocabulary labels, local alignments, and small extensions for imported
ontologies live in `priv/sheaf-ext.ttl`. Use it when Sheaf needs display labels
or bridge facts for terms from RDF/RDFS/OWL/SKOS/PROV, bibliographic
vocabularies, BFO, or other non-Sheaf namespaces. Do not put external term
labels in `priv/sheaf-schema.ttl`; keep that file for the Sheaf vocabulary
itself. `mix sheaf.schema` uploads both the Sheaf schema graph and the external
extension graph.

To change RDF data or its schema, there is no need to write enduring migration
modules. Run `mix sheaf.backup`, then alter the dataset in whatever way is most
convenient.

Mutating RDF data is mostly for migrations and error corrections. Design actual
domain operations so they add new facts to the graph monotonically rather than
relying on destructive mutation.

## Citation And Reference Notes

The index distinguishes two related citation notions. `cito:cites` links a
thesis-level document to works in its bibliography and drives the index-level
`cited` highlight. `biro:references` links a specific document block to the work
that block references; `Sheaf.Documents.references_for_document/1` returns those
block-scoped reference rows for the reader.

When working on citation behavior, inspect the live graph with `bin/rpc` instead
of guessing from UI state. Useful starting points are the workspace graph
`https://less.rest/sheaf/workspace`, the metadata graph
`https://less.rest/sheaf/metadata`, `cito:cites` for bibliography membership, and
`biro:references` for paragraph/block-level evidence.

## Known RDF Cleanup Notes

Some document graphs contain shared RDF list blank nodes around `sheaf:children`
and `rdf:rest`. These are artifacts from earlier manual list-pointer edits where
the head was moved to skip previous list items. They can be cleaned up by
deleting the now-unreachable old list tails rather than preserving them as
meaningful data.

## Development Rules

For HTTP requests in Elixir, prefer `Req`.

When the dev server is running, do not run `bin/deploy`, `mix compile`, or other
manual compile/reload commands just to make LiveView, component, CSS, or JS edits
take effect. Let Phoenix's dev reloader handle it. Use focused tests or browser
checks for verification, and only restart/redeploy when the change actually
touches startup, dependency, config, supervision, or release/runtime loading
behavior.

For Python commands, always use `uv` or `uvx`; do not call `python`,
`python3`, or `pip` directly.

Sheaf's triple store is Dockerized Fuseki. Use `bin/triplestore` rather than
inventing ad hoc Docker commands when checking status, logs, datasets, or
restarting it.

In tests, prefer `start_supervised!/1` for OTP processes so ExUnit owns cleanup.
Avoid fixed sleeps when a monitor, message assertion, or explicit readiness
check will do.

Do not run shell commands in parallel unless you deliberately want them to
execute in parallel.

Keep deployment-specific hosts and secrets out of tracked files. See `.env` for
local `PHX_HOST`, ports, SPARQL endpoints, and other machine-specific settings.
