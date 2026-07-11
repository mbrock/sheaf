# Sheaf Client Agent Notes

This TypeScript client should preserve Sheaf's RDF semantics as far through the
client boundary as practical. Avoid turning explicit RDF vocabulary meaning into
implicit meaning hidden in ad hoc object mappers.

The failure mode to avoid is:

```text
RDF graph with explicit predicates and vocabulary meaning
-> ad hoc object walker
-> bespoke JSON shape
-> another mapper
-> UI type
-> meaning is now implicit in code paths and field names
```

At that point the client is not really using RDF; it is mining RDF for
ingredients and throwing away the model.

## JSON-LD Role

JSON-LD is the main semantic adapter for this package.

- `@context` keeps names such as `children`, `creator`, and `status` tied to
  their RDF predicates.
- Compaction removes IRI noise without erasing the underlying IRIs.
- `@id`, `@type`, typed literals, and list containers carry RDF structure
  forward into TypeScript-facing data.
- Frames can provide view shape without inventing a private mini-format.
- Expansion remains available when a compacted view becomes ambiguous.

The JSON-LD files in `tools/sheaf-client/jsonld` are the source of truth for contexts and
frames. Do not duplicate them as hardcoded fallback structures in the client.
If a context or frame cannot be loaded, fail loudly; silent fallback makes drift
between the code and the JSON-LD contract hard to notice.

Before writing procedural "swizzling" code, check whether the JSON-LD context or
frame should express the structure instead. For example, ordered
`sheaf:children` values are RDF lists, so the context declares
`"@container": "@list"` instead of using a custom post-processing traversal.

## Projection Code

Projection code is appropriate when it represents a real view-level decision,
such as:

- choosing a display label fallback order
- sorting documents
- counting citations
- selecting preview text
- filtering outline blocks to sections

Projection code is not appropriate for structure JSON-LD already knows how to
express, such as:

- compact names
- IRI-valued relations
- typed integers
- RDF lists
- embedded graph shape where a frame is sufficient

Keep projections small, named, and explicit about the view decision they make.
Do not gradually replace RDF vocabulary meaning with schemaless, contextless
JSON blobs.
