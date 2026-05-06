import { DataFactory, Store } from "n3"
import type { NamedNode, Quad, Term } from "@rdfjs/types"
import { BIBO, CITO, DCTERMS, FABIO, FOAF, RDF, RDFS, SHEAF } from "./ns.ts"
import { SheafClient, type QuadPattern } from "./client.ts"

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

const documentTypeObjects = [SHEAF.Document, SHEAF.Thesis, SHEAF.Paper, SHEAF.Transcript, SHEAF.Spreadsheet]

const indexPatterns: QuadPattern[] = [
  ...documentTypeObjects.map((object) => ({ predicate: RDF.type, object })),
  { predicate: RDFS.label },
  { predicate: BIBO.numPages },
  { predicate: FABIO.isRepresentationOf },
  { predicate: DCTERMS.title },
  { predicate: DCTERMS.creator },
  { predicate: FABIO.hasPublicationYear },
  { predicate: FABIO.hasPageRange },
  { predicate: BIBO.status },
  { predicate: FOAF.name },
]

export async function loadDocumentIndex(client: SheafClient) {
  const { store, count } = await client.loadStore(indexPatterns)
  return { store, count, documents: documentsFromStore(client, store) }
}

export async function loadDocumentOutline(client: SheafClient, idOrIri: string) {
  const iri = client.iri(idOrIri)
  const { store, count } = await client.loadGraph(iri)
  return { store, count, outline: outlineFromStore(client, store, iri) }
}

export function documentsFromStore(client: SheafClient, store: Store): SheafDocument[] {
  const docs = subjects(store, RDF.type, SHEAF.Document)

  return docs
    .map((doc) => {
      const expression = objectIri(store, doc, FABIO.isRepresentationOf)
      const title = literal(store, doc, RDFS.label) || (expression && literal(store, expression, DCTERMS.title)) || client.id(doc)
      const kindIri = documentKindIri(store, doc)
      const statusNode = expression ? objectIri(store, expression, BIBO.status) : undefined
      const status = statusNode ? label(store, statusNode) : undefined
      const pageCount = integer(store, doc, BIBO.numPages) || (expression ? integer(store, expression, BIBO.numPages) : undefined)
      const authors = expression ? objects(store, expression, DCTERMS.creator).flatMap((author) => label(store, author) || []) : []

      return {
        iri: doc.value,
        id: client.id(doc),
        kind: kindLabel(kindIri),
        title,
        year: expression ? literal(store, expression, FABIO.hasPublicationYear) : undefined,
        authors,
        status,
        pageCount,
        citationCount: objects(store, doc, CITO.cites).length,
      }
    })
    .sort((a, b) => documentSortKey(a).localeCompare(documentSortKey(b)))
}

export function outlineFromStore(client: SheafClient, store: Store, rootIri: string): OutlineEntry[] {
  const root = namedNode(rootIri)
  return listObjects(store, object(store, root, SHEAF.children))
    .filter((child) => has(store, child, RDF.type, SHEAF.Section))
    .flatMap((child, index) => outlineEntry(client, store, child, [index + 1]))
}

export function blockFromStore(client: SheafClient, store: Store, iri: string | Term): Block | undefined {
  const node = typeof iri === "string" ? namedNode(iri) : iri
  const type = blockType(store, node)
  if (!type) return undefined

  const paragraph = object(store, node, SHEAF.paragraph)
  return {
    iri: node.value,
    id: client.id(node),
    type,
    title: literal(store, node, RDFS.label),
    text: type === "paragraph" && paragraph ? literal(store, paragraph, SHEAF.text) : literal(store, node, SHEAF.text) || literal(store, node, SHEAF.sourceHtml),
    children: listObjects(store, object(store, node, SHEAF.children)).map((child) => child.value),
  }
}

function outlineEntry(client: SheafClient, store: Store, node: Term, number: number[]): OutlineEntry[] {
  if (!has(store, node, RDF.type, SHEAF.Section)) return []

  const children = listObjects(store, object(store, node, SHEAF.children))
    .filter((child) => has(store, child, RDF.type, SHEAF.Section))
    .flatMap((child, index) => outlineEntry(client, store, child, [...number, index + 1]))

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
  for (const kind of [SHEAF.Thesis, SHEAF.Paper, SHEAF.Transcript, SHEAF.Spreadsheet, SHEAF.Document]) {
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
  const order = { thesis: 0, paper: 1, document: 2, transcript: 3, spreadsheet: 4 }[document.kind] ?? 9
  return `${order}\u0000${document.title.toLowerCase()}`
}

function label(store: Store, node: Term) {
  if (node.termType === "Literal") return node.value
  return literal(store, node, FOAF.name) || literal(store, node, RDFS.label) || localName(node)
}

function localName(value?: string | Term) {
  if (!value) return undefined
  const raw = typeof value === "string" ? value : value.value
  return decodeURIComponent(raw.split(/[\/#]/).filter(Boolean).at(-1) || raw)
}

function has(store: Store, subject: Term, predicate: string, object: string) {
  return store.countQuads(subject as any, namedNode(predicate), namedNode(object), null) > 0
}

function subjects(store: Store, predicate: string, object: string) {
  return store.getSubjects(namedNode(predicate), namedNode(object), null) as NamedNode[]
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
