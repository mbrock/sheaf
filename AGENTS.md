# Sheaf Agent Notes

When the repo is coherent and tests pass, commit and push.

Run `mix precommit` to run tests and format code before committing.

Keep deployment-specific hosts and secrets out of tracked files.

The ontology namespace is `https://less.rest/sheaf/`.

The resource base is configurable in `config/runtime.exs`.

Don't invent IRIs for resources; use `Sheaf.mint/0`.

```elixir
iex(1)> Sheaf.mint
~I<https://example.com/JATCTP>
```
