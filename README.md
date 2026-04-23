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
mix sheaf.smoke
mix sheaf.seed_sample
```

`mix sheaf.smoke` verifies read/write access to the configured named graph.
`mix sheaf.seed_sample` inserts a minimal thesis outline when the graph has no thesis yet.

## Storage

Default Fuseki configuration:

* Query endpoint: `http://localhost:3030/kg/sparql`
* Update endpoint: `http://localhost:3030/kg/update`
* Named graph: `https://example.com/sheaf/graph/main`

The vocabulary namespace is `https://example.com/sheaf/`.
Block IRIs use `https://example.com/sheaf/<id>`.

## Deployment

Production build:

```bash
bin/build-prod
```

Installed service and proxy layout on this machine:

* User service file: [ops/systemd/sheaf.service](/home/mbrock/sheaf/ops/systemd/sheaf.service)
* User env file: `~/.config/sheaf/sheaf.env`
* Service entrypoint: [bin/serve](/home/mbrock/sheaf/bin/serve)
* Caddy snippet in repo: [ops/caddy/sheaf.example.test.caddy](/home/mbrock/sheaf/ops/caddy/sheaf.example.test.caddy)

The live service listens on `127.0.0.1:4041` and Caddy terminates TLS for `https://sheaf.example.test`.
