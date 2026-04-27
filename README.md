# Sheaf

Small Phoenix LiveView app for thesis work with block-addressable structure stored in Fuseki.

## Development

Install dependencies and start the app:

```bash
mix setup
bin/start
```

Sheaf commands expect the environment to already be loaded. Human shells can use
direnv; this repository's `.envrc` sources `.env`. Non-interactive callers can
use `bin/env COMMAND...`, for example `bin/env mix precommit` or
`bin/env bin/status`. Normal commands run `bin/env check` and fail when the
current environment is missing or differs from `.env`.

The local route is `http://localhost:4000/` by default. On this machine, Caddy
terminates TLS for `https://sheaf.localhost/` and proxies to the configured
Phoenix port.

Development service helpers:

```bash
bin/start
bin/stop
bin/restart
bin/status
bin/logs
bin/triplestore status
bin/rpc 'Process.whereis(Sheaf.Supervisor)'
bin/docs :rdf
bin/docs Sheaf.mint/0
bin/deploy
```

Fresh development worktrees created by Codex or another harness can inherit the
main checkout's `.env` while keeping their tmux session, BEAM node, Phoenix
port, OpenTelemetry stream, and Redis DB separate. Because the worktree usually
targets the same Fuseki dataset, `bin/worktree setup` also pins the SQLite
embedding/task DB paths to absolute paths in the source checkout:

```bash
bin/worktree setup
bin/start
bin/status
```

`bin/worktree create parser` is also available when you want the script to create
the Git worktree itself.

By default, `bin/worktree` inherits `.env` from the repository's primary Git
worktree. Use `--source DIR`, `--port PORT`, or `--redis-db N` for explicit
control. Use `--sqlite-local` when a worktree should keep its own SQLite DBs.

These use `SHEAF_SERVICE_MODE` from the loaded environment. Supported modes are
`tmux`, `systemd`, and `launchd`; `tmux` is the convenient local default.
`bin/status` also prints derived app URLs, RDF base IRIs, SPARQL endpoints,
Fuseki server metadata, dataset names, and a quick triple count before checking
the configured service process.

`bin/rpc` evaluates Elixir on the running Sheaf node. For a development service,
`bin/deploy` runs `mix assets.build`, then uses `bin/rpc` to hot-reload modified
and newly compiled BEAM modules without starting a second application instance.
For the production systemd service, `bin/deploy` runs `bin/build-prod` and
restarts the service instead.
`bin/docs` uses the running node to show app overviews, module/function docs, and
source snippets, which is often faster than spelunking generated HTML docs.
`bin/triplestore` manages the Dockerized Fuseki dependency used by Sheaf.

Useful graph commands:

```bash
mix escript.build
bin/sheaf-admin backup
bin/sheaf-admin schema upload
```

`bin/sheaf-admin backup` writes a Fuseki backup of the configured dataset under
`output/backups/`. `bin/sheaf-admin schema upload` uploads
`priv/sheaf-schema.ttl` and supporting ontology graphs.

## Storage

Sheaf expects Fuseki to run in Docker. Local development uses the
`stain/jena-fuseki` image by default with a persistent Docker volume. The helper
script understands the same `.env` credentials used by Sheaf:

```bash
bin/triplestore start
bin/triplestore status
bin/triplestore datasets
bin/triplestore logs
bin/triplestore restart
```

Default Fuseki configuration:

* Dataset: `http://localhost:3030/sheaf`
* Query endpoint: `http://localhost:3030/sheaf/sparql`
* Update endpoint: `http://localhost:3030/sheaf/update`
* Graph Store endpoint: `http://localhost:3030/sheaf/data`
* Graph used by Sheaf: Fuseki dataset default graph
* Schema named graph: `https://less.rest/sheaf/`

Default local container settings:

* Container: `sheaf-fuseki`
* Image: `stain/jena-fuseki`
* Port: `127.0.0.1:3030->3030`
* Volume: `sheaf-fuseki-data:/fuseki`

These can be overridden with `SHEAF_TRIPLESTORE_CONTAINER`,
`SHEAF_TRIPLESTORE_IMAGE`, `SHEAF_TRIPLESTORE_HOST`,
`SHEAF_TRIPLESTORE_PORT`, `SHEAF_TRIPLESTORE_VOLUME`, and
`SHEAF_TRIPLESTORE_DATASET`.

The vocabulary namespace is `https://less.rest/sheaf/`.
Block IRIs use the configured resource base, which defaults to `https://example.com/sheaf/` outside production.

The tracked RDF vocabulary lives in `priv/sheaf-schema.ttl` and is served at `/sheaf-schema.ttl`.

## Deployment

Production build:

```bash
bin/build-prod
```

Installed service and proxy layout on this machine:

* User service file: [ops/systemd/sheaf.service](/home/mbrock/sheaf/ops/systemd/sheaf.service)
* Repo env file: [.env](/home/mbrock/sheaf/.env)
* Service entrypoint: [bin/serve-prod](/home/mbrock/sheaf/bin/serve-prod)
* Caddy snippet in repo: [ops/caddy/sheaf.example.test.caddy](/home/mbrock/sheaf/ops/caddy/sheaf.example.test.caddy)

The live service listens on `127.0.0.1:4041` and Caddy terminates TLS for your configured host.
