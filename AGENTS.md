# Sheaf Agent Notes

Sheaf is a Phoenix LiveView app backed by RDF data in Fuseki. It is small, but
it has real runtime state, so orient yourself before changing behavior.

## Start Here

Run `bin/status` early. It prints the facts an agent usually needs: service
mode, node name, URLs, health, RDF base IRIs, SPARQL/Fuseki endpoints, dataset
diagnostics, triple count, and current process status.

```console
$ bin/status
Sheaf environment
  App root:          /Users/mbrock/sheaf
  Service mode:      tmux
  Node:              sheaf@temple
  Public URL:        https://sheaf.localhost/
  Phoenix HTTP:      http://127.0.0.1:4042/
  Health check:      200 http://127.0.0.1:4042/health

SPARQL / Fuseki
  Dataset:           http://localhost:3030/sheaf
  Fuseki server:     reachable http://localhost:3030
  Fuseki version:    5.1.0
  Datasets:          /kg, /sheaf
  Triples:           197

Service process
Sheaf is running in tmux session: sheaf-dev
```

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
on the running node. Use it for code-only changes that do not need a full restart.

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

Do not invent custom IRIs for resources. Use `Sheaf.mint/0` to make new IRIs in
the configured resource base.

The schema is defined in `priv/sheaf-schema.ttl`. Keep it up to date when the
RDF vocabulary changes.

To change RDF data or its schema, there is no need to write enduring migration
modules. Run `mix sheaf.backup`, then alter the dataset in whatever way is most
convenient.

Mutating RDF data is mostly for migrations and error corrections. Design actual
domain operations so they add new facts to the graph monotonically rather than
relying on destructive mutation.

## Development Rules

For HTTP requests in Elixir, prefer `Req`.

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
