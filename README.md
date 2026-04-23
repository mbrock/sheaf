# Sheaf

Small Phoenix LiveView app for thesis work with block-addressable structure stored in Fuseki.

## Development

Install dependencies and start the app:

```bash
mix setup
mix phx.server
```

The local route is `http://localhost:4000/`.

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
