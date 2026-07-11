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

### Conservative reconstruction

Sheaf now reconstructs a bounded high-confidence subset during Datalab import.
Two `Text` blocks are joined when they are adjacent in textual reading order,
cross exactly one page, retain identical section ancestry, the first lacks
sentence-final punctuation, and the second begins lowercase or with an opening
delimiter followed by lowercase text. Intervening page headers, footers,
figures, pictures, and captions are allowed; equations, lists, tables, and
section headers prevent a join.

The raw Datalab JSON remains unchanged. The reconstructed RDF block keeps every
original `sourceKey`, the first `sourcePage`, and a `sourcePageEnd`. This makes
the semantic reading unit coherent without throwing away extraction
provenance. Hyphenated page seams such as `sec-` + `tion` are dehyphenated;
ordinary seams receive one space.

For the three-paper field trial this identifies 14 joins: 5 in the
active-walker paper, 6 in the interactive street-modeling paper, and 3 in the
procedural-roads paper. The import inspection report exposes this count before
the graph is written.

## Retrieval Audit And Improvement Plan

The current hybrid retrieval is useful but still crude:

- canonical units are individual paragraph, extracted-text, equation, row, or
  note blocks;
- the embedding input adds the document title but not section ancestry or
  neighboring prose;
- one vector is stored per unit;
- lexical and semantic searches are executed separately and presented as two
  result groups rather than fused into one calibrated ranking;
- semantic search retrieves nearest vectors and filters them, but does not
  rerank candidates against the full query;
- the assistant receives section ancestry after retrieval, but not neighboring
  paragraph text;
- extracted HTML, LaTeX, tables, figures, and prose all need different useful
  projections, while the current path is mostly one generic text field.

The next retrieval work should be staged and evaluated rather than hidden in a
single complicated agent prompt.

### 1. Logical units and normalized projections

Keep source blocks immutable, but derive coherent logical units. Page-spanning
paragraph reconstruction is the first instance. Normalize HTML to readable
text for lexical and semantic indexing while retaining raw HTML and LaTeX as
separate source fields. Split abnormally long blocks by sentence windows and
combine very short fragments when confidence is high.

### 2. Contextual multi-vector indexing

Give each logical paragraph at least two searchable representations:

- a precise vector for the paragraph itself;
- a contextual vector built from document title, section breadcrumb, the
  paragraph, and bounded neighboring prose.

The precise vector helps pinpoint an answer; the contextual vector helps when
the query names a topic established in the previous paragraph or section. A
starting experiment should target roughly 250–500 tokens per contextual window
with one neighboring logical unit on each side, while returning the focal block
as the citation target.

Equations should have a math-specific representation containing LaTeX,
equation number, nearby defining prose, and symbol descriptions. Tables should
use normalized rows and generated claims rather than raw table HTML alone.

### 3. True hybrid candidate fusion

Over-fetch independently from FTS and vector search, deduplicate by logical
unit, and combine ranks with reciprocal-rank fusion before applying filters.
Cluster adjacent hits so one passage does not occupy most of the result budget.
Keep exact phrase matches as a strong feature rather than a completely separate
result category.

### 4. Neighbor expansion and reranking

After fusion, expand the top focal units with their immediate logical neighbors
and section breadcrumb. Rerank a bounded candidate set against the original
question using a query-aware reranker or a capable model. The reranker should
choose passages, not generate answers, and record its scores and model in
telemetry.

### 5. Agentic query planning

Let the research agent issue several explicit retrieval operations when a
question benefits from them: exact terminology, paraphrases, author or citation
constraints, equation symbols, and document-scoped searches. This is more
auditable than silently asking one embedding query to express every intent.
The agent should be able to read expanded passages and then request another
search when evidence is incomplete.

### 6. Evaluation before tuning

Build a small judged set from real research questions and known passages in the
current corpus. Track lexical and semantic recall at 5/10/20, reciprocal rank,
adjacent-duplicate rate, citation correctness, and whether the answer-supporting
passage survives the final context budget. Log the retrieval profile, embedding
model, fusion weights, reranker, candidate counts, and timings in OpenTelemetry.

The first version of this retrieval design is now implemented:

- paragraph and extracted-text citation IRIs receive both a precise vector and
  a contextual vector; the contextual vector includes the document title,
  section breadcrumb, focal passage, and one readable neighbor on each side;
- contextual vectors use derived `#sheaf-context` embedding identities, but are
  collapsed back to the focal RDF block IRI before hydration and ranking, so
  links and citations remain stable;
- lexical, precise-vector, and contextual-vector ranks are fused with weighted
  reciprocal-rank fusion instead of comparing incomparable raw scores;
- assistant search hits include section ancestry and bounded adjacent passages;
- `bin/sheaf-admin search evaluate priv/retrieval-eval.json` runs a reviewable
  smoke suite and reports hit rate and mean reciprocal rank;
- retrieval queries, candidate counts, fusion profile, and evaluation metrics
  are recorded as OpenTelemetry attributes.

The next refinement should be a bounded query-aware reranker over the fused
candidates, followed by more evaluation questions and dedicated equation/table
projections. The evaluation suite should grow from real research questions and
retain text evidence rather than reminted block IRIs as its ground truth.

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

### Mathematical papers

Datalab represents both inline and display mathematics as LaTeX inside custom
`<math>` elements. Sheaf preserves that source HTML, records each expression as
`sheaf:latex`, and typesets the reader copy with KaTeX. `Equation` blocks are
included in the same derived `sourceHtml` search and embedding path as extracted
prose, with `sourceBlockType` retained so callers can distinguish them.

Before import, an agent should run:

```console
$ bin/env bin/sheaf-admin import inspect-datalab var/datalab/JOB/FILE.datalab.json
```

The report is deterministic and deliberately small: pages, total blocks,
block-type frequencies, display-equation blocks, all inline and display math
expressions, pages containing math, and equation blocks that contain no parsed
LaTeX. `--json` produces machine-readable output. A nonzero empty-equation
count, unexpectedly low math count, visible transcription errors, or a large
disagreement with the source PDF is a reason to inspect the affected pages and
selectively retry them. It is not by itself a reason to discard the preserved
raw result or to rerun an entire paper in the most expensive mode.

In a three-page equation-heavy comparison from the active-walker paper,
Datalab's default pipeline and `accurate` conversion produced the same eight
equation blocks and identical LaTeX. That supports an adaptive policy: use the
normal pipeline first, validate, and escalate only when evidence warrants it.

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

## Field Trial: Three Papers From Open Browser Tabs

On 2026-07-11, a first end-to-end agentic import trial started from three PDF
URLs supplied without any accompanying metadata. The papers concerned
procedural street modeling, procedural road generation, and active-walker
models of trail formation.

The trial used the existing pieces rather than a purpose-built orchestrator:

1. Download and hash the PDFs.
2. Inspect PDF metadata and first-page text.
3. Independently search arXiv and Crossref for bibliographic identity.
4. Ingest the source files into the content-addressed blob store.
5. Submit them to Datalab and inspect the extracted headings before import.
6. Import the raw document graphs.
7. Run the queued metadata extraction workflow.
8. Continue the investigation manually when that workflow stopped.
9. Import confirmed Crossref records.
10. Build exact and semantic indexes, exercise discriminating corpus queries,
    and inspect rendered pages in a browser.

The exercise found several issues that a fixed pipeline would have missed or
handled poorly:

- One URL had initially been given a plausible but incorrect local filename.
  Reading the first page and checking the arXiv record established that it was
  Helbing et al.'s _Active Walker Model for the Formation of Human and Animal
  Trail Systems_, not the Watts-Strogatz small-world paper. URL intake should
  not treat a caller's filename or tab description as authoritative metadata.
- Datalab recovered the correct title as an `h1` for all three papers, but left
  its top-level `metadata.title` empty. The importer therefore created untitled
  documents even though the title was present in the extraction. Import
  planning needs ranked title evidence and an explicit choice, not a single
  hard-coded field.
- The bounded LLM metadata pass recovered good titles and authors, but no DOI
  was printed in the extracted text. The fixed queue consequently stopped
  before lookup. An investigating agent could search by title, compare authors,
  venue, year, and page ranges, notice Crossref aliases, and select the correct
  DOI with an evidence trail.
- A graph-construction bug placed PDF metadata in the RDF default graph rather
  than the named metadata graph. This hid all three papers from the index and
  caused reader requests to fail while resolving blocks. Post-import checks for
  graph names, document counts, resource resolution, and HTTP status would have
  caught this immediately even without knowing the implementation.
- Datalab represented each paper title as a section wrapping the entire paper.
  The desired repair was to unwrap that section. Repeated generic `move_block`
  calls were not atomic and failed after partially changing RDF lists. The
  pre-edit backup made rollback safe, but the experience argues for a dedicated
  atomic `unwrap section` operation and dry-run validation.
- Once metadata placement was repaired, the document index, full reader,
  lightweight reader, exact search, semantic search, figures, captions,
  breadcrumbs, and page references all worked well. Three discriminating test
  queries selected the intended paper and relevant passages.

This trial suggests that the orchestrator should be goal-directed rather than
merely a longer fixed pipeline. It needs tools and durable state for:

- recording the supplied URL and retrieval response as source provenance;
- inspecting PDF properties and bounded page text before extraction;
- proposing bibliographic candidates from multiple providers;
- comparing candidates against observed title, authors, venue, date, pages,
  DOI, ISBN, and repository identifiers;
- accepting a candidate with explicit evidence and confidence;
- choosing among extraction fields when they disagree or are incomplete;
- validating RDF graph placement and required document invariants;
- applying compound structural edits atomically, with preview and rollback;
- running post-import acceptance checks over APIs, rendered pages, search, and
  stored source-file access;
- using the lightweight `wd screenshot` workflow for ordinary visual acceptance
  checks, and reserving heavier browser automation for interactions or
  assertions that `wd` cannot express;
- ending in `accepted`, `needs review`, or `failed safely`, rather than treating
  a technically completed extraction as a successful import.

The most important practical lesson is that model reasoning was useful between
the existing stages, not as a replacement for them. Datalab, Crossref, arXiv,
RDF transactions, search indexes, and browser checks each provided bounded
evidence or actions. The agent's role was to decide what evidence to seek next,
recognize when a stage's success did not satisfy the overall goal, and stop a
dangerous repair when the available mutation tool was not adequate.
