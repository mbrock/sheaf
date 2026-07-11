import { DataFactory, Store, Writer } from "n3"
import type { NamedNode, Quad, Term } from "@rdfjs/types"
import { BIBO, CITO, DCTERMS, FABIO, FOAF, RDF, RDFS, SHEAF } from "./ns.ts"
import { SheafClient } from "./client.ts"

const { namedNode } = DataFactory

export type SheafDocument = {
  iri: string
  id: string
  kind: string
  title: string
  year?: string
  authors: string[]
  status?: string
  pageCount?: number
  citationCount: number
}

export type OutlineEntry = {
  iri: string
  id: string
  number: number[]
  title: string
  children: OutlineEntry[]
}

export type Block = {
  iri: string
  id: string
  type: string
  title?: string
  text?: string
  children: string[]
}

const documentTypeObjects = [
  SHEAF.Document,
  SHEAF.Thesis,
  SHEAF.Paper,
  SHEAF.Transcript,
  SHEAF.Spreadsheet,
]

export async function loadDocumentIndex(client: SheafClient) {
  // The metadata graph is the document index graph: it contains document type
  // facts, document-to-expression links, bibliographic metadata, creators,
  // statuses, and labels without loading document block content graphs.
  const { store, count } = await client.loadGraph(SHEAF.metadataGraph)
  await debugStoreAsTurtle(store)
  return { store, count, documents: documentsFromStore(client, store) }
}

export async function loadDocumentOutline(
  client: SheafClient,
  idOrIri: string,
) {
  // Document content lives in the named graph whose IRI is the document IRI.
  // Loading that graph gives us the blocks and RDF lists needed for the outline.
  const iri = client.iri(idOrIri)
  const { store, count } = await client.loadGraph(iri)
  return { store, count, outline: outlineFromStore(client, store, iri) }
}

export function documentsFromStore(
  client: SheafClient,
  store: Store,
): SheafDocument[] {
  // RDF describes facts, not rows. This function chooses how to collapse facts
  // spread across a document resource, its bibliographic expression, and author
  // resources into one row that is useful to display.
  const docs = documentSubjects(store)

  return docs
    .map((doc) => {
      const expression = objectIri(store, doc, FABIO.isRepresentationOf)
      const title =
        literal(store, doc, RDFS.label) ||
        (expression && literal(store, expression, DCTERMS.title)) ||
        client.id(doc)
      const kindIri = documentKindIri(store, doc)
      const statusNode = expression
        ? objectIri(store, expression, BIBO.status)
        : undefined
      const status = statusNode ? label(store, statusNode) : undefined
      const pageCount =
        integer(store, doc, BIBO.numPages) ||
        (expression ? integer(store, expression, BIBO.numPages) : undefined)
      const authors = expression
        ? objects(store, expression, DCTERMS.creator).flatMap(
            (author) => label(store, author) || [],
          )
        : []

      return {
        iri: doc.value,
        id: client.id(doc),
        kind: kindLabel(kindIri),
        title,
        year: expression
          ? literal(store, expression, FABIO.hasPublicationYear)
          : undefined,
        authors,
        status,
        pageCount,
        citationCount: objects(store, doc, CITO.cites).length,
      }
    })
    .sort((a, b) => documentSortKey(a).localeCompare(documentSortKey(b)))
}

export function outlineFromStore(
  client: SheafClient,
  store: Store,
  rootIri: string,
): OutlineEntry[] {
  // sheaf:children points at an RDF list head. listObjects() turns that linked
  // list into ordered child nodes, then we keep only section blocks for the
  // outline tree.
  const root = namedNode(rootIri)
  return listObjects(store, object(store, root, SHEAF.children))
    .filter((child) => has(store, child, RDF.type, SHEAF.Section))
    .flatMap((child, index) =>
      outlineEntry(client, store, child, [index + 1]),
    )
}

export function blockFromStore(
  client: SheafClient,
  store: Store,
  iri: string | Term,
): Block | undefined {
  // A block's readable text may be attached directly to the block, or for
  // paragraph blocks via a sheaf:paragraph node. This hides that RDF shape from
  // callers of the block preview projection.
  const node = typeof iri === "string" ? namedNode(iri) : iri
  const type = blockType(store, node)
  if (!type) return undefined

  const paragraph = object(store, node, SHEAF.paragraph)
  return {
    iri: node.value,
    id: client.id(node),
    type,
    title: literal(store, node, RDFS.label),
    text:
      type === "paragraph" && paragraph
        ? literal(store, paragraph, SHEAF.text)
        : literal(store, node, SHEAF.text) ||
          literal(store, node, SHEAF.sourceHtml),
    children: listObjects(store, object(store, node, SHEAF.children)).map(
      (child) => child.value,
    ),
  }
}

function outlineEntry(
  client: SheafClient,
  store: Store,
  node: Term,
  number: number[],
): OutlineEntry[] {
  if (!has(store, node, RDF.type, SHEAF.Section)) return []

  const children = listObjects(store, object(store, node, SHEAF.children))
    .filter((child) => has(store, child, RDF.type, SHEAF.Section))
    .flatMap((child, index) =>
      outlineEntry(client, store, child, [...number, index + 1]),
    )

  return [
    {
      iri: node.value,
      id: client.id(node),
      number,
      title: literal(store, node, RDFS.label) || client.id(node),
      children,
    },
  ]
}

function listObjects(store: Store, head?: Term): Term[] {
  // RDF lists are linked lists:
  //   head --rdf:first--> value
  //   head --rdf:rest--> nextCell
  // This converts that representation to a normal ordered array of values.
  if (!head || head.value === RDF.nil) return []
  const values: Term[] = []
  const seen = new Set<string>()
  let cursor: Term | undefined = head

  while (cursor && cursor.value !== RDF.nil && !seen.has(cursor.value)) {
    seen.add(cursor.value)
    const first = object(store, cursor, RDF.first)
    if (first) values.push(first)
    cursor = object(store, cursor, RDF.rest)
  }

  return values
}

function documentKindIri(store: Store, doc: Term) {
  for (const kind of [
    SHEAF.Thesis,
    SHEAF.Paper,
    SHEAF.Transcript,
    SHEAF.Spreadsheet,
    SHEAF.Document,
  ]) {
    if (has(store, doc, RDF.type, kind)) return kind
  }
  return SHEAF.Document
}

function blockType(store: Store, block: Term) {
  if (has(store, block, RDF.type, SHEAF.Section)) return "section"
  if (has(store, block, RDF.type, SHEAF.ParagraphBlock)) return "paragraph"
  if (has(store, block, RDF.type, SHEAF.ExtractedBlock)) return "extracted"
  if (has(store, block, RDF.type, SHEAF.Row)) return "row"
  return undefined
}

function kindLabel(iri: string) {
  if (iri === SHEAF.Thesis) return "thesis"
  if (iri === SHEAF.Paper) return "paper"
  if (iri === SHEAF.Transcript) return "transcript"
  if (iri === SHEAF.Spreadsheet) return "spreadsheet"
  return "document"
}

function documentSortKey(document: SheafDocument) {
  const order =
    { thesis: 0, paper: 1, document: 2, transcript: 3, spreadsheet: 4 }[
      document.kind
    ] ?? 9
  return `${order}\u0000${document.title.toLowerCase()}`
}

function label(store: Store, node: Term) {
  if (node.termType === "Literal") return node.value
  return (
    literal(store, node, FOAF.name) ||
    literal(store, node, RDFS.label) ||
    localName(node)
  )
}

function localName(value?: string | Term) {
  if (!value) return undefined
  const raw = typeof value === "string" ? value : value.value
  return decodeURIComponent(raw.split(/[\/#]/).filter(Boolean).at(-1) || raw)
}

function has(store: Store, subject: Term, predicate: string, object: string) {
  return (
    store.countQuads(
      subject as any,
      namedNode(predicate),
      namedNode(object),
      null,
    ) > 0
  )
}

function subjects(store: Store, predicate: string, object: string) {
  return store.getSubjects(
    namedNode(predicate),
    namedNode(object),
    null,
  ) as NamedNode[]
}

function documentSubjects(store: Store) {
  return uniqueTerms(
    documentTypeObjects.flatMap((type) => subjects(store, RDF.type, type)),
  ) as NamedNode[]
}

function objects(store: Store, subject: Term, predicate: string) {
  return store.getObjects(subject as any, namedNode(predicate), null)
}

function object(store: Store, subject: Term, predicate: string) {
  return objects(store, subject, predicate)[0]
}

function objectIri(store: Store, subject: Term, predicate: string) {
  const value = object(store, subject, predicate)
  return value?.termType === "NamedNode" ? value : undefined
}

function literal(store: Store, subject: Term, predicate: string) {
  return object(store, subject, predicate)?.value
}

function integer(store: Store, subject: Term, predicate: string) {
  const value = literal(store, subject, predicate)
  if (!value) return undefined
  const number = Number.parseInt(value, 10)
  return Number.isFinite(number) ? number : undefined
}

function uniqueTerms<T extends Term>(terms: T[]) {
  const seen = new Set<string>()
  const result: T[] = []

  for (const term of terms) {
    const key = termSortKey(term)
    if (seen.has(key)) continue
    seen.add(key)
    result.push(term)
  }

  return result
}

async function debugStoreAsTurtle(store: Store) {
  if (!debugTurtleEnabled()) return
  console.error(await storeAsTurtle(store))
}

function debugTurtleEnabled() {
  const value = Bun.env.SHEAF_CLIENT_DEBUG_TURTLE
  return Boolean(value && !["0", "false", "no"].includes(value.toLowerCase()))
}

export function storeAsTurtle(store: Store) {
  const writer = new Writer({
    format: "Turtle",
    prefixes: {
      "": SHEAF.resourceBase,
      bibo: namespaceIri(BIBO.numPages),
      cito: namespaceIri(CITO.cites),
      dcterms: namespaceIri(DCTERMS.title),
      fabio: namespaceIri(FABIO.ScholarlyWork),
      foaf: namespaceIri(FOAF.name),
      rdf: namespaceIri(RDF.type),
      rdfs: namespaceIri(RDFS.label),
      sheaf: SHEAF.base,
    },
  })
  writer.addQuads(turtleDebugQuads(store))

  return new Promise<string>((resolve, reject) => {
    writer.end((error, result) => {
      if (error) reject(error)
      else resolve(result)
    })
  })
}

function namespaceIri(iri: string) {
  return iri.replace(/[#/][^#/]*$/, (separator) => separator[0]!)
}

function turtleDebugQuads(store: Store) {
  const seen = new Set<string>()
  const quads: Quad[] = []

  for (const quad of store.getQuads(null, null, null, null) as Quad[]) {
    const triple = DataFactory.quad(quad.subject, quad.predicate, quad.object)
    const key = [
      termSortKey(triple.subject),
      termSortKey(triple.predicate),
      termSortKey(triple.object),
    ].join("\u0000")

    if (seen.has(key)) continue
    seen.add(key)
    quads.push(triple)
  }

  return quads.sort(compareQuads)
}

function compareQuads(a: Quad, b: Quad) {
  return (
    compareTerms(a.subject, b.subject) ||
    compareTerms(a.predicate, b.predicate) ||
    compareTerms(a.object, b.object)
  )
}

function compareTerms(a: Term, b: Term) {
  return termSortKey(a).localeCompare(termSortKey(b))
}

function termSortKey(term: Term) {
  return `${term.termType}\u0000${term.value}`
}
