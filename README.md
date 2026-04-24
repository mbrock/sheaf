# Sheaf

Small Phoenix LiveView app for thesis work with block-addressable structure stored in Fuseki.

## Development

Install dependencies and start the app:

```bash
mix setup
bin/start
```

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
bin/rpc 'Process.whereis(Sheaf.Supervisor)'
bin/docs :rdf
bin/docs Sheaf.mint/0
bin/deploy
```

These use `SHEAF_SERVICE_MODE` from `.env`. Supported modes are `tmux`,
`systemd`, and `launchd`; `tmux` is the convenient local default. `bin/status`
also prints derived app URLs, RDF base IRIs, SPARQL endpoints, Fuseki server
metadata, dataset names, and a quick triple count before checking the configured
service process.

`bin/rpc` evaluates Elixir on the running Sheaf node. `bin/deploy` runs
`mix assets.build`, then uses `bin/rpc` to hot-reload modified and newly compiled
BEAM modules without starting a second application instance.
`bin/docs` uses the running node to show app overviews, module/function docs, and
source snippets, which is often faster than spelunking generated HTML docs.

Useful graph commands:

```bash
mix sheaf.backup
mix sheaf.schema
```

`mix sheaf.backup` writes a TriG backup of the configured dataset under `output/backups/`.
`mix sheaf.schema` uploads `priv/sheaf-schema.ttl` to the schema named graph.

## Storage

Default Fuseki configuration:

* Dataset: `http://localhost:3030/sheaf`
* Query endpoint: `http://localhost:3030/sheaf/sparql`
* Update endpoint: `http://localhost:3030/sheaf/update`
* Graph Store endpoint: `http://localhost:3030/sheaf/data`
* Graph used by Sheaf: Fuseki dataset default graph
* Schema named graph: `https://less.rest/sheaf/`

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
* Service entrypoint: [bin/serve](/home/mbrock/sheaf/bin/serve)
* Caddy snippet in repo: [ops/caddy/sheaf.example.test.caddy](/home/mbrock/sheaf/ops/caddy/sheaf.example.test.caddy)

The live service listens on `127.0.0.1:4041` and Caddy terminates TLS for your configured host.
