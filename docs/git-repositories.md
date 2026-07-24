# Git repositories in Sheaf

Sheaf can treat a software project and its Git repository as research
resources. The integration mirrors Git's own content-addressed object graph
without trying to interpret a particular programming language.

```console
bin/env bin/sheaf-admin git sync /path/to/checkout --project "Project name"
```

The first synchronization backs up Quadlog by default. Pass `--no-backup` only
when a suitable backup has already been made. `--no-text` imports history and
topology without materializing searchable source text, and
`--max-text-bytes N` changes the per-blob text size limit.

## Identity and graph layout

The software project, Git repository, and mutable-reference graph are ordinary
minted Sheaf resources. Immutable Git-derived resources use deterministic IRIs:

```text
{resource-base}git/objects/{object-format}/{object-id}
{resource-base}git/tree-entries/{object-format}/{tree-id}/{encoded-name}
{repository-iri}/source-files/{encoded-path}
{repository-iri}/source-files/{encoded-path}#content
```

Including the object format keeps SHA-1 and SHA-256 object namespaces distinct.
Git object IDs remain the primary content identity; the full ID is also stored
with `sheaf:gitObjectId`.

The projection uses four graph roles:

- The workspace graph links a `sheaf:SoftwareProject` to its
  `sheaf:GitRepository` and records checkout and synchronization identity.
- A graph named by the repository contains immutable commits, trees, blobs,
  annotated tag objects, and tree entries. New facts are appended
  incrementally.
- A separately named reference graph contains current heads, tags, remotes,
  and `HEAD`. This small graph is atomically replaced when references move.
- A current-source graph contains selected source files from `HEAD`, each with
  one complete-content block.
  Synchronization applies statement-level additions and retractions so
  unchanged files stay put and text from old revisions stops appearing in
  search.
- Every synchronization gets a small provenance activity graph.

Only conventional project refs under `refs/heads`, `refs/tags`, and
`refs/remotes` are mirrored. Tool-internal refs such as task checkpoints are
not treated as part of the software project.

By default the repository identity is `remote:` followed by the configured
`origin` URL. A repository without `origin` uses its absolute Git directory.
Use `--identity ID` when several checkout or remote spellings should be treated
as one repository.

## Payload and text policy

Git remains the authority for bytes. Quadlog records object type, byte size,
topology, commit metadata, and tree entry names; it does not copy arbitrary
blob payloads.

For the current `HEAD`, each eligible UTF-8 source or prose path whose blob is
no larger than 512,000 bytes becomes one `sheaf:GitSourceFile`. Every source
file has exactly one `sheaf:SourceFileBlock`, addressed by the file IRI with
the `#content` fragment, containing its complete text. There are deliberately
no line or range resources yet. Binary data, PDFs, generated archives, and
oversized files retain only Git blob metadata. If several paths point to the
same blob, each path is represented as a distinct source file linked to that
shared immutable blob.

This makes moving large literature files to git-annex or another object store
compatible with the model: Git can retain a small pointer blob while Sheaf's
document and file resources continue to describe the literature itself.

## Search and embeddings

Git commits and complete source-file blocks are exposed by `Sheaf.TextUnits` as
the `gitCommit` and `sourceFile` kinds, so the existing SQLite full-text and
embedding pipelines can consume them without a second indexing architecture.
Each accepted file contributes one search row and one embedding input. Commit
author and time, and source path and inferred language, are included in
embedding context. Stable citation targets are commit IRIs and source-file
`#content` block IRIs.

Embedding input is never truncated or secretly divided. A source file whose
complete prepared input exceeds the conservative 8,000-byte embedding limit
remains available in RDF and full-text search but is omitted from semantic
indexing. The embedding plan reports the number of such files.

The usual commands work for only repository text:

```console
bin/env bin/sheaf-admin embeddings plan --kind gitCommit --kind sourceFile
bin/env bin/sheaf-admin search sync --kind gitCommit --kind sourceFile
```

Running the embedding plan first is useful for reviewing volume and cost; the
search synchronization then updates both the full-text and embedding indexes.
Synchronizing the repository itself never calls an embedding provider; it only
writes the RDF source material.

## Future semantic analyzers

Language servers, clangd, Doxygen, build-system readers, and other analyzers can
be added as independent enrichment activities. Their symbol, declaration,
reference, target, or documentation resources can point to the existing commit,
blob, and source-file identities. The Git mirror therefore does not need
C++-specific parsing or demangling, and later analyzers do not need to replace
the repository model.
