# Sheaf Agent Notes

Run `mix precommit` to run tests and format code before committing.

Read `docs/rdf-ex.md` for the Elixir RDF cheat sheet (builder DSL, IRI vocabulary namespace modules, etc.)

Don't invent custom IRIs for resources; use `Sheaf.mint/0` to make new IRIs in the resource base.

For HTTP requests in Elixir, prefer Req.

Do not run shell commands in parallel unless you deliberately want them to execute in parallel.

Keep deployment-specific hosts and secrets out of tracked files.

See the .env file for PHX_HOST and other production-specific configuration.

To make changes to the RDF data or its schema, there is no need to write
enduring migration modules.  Just run `mix sheaf.backup` and then alter the
dataset in whatever way is most convenient.

The schema is defined in `priv/sheaf-schema.ttl`.  Keep it up to date.

Mutating RDF data is mostly for migrations and error corrections.
Design the actual domain operations so they don't rely on mutation,
but rather add new facts to the graph monotonically.
