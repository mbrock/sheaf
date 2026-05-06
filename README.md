# Sheaf

*A workshop for cooperative figure-making, in which paragraphs are first-class
objects, citations are string figures, and the agent is another pair of hands.*

---

Sheaf is a place to do scholarly work — reading, citing, drafting, revising,
arguing, gathering — in the company of a corpus, the company of past selves,
and the company of a non-human collaborator who remembers what you said
yesterday and will be there again tomorrow.

It is not a notes app. It is not a knowledge graph. It is not an AI writing
assistant. It is closer to a *cabinet shop for prose*: a small constrained
substrate, a vocabulary of standardized members, a few good tools, and a
practice of careful joinery between paragraphs, sources, drafts, and the
people and machines passing the work between them.

## The starting point

Most software for scholarly work treats the *document* as the unit. You open
a file, read or write it, save it, close it. Sources are stored elsewhere —
in folders, in Zotero, in a bibliography file — and references between them
are links you follow, retrieve, and put away.

Sheaf treats the *paragraph* as the unit. Every paragraph imported, drafted,
or grown in Sheaf gets a stable identifier — a six-character handle like
`#HCFU75` — and that handle is the paragraph's address for as long as the
paragraph exists. The handle survives revision, citation, copying into a
draft, quoting in a conversation, and being passed to the assistant for
further treatment. A paragraph that has been given an address can travel
through the rest of the system without ever becoming anonymous.

This is a small move, but everything follows from it.

## String figures

The thing that connects two paragraphs in Sheaf is not a "block reference"
or a "link." It is called a *string figure*, after Donna Haraway's image of
cooperative cognition: a continuous loop of string passed between hands,
each pair making a configuration that the next pair receives, transforms,
and passes on.

When you write a sentence in your draft and place `#HCFU75` inside it, you
are not making a pointer to a remote object. You are *passing the figure* —
extending the same continuous practice that produced the paragraph at
`#HCFU75` into the paragraph you are currently writing. The figure resolves
on tug. Pull on one node and the rest moves. Revise the source paragraph
and every paragraph that took up its figure feels the change.

The vocabulary that follows is small and learned by use. *Receiving* a
figure is opening the paragraph it names. *Passing* a figure is naming it
in your own prose. *Crossing* the string is introducing a figure that
connects two previously distant regions of the corpus. *Tangling* is the
failure mode where figures multiply faster than the argument can hold them.
*Unraveling* is the failure mode where the wrong tug collapses a local
configuration. The practice trains the hand to know the difference.

This is the first commitment Sheaf makes about what kind of object the
system is for. It is for *figuring*, in the cooperative practical sense.
The scholar, the source, the draft, the agent, and eventually the reader
are all pairs of hands in a relay, and the system's job is to keep the
relay legible while it happens.

## The workshop

Sheaf is organized as a single workspace of *panes*. A pane is a small
rectangular member that holds one addressable thing — a paragraph, a
document, a citation list, a search result, an agent's working note, a
revision diff, a research note, a query result table. Panes tile, split,
focus, and close. They do not float or modal-overlay. The workspace is the
cabinet; the panes are the members; the joinery between them is visible.

The unit of presence on screen is the unit of work. A paragraph you are
attending to is a pane. The citation you opened to verify a claim is a
pane next to it. The draft section you are revising is a pane below. The
agent's running commentary is a pane to the side, contributing further
panes as it works. There is no scrolling viewport that contains "the
document you are reading." There are paragraphs, on a workspace, in a
particular configuration that you and the agent and the corpus have
arrived at together.

This is borrowed, openly, from the Smalltalk class browser tradition —
the idea that a workspace should let you *gather* the units you are
currently working with, rather than navigate to them one at a time inside
a single viewport. A book in Sheaf is not a scroll to march through; it
is a source of paragraphs to gather around the question you came with.
The book's outline is available; its full sequence is preserved; but the
unit you act on is the paragraph, and you act on as many of them, in as
many configurations, as the work requires.

The workspace state — which panes are open, in which arrangement, on
which paragraphs — is reflected in the URL. A configuration of panes is
shareable, bookmarkable, and survives the browser's back button as a real
move in the user's session. You can hand someone a link that opens the
exact arrangement of paragraphs you were thinking with this morning.

## Reading paragraph by paragraph

Reading in Sheaf is paragraphic by default. You receive a paragraph; you
sit with it; you decide what to do with it; you move to the next when you
are ready. The paragraph is the commitment, the next paragraph is a
deliberate choice, and the workspace itself records what you have already
engaged with.

This is offered as an alternative to the dominant model of reading-by-
scrolling, which inherits the page from the codex without asking whether
the page is still the right unit. The page is not the unit of cognition.
The paragraph is. A reading interface that respects the paragraph as a
unit gives the reader something to land on, something to dispatch,
something to fork or keep — instead of a continuous textured surface
that the eye is constantly being pulled across before the mind has caught
up.

This is also a practical accommodation for readers whose attention works
in discrete chunks rather than in continuous flow. Sheaf does not
pathologize that mode of reading. It treats it as the *default*, and
trusts that readers who prefer to read continuously will be just as well
served, since gathering paragraphs into a continuous field is what
Sheaf's reader does anyway.

## Working with the corpus

Sheaf imports documents — papers, books, drafts, transcripts, spreadsheets,
notes — and breaks each one into addressable paragraphs while preserving
its outline, its source, and the relations between its parts. Imports
carry their provenance: where the file came from, when it arrived, what
metadata the resolver found, what the importer made of it.

Underneath the paragraphs is an RDF graph store called Quadlog, in which
every paragraph, document, citation, note, revision, agent action, and
import is a resource with relations to the others. Sheaf uses RDF because
scholarship already depends on identity, provenance, relation, and
source — all of which RDF was designed for. The schema is small and
documented; the IRI structure is stable; the data is exportable and
queryable from outside Sheaf if you ever need to take it with you.

Search runs across the corpus by exact match and by semantic embedding.
A search is itself a paragraphic object — it can be opened as a pane,
saved, named, cited, returned to. A query result is not a transient hit
list that disappears when you navigate away; it is a workspace member
that persists if you want it to.

## The companion

Sheaf includes an assistant. The assistant's role is not to *answer your
questions about the corpus*. The assistant's role is to *work alongside
you in the corpus*, populating your workspace with the paragraphs and
notes and figures it finds useful, while you do the same.

The assistant's primary affordance is not the production of responses.
It is the production of small workspace effects, one at a time, each a
discrete tool call. The assistant opens a paragraph as a pane. The
assistant pins a quote with a note. The assistant drafts a paragraph in
a research-note pane. The assistant adds a citation between two existing
paragraphs. The assistant marks something for follow-up. Each of these
is a *move* — a small, addressable, attributable act that lands on the
shared workspace.

This is paragraphic temporality at the agent's grain. The assistant does
not produce a wall of streamed prose for you to surf. It acts, then
yields, then acts again, with the gaps between acts being the places
where you can steer, intervene, redirect, or simply read what just
arrived. The assistant is a coroutine, not a commission. You are never
out of grip.

The conversational stream the assistant produces internally — its
reasoning, its drafts of phrasings, its half-formed plans — is its
working memory, not its output. The output is what it does. The
distinction matters: it means the assistant's "thinking" can flow freely
without crowding the workspace, and the workspace remains a place of
finished moves rather than a transcript of in-flight cognition.

The same applies to *you*. When you write a paragraph, you write a
paragraph, you commit it. When you pin a quote, you pin a quote, you
commit it. The workspace records the moves. *Both pairs of hands make
the same kinds of moves on the same workspace.* The workspace does not
care which of you acted; it records what happened, with full provenance,
and the figure that emerges is jointly yours.

This is the second commitment Sheaf makes. The agent is not a helper,
a tool, or a generator. The agent is *another pair of hands in the
relay*, with its own perceptions and its own moves, contributing to a
figure that neither party authored alone.

## Provenance as permission

It is tempting to read provenance as an epistemic policing layer — a
way of certifying claims, auditing AI contamination, proving who said
what. Sheaf rejects that framing. The provenance machinery in Sheaf
is not for *catching*; it is for *permitting*. It exists so that the
workspace can be generous about what it accepts, because the metadata
underneath is honest about how each thing arrived.

The analogy is to RDF*. Plain RDF treats every triple as an assertion
in the global truth arena, which makes any real corpus intolerable —
real corpora are full of provisional quotes, contested attributions,
half-paraphrases, sentences-someone-else-said-that-you-want-to-think-
about-but-not-endorse. The traditional response is to be prudish about
what enters the graph, which strangles the practice. RDF* flips this:
*put anything in, but on a layer that names its provenance, so the
bare assertion never has to be made.* The graph becomes generous
because the metadata is honest.

Sheaf does the same move at the paragraph layer. Every paragraph
carries a status as inherent metadata — *imported*, *quoted*,
*paraphrased*, *agent-drafted*, *exploratory*, *pending review*,
*endorsed*. None of these statuses are scribbled in margins or
encoded in TODO comments; they are part of what the paragraph *is*.
A paragraph drafted by the assistant on Tuesday in an exploratory
mode is *visibly* an agent-drafted exploratory paragraph. A paragraph
quoted from a source is *visibly* a quotation, with the source
addressable next to it. A paragraph the writer has read, revised,
and chosen to keep is *visibly* endorsed.

The point of this is to relieve a particular kind of suffering that
many writers know well. Producing academic prose is often miserable
because every sentence feels like a *commitment* — to the claim, to
its phrasing, to its place in the argument. The cost of writing a
sentence is heavy because the sentence is silently asserted on the
ground floor of the writer's authorial voice the moment it appears in
the document. Most working writers develop an *internal* trick to
manage this — *yeah yeah, it's a bunch of text, I can change it
later, whatever* — but they have to do that work themselves, against
the grain of a medium that wants every sentence to be assertion.
Sheaf does that work for them. The exploratory paragraph is *known*
to be exploratory. The writer doesn't have to gaslight themselves
into not committing; the medium knows it's a draft.

This also reframes the AI question. The complaint about students
cheating with AI is structurally the same complaint as RDF without
quoted triples: *something entered the document and now it's just a
fact, with no marker of origin*. The pathology is partly downstream
of the medium's prudishness about provenance. The harder, quieter
version of the same problem is what working academics are going
through right now: they don't *want* to submit something the AI
wrote for them and that they haven't really controlled or curated,
but they have eighty-three pages in a Google Doc and they're scrolling
through it trying to remember which paragraphs they actually believe.
The Doc cannot help them. It treats every sentence the same. *Sheaf
can.* A workspace that distinguishes the agent-drafted from the
endorsed, the quoted from the paraphrased, the exploratory from the
committed, makes the curation legible — and the writer can do their
actual job, which is *deciding* what they mean, rather than
remembering it from scrolling.

The cooperative authorship that Sheaf supports is downstream of this.
The thesis is not "Ieva's thesis with help from an AI." The thesis
is the figure that emerged from the relay, with every paragraph
honestly stamped by who passed it, and the writer free to compose,
revise, and endorse without the medium silently promoting every
fragment to assertion the moment it lands. *Liberal intake at the
content level is enabled by strict honesty at the metadata level.*
That is the point of the provenance machinery, and that is why
Sheaf is built around it.

## Joinery, all the way down

The visible structure of Sheaf — the workspace, the panes, the seams
between them, the typography, the small percussive vocabulary of names
the system uses for itself — is built in a register that the project
calls *Baltic Birch*, after the sheet stock favored by a particular
tradition of small-shop cabinetmaking.

The relevant properties of the material are also the properties of the
interface. Standardized substrate. Visible plies. Eased outer edges,
crisp inner ones. Real joinery between members rather than butt seams
glued with shadow. A small enumerated vocabulary of joints, finishes,
and scales. Type set to do edge work. Frames thick enough to hold what
they contain. Names short enough to fit on a whiteboard and dense enough
to do real work in conversation.

Baltic Birch is described in detail in its own document inside Sheaf.
It is not a skin or a theme. It is the design position the system
inhabits, applied at every scale from the typography of a paragraph to
the architecture of the request-response cycle. The position holds that
craft is enabled by substrate constraints, that visible construction is
honest construction, and that the user reaches for surfaces that grip.

A finger joint is a frozen string figure where two pieces of wood pass
over and under each other in alternating crossings. The dovetail is a
more elaborate figure. *Joinery is string figures in wood.* The block
ID is a string figure in prose. Sheaf is a system of nested string
figures, from the joints between panes down to the citations between
paragraphs, with the user's hands passing loops at every scale.

## A small lineage

Sheaf is a recovery rather than an invention. Almost every move it
makes has been made before, by people working in adjacent media:

- the Smalltalk class browser, for the workspace as a tilable field of
  small browsers parked on addressable units;
- the Pattern Language tradition, for thick boundaries, levels of scale,
  and joinery as ornament;
- David Pye's *Nature and Art of Workmanship*, for the distinction
  between the workmanship of risk and the workmanship of certainty;
- Tim Ingold's *Perception of the Environment*, for the figure of making
  as correspondence with materials in a field of forces;
- Donna Haraway's *Staying with the Trouble*, for the string figure as
  the unit of cooperative cognition;
- the Knuth–Plass paragraph layout algorithm and Bernardy's pretty-
  printing work, for the principle that the producer pays the global-
  optimization surcharge so the consumer can parse for free;
- the Forth and Lisp traditions, for short percussive names from a
  bounded vocabulary;
- the MakerDAO core protocol, for the demonstration that short atomic
  names ship real systems while long Latinate names do not;
- Roy Fielding's REST dissertation, for the constraints — addressability,
  statelessness, uniform interface — that make the web's tooling
  legible across decades;
- the long tradition of cabinetmaking from Nakashima and Krenov back
  through the Greene brothers and the Arts and Crafts movement, for the
  attitude that joints are the truth of the construction and should be
  shown.

Sheaf claims its place in this lineage explicitly. It is not a knowledge
management tool, not a research assistant, not an AI writing app. It is
a craft environment for sympoietic scholarship, with the explicit
ambition of letting careful practices be denser, faster, and more
reliable without being any less careful.

## A swapshop for paragraphs

Sheaf was built to support a master's thesis on a brīvbode — a Latvian
swapshop where things are received, sorted, repaired, recirculated, or
discarded by volunteers, without monetary exchange, twice a week,
year-round. The thesis describes how that circulation is organized and
sustained, and what work it asks of the people who keep it running.

The metaphor turned out to be more than convenient. Sheaf does similar
work for scholarly material. Papers and notes come in. Paragraphs are
separated, named, examined, compared, sorted, kept, set aside, revived,
cited, recombined. Useful fragments move into new writing without losing
where they came from. The room is held together by people and
machines doing small, patient work, and the figure that emerges is no
one party's authored object.

*Keep things moving. Hold them together.* That is a good description of
a swapshop, a bibliography, a thesis draft, a research workspace, and a
string figure mid-relay.

The form and the content rhyme. The thesis is about a sympoietic
practice, written in a sympoietic environment, using a sympoietic tool,
in collaboration with a sympoietic companion. The architecture of the
tool enacts the thing the thesis is about. We treat that as a
correctness signal — when the tool, the practice, and the subject share
a structure, the building tends to go well, because every day at the
bench is also a day spent inside the answer.

## What this thing is, finally

Sheaf is a workshop for cooperative figure-making, in which paragraphs
are first-class objects, citations are string figures, and the agent is
another pair of hands. It is built in the Baltic Birch register, on a
substrate of stable identifiers and provenance-aware RDF, with a
workspace shaped by the editor and Smalltalk-browser traditions of
panes-as-units. It is run as a personal tool, a research prototype, a
design argument, and a quiet bet that the right tools for scholarly work
in the AI era are not the ones currently being built by anyone making a
serious amount of noise about it.

It is also, frankly, a beautiful place to spend an afternoon writing.
That part is not in the manifesto, but it is the part that matters.

---

*Something in this slippery world that can hold.*

Cabinetry, all the way down.
