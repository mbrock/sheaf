# Ontology Labeling Notes

These notes record the label and term-selection style we want for Sheaf's local
schema. They are based on the BFO/OBO style visible in BFO itself and on the
practical ontology-design guidance in Robert Arp, Barry Smith, and Andrew D.
Spear, _Building Ontologies with Basic Formal Ontology_.

## Terms And Identifiers

Ontology labels are human terms, not machine identifiers. IRIs, compact IRIs,
and opaque IDs can be stable machine handles; labels should be ordinary terms a
domain reader can understand.

Use labels for the thing meant by the class or property, not for the spelling of
the code identifier. For example, an IRI ending in `ParagraphBlock` can have the
label `paragraph block`.

## Class Labels

Class labels should normally be singular common nouns or singular noun phrases:

- `document`
- `paragraph`
- `audio blob`
- `research session`
- `material entity`
- `generically dependent continuant`

Use lowercase for common nouns. Initial capitals usually signal proper names or
individuals, so avoid title case for class labels.

Keep capitals for established proper names, standards, protocols, and acronyms:

- `Ogg packet`
- `RTP stream`
- `WebRTC connection`
- `MIME type`
- `SHA-256 digest`

Avoid acronyms in preferred labels unless they are already the established term
used by domain experts. When an acronym is merely a local convenience, prefer
the expanded noun phrase as the label and keep the acronym as an alternate
label or identifier.

## Property Labels

Property labels should read as unambiguous relational expressions or attributes:

- `has part`
- `part of`
- `has source file`
- `has paragraph`
- `has byte size`
- `mentions`

Avoid labels that are only bare plural field names when the property itself is a
relation. For example, `has child list` is clearer than `children` when the
object is an RDF list of children.

Relational labels should be used consistently. Do not use the same relation
label with different meanings in different contexts, and do not use a familiar
relation label such as `part of` for a looser application-specific association.

## Mass Nouns

Avoid mass nouns as class labels when the intended instances are countable
portions or units. Use an ontologically explicit phrase:

- `portion of text`
- `portion of audio`
- `portion of chemical substance`
- `maximal portion of blood`

This is useful when a word like `text`, `audio`, `water`, or `data` could refer
either to a kind of stuff, an arbitrary amount of stuff, a file, a document, or a
particular bounded portion. Pick the countable entity the class actually ranges
over.

## Univocity

Each preferred label should have one meaning in the schema. If several
communities use different names for the same thing, choose one preferred label
and record the others as alternate labels rather than overloading the preferred
term.

If one familiar word has several meanings, split the meanings into distinct
classes or properties with more specific labels.

## Definitions And Comments

Definitions should explain what kind of entity the term denotes. For non-root
classes, prefer an Aristotelian shape: a child class is a kind of its parent
class with a differentiating feature.

Usage notes, import quirks, and UI behavior belong in comments, not in the
definition-like label.
