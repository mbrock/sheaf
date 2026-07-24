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
{repository-iri}/source-directories/{encoded-path}
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
- A current-source graph represents the repository as a `sheaf:Document`.
  Its ordered `sheaf:children` hierarchy follows the current source directory
  tree: directories contain directories and files, and each file contains one
  complete-content block.
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

This navigable source hierarchy is a replaceable view of the current `HEAD`;
it does not replace or duplicate the immutable Git commit/tree/blob graph.
Directories and files use stable, repository-scoped path identities, while
their content blocks continue to point at the immutable blobs that supplied
their text.

This makes moving large literature files to git-annex or another object store
compatible with the model: Git can retain a small pointer blob while Sheaf's
document and file resources continue to describe the literature itself.

## Search and embeddings

Git commits and complete source-file blocks are exposed by `Sheaf.TextUnits` as
the `gitCommit` and `sourceFile` kinds, so the existing SQLite full-text and
embedding pipelines can consume them without a second indexing architecture.
Every current source-file row is scoped to the repository document rather
than to an isolated file pseudo-document. Repository-scoped search can
therefore filter directly by the repository ID, and hydrated results derive
breadcrumbs and neighboring files from the same document hierarchy.
Each accepted file contributes one full-text search row. A file that does not
fit in one embedding request is divided into overlapping, bounded segments only
inside the derived vector index. Those segment identities are not RDF
resources: all segment matches hydrate and deduplicate to the file's single
`#content` block. Commit author and time, and the source path, are included in
embedding context. Stable citation targets are commit IRIs and source-file
`#content` block IRIs.

Search results show a bounded matching excerpt plus the file's byte and line
counts. Agents can pass the returned complete `#content` IRI to the ordinary
`read` tool to retrieve the full file. The full content is therefore available
without being copied wholesale into every search result.

The usual commands work for only repository text:

```console
bin/env bin/sheaf-admin embeddings plan --kind gitCommit --kind sourceFile
bin/env bin/sheaf-admin search sync --kind gitCommit --kind sourceFile
```

Running the embedding plan first is useful for reviewing volume and cost; the
search synchronization then updates both the full-text and embedding indexes.
Synchronizing the repository itself never calls an embedding provider; it only
writes the RDF source material.

## Updating a registered checkout

The software-project page exposes an **Update repository** action for a
registered checkout. It is deliberately constrained: the checkout path comes
from the repository's RDF registration, the worktree must be clean, the current
branch must have an upstream, terminal credential prompts are disabled, and Git
is invoked with `pull --ff-only`.

After a successful pull, Sheaf backs up Quadlog, synchronizes the Git object,
reference, and current-source graphs, rebuilds the lexical search mirror, and
incrementally refreshes embeddings. The page reports whether HEAD advanced or
was already current. The work continues under the application task supervisor
if the browser leaves the page.

## Future semantic analyzers

Language servers, clangd, Doxygen, build-system readers, and other analyzers can
be added as independent enrichment activities. Their symbol, declaration,
reference, target, or documentation resources can point to the existing commit,
blob, and source-file identities. The Git mirror therefore does not need
C++-specific parsing or demangling, and later analyzers do not need to replace
the repository model.
