# Agentic Document Import

This note records findings from exploring Sheaf's PDF imports and sketches a
direction for improving them with auditable agentic repair passes.

## Problem

The current PDF import path preserves Datalab's extracted blocks and section
hierarchy almost verbatim. That gives us useful provenance, but it also means
layout artifacts become document structure:

- Paragraphs that span page breaks often become two arbitrary text blocks.
- Cover and title-page text can become top-level sections.
- Table-of-contents pages can become parent sections containing the rest of the
  document.
- Lists, directory entries, pull quotes, and local labels can become deep
  `doc:Section` nodes.
- Tables are preserved as extracted HTML, but they are currently excluded from
  the text-unit path used for search and embeddings.

The core issue is not that Datalab is bad. Its output is structured and useful.
The issue is that Sheaf currently treats extraction classes such as
`SectionHeader` and `Table` as if they were already the document ontology.

## Current Path

`Datalab.Document.document_blocks/1` flattens page children and builds a tree
from Datalab's `section_hierarchy`. Any block with
`block_type == "SectionHeader"` and an `<h1>` through `<h6>` tag becomes a
section node.

`Sheaf.PDF` then persists section nodes as `doc:Section` and ordinary nodes as
`doc:ExtractedBlock`, while preserving source metadata such as `sourceKey`,
`sourceBlockType`, `sourcePage`, and `sourceHtml`.

`Sheaf.Document.toc/2` walks `doc:children` and returns every `doc:Section`.
It does not re-interpret whether a section is semantically a section.

This means the reader's table of contents currently mirrors Datalab's header
classification.

## Data Findings

A DuckDB projection of the Quadlog-backed RDF data was materialized as
`var/pdf-blocks.parquet` for fast exploration. It contains one row per imported
PDF block with document graph, title, source type, page, source key, source
HTML, and plain text.

On this snapshot:

- There are 45,513 extracted PDF blocks across 139 document graphs.
- 35,777 blocks are text-like.
- 258 blocks are tables.
- 5,762 blocks are section headers.
- The largest section-header counts are mostly long books:
  - 292: _The Perception of the Environment_
  - 269: _Distinction_
  - 233: _Doing Anthropological Research_
  - 206: _Household Recycling and Consumption Work_

For _Distinction_, `Sheaf.Document.toc/2` returns 269 entries, exactly matching
the number of imported `SectionHeader` blocks. The result includes real book
structure, but also cover text, contents-page entries, numeric chapter markers,
source-excerpt labels, directory categories, and quotation headings.

Examples of problematic deep headings in _Distinction_ include:

- `The Catalogue of New Sporting Resources`
- `Physical expression`
- `Women discover their bodies through dance`
- `Wheels`
- `Free flight`
- `Groovy football`
- `A Grand Bourgeois 'Unique among His Kind'`
- `'The nouveau-riche approach'`
- `'For my personal enjoyment'`
- `Luxury Trade Directory from le goût du luxe`
- `ANIMALS`
- `ANTIQUES`
- `HAUTE COUTURE`
- `Rail`
- `Doctors`

These are not all the same kind of mistake. Some are local headings inside
reproduced source excerpts. Some are interview or case-profile segment labels.
Some are directory categories or subcategories. Some are genuine local
subsections but should probably not appear in the global table of contents.

## Page-Boundary Fragmentation

Adjacent text blocks around page breaks show a strong signal that many
paragraphs were split only because a page ended.

In the parquet projection:

- There are 8,077 adjacent text-block pairs crossing a page boundary.
- 6,184 have a previous block that does not end with sentence-final
  punctuation.
- 5,328 are strong continuation candidates where the previous block lacks
  terminal punctuation and the next block starts lowercase or with an opening
  parenthesis.
- Strong candidates occur in 137 of 139 PDF graphs.

Embedding similarity is directionally useful but not a complete classifier.
Using existing 768-dimensional embeddings for adjacent block pairs:

- Same-page adjacent pairs have median cosine similarity around 0.638.
- Page-boundary pairs with terminal punctuation have median around 0.643.
- Page-boundary pairs without terminal punctuation have median around 0.659.
- Strong page-boundary candidates have median around 0.662.

The shift is real, but the distributions overlap. Embeddings are better used as
a ranking or confidence feature than as the sole decision rule.

## Tables

Datalab table output is often good enough to preserve. The imported table
blocks usually contain structured HTML with `thead`, `tbody`, row spans, column
spans, math markup, superscripts, paragraphs, and lists inside cells.

The current search and embedding path includes `sourceHtml` blocks only when
`sourceBlockType` is absent or `Text`. Tables are therefore mostly invisible to
the general retrieval path, even when they contain dense information.

Tables probably need a derived representation rather than merely being embedded
as raw HTML. A model could interpret each table into one or more semantic
forms:

- a normalized relational table;
- row-wise textual records;
- compact claims or observations;
- variables, units, populations, and measurements;
- provenance links back to the original table block and cells.

The original table HTML should remain the source artifact. The derived
representation should be what search and agents use.

## Ontology Implications

Extraction type should not be treated as discourse type.

`sourceBlockType == "SectionHeader"` means Datalab saw typographic heading
layout. It does not imply that the block is a section in the authorial argument.

Useful semantic component kinds include:

- `section`
- `front matter component`
- `back matter component`
- `table of contents`
- `reproduced source`
- `source excerpt`
- `catalogue excerpt`
- `directory excerpt`
- `case profile`
- `interview excerpt`
- `excerpt heading`
- `list heading`
- `directory category`
- `directory entry`
- `pull quote`
- `run-in label`
- `caption`
- `table`
- `figure`

The local schema can keep `doc:Section` narrow: a headed container in the main
document structure. Other heading-like blocks can remain extracted blocks with
inferred component roles. For example, a block may have:

- source type: `SectionHeader`
- inferred component kind: `directory category`
- inferred component role: `local label`
- provenance: source page, source key, source HTML

This preserves Datalab provenance while making the reader outline and retrieval
model more accurate.

## SPAR Alignment

The SPAR ontologies already cover much of the territory Sheaf is moving into.
They are useful here because they explicitly separate several concerns that are
currently collapsed in the PDF import:

- bibliographic resource type, covered by FaBiO;
- document components, covered by DoCO;
- rhetorical or discourse roles, covered by DEO;
- citations and citation intent, covered by CiTO.

DoCO, the Document Components Ontology, is designed for document components,
including structural components such as blocks, paragraphs, sections, chapters,
lists, tables, figures, front matter, body matter, and back matter, as well as
some rhetorical components such as introductions, discussions, appendices, and
reference lists. It imports DEO and the Pattern Ontology.

DEO, the Discourse Elements Ontology, covers components that carry rhetorical
functions, such as acknowledgements, background, caption, conclusion,
discussion, introduction, methods, related work, results, and references. Its
model is useful because rhetorical role is not necessarily the same thing as
structural position. A `doco:Section` may have the rhetorical role
`deo:Introduction`, but an introduction can also be mixed into some other
structural component.

That distinction maps well onto the PDF import problem:

- `sourceBlockType` records extraction evidence.
- a DoCO-like component kind records structural interpretation.
- a DEO-like discourse role records rhetorical function.
- Sheaf editor state records whether this component belongs in the reader
  outline.

For example:

- a Datalab `SectionHeader` on the cover may be a `doco:Title`, not a
  `doco:Section`;
- a Datalab `SectionHeader` on a contents page may be part of
  `doco:TableOfContents`, not a body section;
- `ANIMALS` in the _Distinction_ luxury directory is closer to a list or
  directory category than to a section;
- `'For my personal enjoyment'` is closer to a quotation label or local heading
  within a case profile than to a section;
- `A Grand Bourgeois 'Unique among His Kind'` is plausibly a case profile or
  scenario-like discourse component, nested inside the book's main section.

SPAR does not appear to provide every humanities-oriented component we want,
such as `case profile`, `directory category`, `source excerpt`, or `pull quote`.
Those can be Sheaf-local subclasses or classifications aligned to broader SPAR
classes:

- `case profile` as a local document component, probably related to
  `deo:Scenario` or `deo:Biography` depending on the case;
- `source excerpt` as a local component for reproduced source material;
- `directory category` as a local kind of list heading or label;
- `pull quote` as a local kind of quotation or text box;
- `table-derived record` as a local derived information unit linked back to
  `doco:Table`.

The immediate design lesson is to avoid making `doc:Section` do all the work.
Sheaf can keep its existing block model, but add imported or aligned terms for:

- structural kind: `doco:Section`, `doco:Paragraph`, `doco:Table`,
  `doco:Figure`, `doco:List`, `doco:FrontMatter`, `doco:BodyMatter`,
  `doco:BackMatter`, `doco:TableOfContents`, `doco:Title`, `doco:Label`;
- discourse role: `deo:Introduction`, `deo:Background`, `deo:Methods`,
  `deo:Results`, `deo:Discussion`, `deo:Conclusion`, `deo:Caption`,
  `deo:Reference`;
- Sheaf-local import roles: source excerpt, case profile, directory category,
  excerpt heading, local label, table-derived record, needs review.

This gives the agent more precise tool targets. It can demote a typographic
heading from the reader outline while still classifying it as a `doco:Label` or
as a local `directory category`. It can also infer that a section titled
`Introduction` is both a structural section and a rhetorical introduction,
without conflating those two facts.

References:

- DoCO: <http://purl.org/spar/doco>
- DEO: <http://purl.org/spar/deo>
- SPAR ontology overview: <https://www.sparontologies.net/ontologies>
- DoCO paper: <https://doi.org/10.3233/SW-150177>

## Agentic Workflow Shape

The import should become a staged, auditable workflow:

1. Preserve raw extraction.
2. Materialize fast projections for analysis and candidate generation.
3. Run deterministic candidate detectors.
4. Ask a small reasoning model to classify or repair bounded windows.
5. Apply edits through explicit document-editing tools.
6. Store provenance for every inferred component and edit.
7. Rebuild derived indexes for search, embeddings, and reader navigation.

The agent should not directly rewrite the RDF graph as unstructured output. It
should call tools that correspond to editor operations Sheaf already wants to
support:

- splice adjacent paragraph blocks;
- split a block;
- demote a section to an extracted block;
- promote an extracted block to a section;
- merge a numeric chapter marker with the following heading;
- classify blocks as front matter, body, back matter, source excerpt, table,
  figure, case profile, or local label;
- build a clean outline from table-of-contents evidence;
- derive row-wise or claim-wise records from a table;
- tag blocks as needing human review.

This gives models a useful active role while keeping changes reviewable and
reversible.

## Read Replicas And Projections

Large RDF graphs are awkward for exploratory analytics. DuckDB and parquet are
much better suited for broad scans over imported block data.

Useful projections include:

- a global `pdf-blocks.parquet`;
- per-document `blocks-${docid}.parquet`;
- a page-boundary candidate dataset;
- a section-header candidate dataset;
- table blocks with parsed HTML summaries;
- embedding-neighborhood datasets for adjacent blocks.

These projections can be rebuilt from Quadlog and do not have to be canonical.
They make it cheap to inspect import quality, rank repair candidates, and feed
bounded context windows to models.

## Open Questions

- Should inferred component kind be added to the core Sheaf document ontology,
  or stored as an import-analysis layer?
- Should `doc:Section` be corrected in-place after import, or should raw
  sections be preserved with a separate reader outline?
- How much should the table-of-contents page influence the canonical outline?
- What is the right review UI for model-proposed import repairs?
- Should table-derived semantic records enter the same text-unit index as
  paragraph text, or a separate retrieval collection?
- How should repair provenance be represented so that later agents can explain
  why a block was spliced, demoted, or reclassified?

## Near-Term Experiments

- Build a `page_boundary_candidates` parquet dataset with neighboring block
  text, pages, source keys, punctuation features, and embedding similarities.
- Build a `section_header_candidates` parquet dataset with heading level,
  neighboring block types, page position, text features, and ancestry.
- Run a dry-run model pass over _Distinction_ section headers to classify each
  as main section, front matter, contents entry, source excerpt label,
  directory category, quotation label, or review-needed.
- Run a table interpretation pass over a handful of table blocks and compare
  raw HTML, normalized rows, and generated textual records.
- Add telemetry spans around import repair passes with document id, candidate
  counts, model, token counts, accepted edits, and review counts.
