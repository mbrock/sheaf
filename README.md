# Sheaf

Sheaf is a collaborative research workspace for reading, writing, citing, and
working with scholarly material at paragraph scale.

It turns a research corpus into something you can point at. Papers, books,
notes, drafts, spreadsheet rows, images, citations, assistant conversations, and
revisions become stable resources in a shared workspace. A paragraph is not just
text on a page; it has an address, a place in a document, a source, a history,
and relations to the rest of the work.

The short version:

- every meaningful block gets a stable ID like `#HCFU75`;
- those IDs are clickable, previewable, searchable, and citable;
- documents can be read as prose, searched as a corpus, and traversed as a
  graph;
- assistants work inside that same addressable world, so their claims can be
  checked instead of merely trusted;
- edits, imports, notes, and agent actions can carry provenance.

Sheaf began as a tool for supporting Ieva Lange's master's thesis on a Riga
swapshop. It has grown into a working experiment in what AI-assisted scholarship
can feel like when the assistant is not floating above a pile of files, but
working inside a stable, inspectable, citable world.

## A Sheaf Moment

One practical example captures the point.

A researcher asks:

> Can you check whether this thesis has bibliography entries that are not cited,
> or citations in the text that are missing from the bibliography?

In an ordinary workflow, that means printing the manuscript, printing the
bibliography, taking out two highlighters, and hoping the last mismatch is found
before patience runs out.

In Sheaf, the assistant can read the thesis outline, expand the whole draft,
search the document, inspect the bibliography, and come back with a structured
audit:

- bibliography entries that appear not to be cited;
- citations that appear not to have bibliography entries;
- year and spelling mismatches;
- ambiguous author-year cases that need human judgment;
- concrete cleanup suggestions.

The useful part is not just that the answer is fast. The useful part is that the
answer is grounded in block IDs. If the assistant says the text cites
`Gregson (2007)` in `#PW535S`, and that the bibliography entry at `#CGY7E2`
may not be the intended source, both handles can be opened immediately. The
writer can inspect the exact paragraph, inspect the exact bibliography entry,
decide what is true, and fix the draft.

That is the kind of assistance Sheaf is built for: careful structural work that
keeps scholarship moving without taking the author out of the loop.

## The Basic Idea

Most writing tools treat documents as containers. Most AI tools treat documents
as chunks. Most citation tools treat references as strings.

Sheaf treats scholarly work as a set of connected practices: reading, sorting,
quoting, searching, revising, checking, comparing, following a thread, returning
to a source, and carrying useful pieces forward into new writing.

The central design choice is stable identity at the paragraph level. A block ID
is small enough to use fluently and precise enough to verify. It lets a piece of
thinking travel without becoming anonymous.

Once paragraphs have stable identities, a lot becomes possible:

- a note can cite the exact paragraph that prompted it;
- a draft can link directly to the source block behind a claim;
- a search result can become a durable reference instead of a transient hit;
- an assistant response can be audited by clicking the IDs it names;
- a paragraph can be revised while keeping its provenance;
- a bibliography can be checked against the text that actually cites it.

The goal is not to make research frictionless. Some friction is the work. The
goal is to give the work better handles.

## What Sheaf Does

Sheaf is a paragraph store. Imported documents are broken into addressable
blocks with stable IDs, hierarchy, source context, and embeddings. The paragraph
is treated as a first-class scholarly object: small enough to cite precisely,
large enough to carry an argument.

Sheaf is a bibliographic graph. Works, expressions, manifestations, source
files, imports, datasets, notes, citations, and revisions are modeled as related
resources. RDF is used because scholarship already depends on identity,
provenance, relation, and source.

Sheaf is a reading environment. Documents render as structured prose with
outline navigation, block previews, semantic search, and visible handles for the
places you may want to return to.

Sheaf is a writing environment. Drafts can be edited paragraph by paragraph.
References to sources and notes can stay close to the prose they support.
Revision history is part of the object, not a hidden accident of the editor.

Sheaf is an assistant workspace. Agents can search the corpus, inspect
documents, produce research notes, audit citations, help restructure prose, and
make bounded edits. Their work is meant to be visible, attributable, and
verifiable.

Sheaf is also a small claim about AI: language models become much more useful
when their world is stable enough to point into. Fluency is not enough. A good
assistant needs handles, boundaries, source context, and a way to show its work.

## A Brīvbode For Thought

The first serious use case for Sheaf was a thesis about a brīvbode: a swapshop
where things are received, sorted, cared for, recirculated, or discarded.

That metaphor turned out to be more than decorative. Sheaf does similar work for
scholarly material. Papers and notes come in. Paragraphs are separated, named,
searched, compared, kept, ignored, revived, cited, and recombined. Useful
fragments move into new writing without losing where they came from.

Keep things moving. Hold them together. That is a good description of a
swapshop, a bibliography, a thesis draft, and a research workspace.

## Design Commitments

Stable identity beats anonymous retrieval. Semantic search is useful, but it
should lead to named things that can be opened again.

Citation should be lively and precise. References should be easy enough to use
often, dense enough to support thought, and concrete enough to verify.

Assistants should work inside declared boundaries. Asking a question, writing a
research note, and editing a draft are different powers.

AI-assisted work should have provenance. It should be possible to know what
changed, when it changed, why it changed, and under whose instruction.

The interface should have grip. Sheaf is built for sustained attention: dense
surfaces, visible structure, useful edges, and enough craft in the frame for the
text to feel at home.

Tools should extend skill rather than replace it. Sheaf is not here to make a
researcher less capable. It is here to make careful practices faster, denser,
and more reliable.

## Technology

Sheaf is built with Elixir and Phoenix LiveView. Its corpus lives in Quadlog, a
SQLite-backed RDF quad store. Documents are imported into structured resources,
embedded for semantic search, and connected through RDF relations. Assistant
tools are deliberately bounded. The system emits OpenTelemetry spans because the
work should be observable while it is happening.

Those details matter, but they are not the point by themselves. The point is the
substrate they make possible: a research world where paragraphs, citations,
notes, documents, searches, assistant actions, and revisions can all be named
and followed.

## Local Development

Sheaf expects its environment to be loaded from `.env`. If you use `direnv`,
entering the directory should be enough. Otherwise prefix commands with
`bin/env`.

```console
$ bin/env bin/status
$ bin/env bin/start
$ bin/env bin/logs
```

Useful command-line entry points:

```console
$ bin/env bin/sheaf notes
$ bin/env bin/sheaf doc WG8SNC
$ bin/env bin/sheaf outline WG8SNC
$ bin/env bin/sheaf read WG8SNC
$ bin/env bin/sheaf get HCFU75
```

Run the usual checks before committing:

```console
$ bin/env mix precommit
```

## Status

Sheaf is a real working system, built for a real thesis, under real deadlines.
It is also a research prototype, a design argument, and a personal tool. Some
parts are polished because they had to be used every day. Some parts are rough
because they were built in the order the work demanded.

It is not trying to be a generic note-taking app. It is trying to find out what
scholarly software can become when citation, provenance, paragraph identity, and
AI collaboration are treated as one problem.
