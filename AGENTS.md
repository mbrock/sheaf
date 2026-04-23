# Sheaf Agent Notes

When the repo is coherent and tests pass, commit and push.

Run `mix precommit` to run tests and format code before committing.

Before changing code that uses RDF.ex heavily, read `docs/rdf-ex.md`.

Use Req for direct HTTP requests.

Do not run commands in parallel unless you deliberately want them to execute in parallel.

Keep deployment-specific hosts and secrets out of tracked files.

The ontology namespace is `https://less.rest/sheaf/`.

The resource base is configurable in `config/runtime.exs`.

Don't invent IRIs for resources; use `Sheaf.mint/0`.

```elixir
iex(1)> Sheaf.mint
~I<https://example.com/JATCTP>
```

This is a personal project.  There are no other users or deployments.
I am making it to help my wife with her thesis work, and to develop
a delightful, novel, useful system that could become useful to others, later.

Therefore, do not add complexity in the name of performance.

This codebase must remain aligned with the ideal of short, simple, supple code.

To make changes to the RDF data or its schema, there is no need to write
enduring migration modules.  Just run `mix sheaf.backup` and then alter the
dataset in whatever way is most convenient.

The schema is defined in `priv/sheaf-schema.ttl`.  Keep it up to date.

Mutating RDF data is mostly for migrations and error corrections.
Design the actual domain operations so they don't rely on mutation,
but rather add new facts to the graph monotonically.

I care about the ontology, so confirm with me before inventing classes or properties.

# Context

My wife is finishing her master's thesis — an ethnographic study of a swapshop in Riga, looking at how people divest, acquire, and circulate things outside ordinary commerce. She has a pile of material: draft chapters, transcribed interviews, notes. The writing is underway but the material is hard to work with in its current form. Google Docs treats it all as undifferentiated text, and the interviews and the thesis live in separate files with no way to connect a claim to the passage that grounds it.

Sheaf is the tool I'm building to help her finish. Every paragraph in the thesis is a first-class block with a stable identity and a short visible ID, living inside a hierarchy of sections. The interview transcripts get ingested into the same structure, so a thesis paragraph can be explicitly linked to the passage of an interview it draws on.

The broader frame is that I already built her one tool for this thesis — a transcription system using current multimodal models that turned hours of interview audio into usable text and saved her an enormous amount of tedious work. That went well enough that I want to do it again for the next phase.
