#!/usr/bin/env bun

import { BIBO, CITO, DCTERMS, FABIO, FOAF, RDF, RDFS, SHEAF } from "./ns.ts"
import { SheafClient, type QuadPattern } from "./client.ts"
import { compactGraphJsonld, compactGraphTreeJsonld, compactResourceJsonld, frameGraphJsonld } from "./jsonld.ts"
import { blockFromStore, loadDocumentIndex, loadDocumentOutline } from "./projections.ts"

const args = parseArgs(Bun.argv.slice(2))
const command = args._[0] || "help"
const client = new SheafClient({ host: arg("host") })

try {
  switch (command) {
    case "count":
      await count()
      break
    case "quads":
      await quads()
      break
    case "resource":
      await resource()
      break
    case "documents":
      await documents()
      break
    case "outline":
      await outline()
      break
    case "jsonld":
      await jsonldCommand()
      break
    case "frame":
      await frameCommand()
      break
    case "tree":
      await treeCommand()
      break
    case "help":
    default:
      help()
      break
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
}

async function count() {
  let n = 0
  for await (const _quad of client.streamQuads(patternArgs())) n++
  console.log(n)
}

async function quads() {
  const limit = numberArg("limit", 40)
  let n = 0
  for await (const quad of client.streamQuads(patternArgs())) {
    console.log(`${term(quad.subject)} ${term(quad.predicate)} ${term(quad.object)} ${term(quad.graph)}`)
    if (++n >= limit) break
  }
}

async function resource() {
  const id = requiredArg(1, "resource id or IRI")
  const { store, count } = await client.loadResource(client.iri(id))
  console.log(`${count} quads for ${client.iri(id)}`)

  for (const predicate of [RDF.type, RDFS.label, DCTERMS.title, FABIO.isRepresentationOf, BIBO.status, CITO.cites]) {
    for (const object of store.getObjects(client.iri(id) as any, predicate as any, null)) {
      console.log(`${compact(predicate)}: ${object.value}`)
    }
  }
}

async function documents() {
  const limit = numberArg("limit", 30)
  const { documents, count } = await loadDocumentIndex(client)
  console.log(`${documents.length} documents from ${count} indexed quads`)
  for (const document of documents.slice(0, limit)) {
    const right = [document.year, document.pageCount ? `${document.pageCount} pp.` : "", document.status].filter(Boolean).join("  ")
    const byline = document.authors.length ? `\n    ${document.authors.join(", ")}` : ""
    console.log(`${document.id}  ${document.kind.padEnd(11)} ${document.title}${right ? `  ${right}` : ""}${byline}`)
  }
}

async function outline() {
  const id = requiredArg(1, "document id or IRI")
  const { store, count, outline } = await loadDocumentOutline(client, id)
  console.log(`${client.iri(id)} outline from ${count} graph quads`)
  printOutline(outline)

  if (arg("block")) {
    const block = blockFromStore(client, store, client.iri(arg("block")!))
    if (block) {
      console.log("")
      console.log(`${block.id}  ${block.type}  ${block.title || ""}`)
      if (block.text) console.log(block.text.replace(/\s+/g, " ").slice(0, 800))
      if (block.children.length) console.log(`children: ${block.children.map((iri) => client.id(iri)).join(" ")}`)
    }
  }
}

async function jsonldCommand() {
  const id = requiredArg(1, "resource id or IRI")
  const mode = arg("mode") || "graph"
  const document = mode === "resource" ? await compactResourceJsonld(client, id) : await compactGraphJsonld(client, id)
  console.log(JSON.stringify(document, null, 2))
}

async function frameCommand() {
  const id = requiredArg(1, "document id or IRI")
  const frame = arg("frame") || "document.frame.jsonld"
  const document = await frameGraphJsonld(client, id, frame)
  console.log(JSON.stringify(document, null, 2))
}

async function treeCommand() {
  const id = requiredArg(1, "document id or IRI")
  const document = await compactGraphTreeJsonld(client, id)
  console.log(JSON.stringify(document, null, 2))
}

function printOutline(entries: Awaited<ReturnType<typeof loadDocumentOutline>>["outline"], depth = 0) {
  for (const entry of entries) {
    console.log(`${"  ".repeat(depth)}${entry.number.join(".")}. ${entry.title}  ${entry.id}`)
    printOutline(entry.children, depth + 1)
  }
}

function patternArgs(): QuadPattern {
  return {
    subject: arg("s") || arg("subject"),
    predicate: expandPredicate(arg("p") || arg("predicate")),
    object: expandObject(arg("o") || arg("object")),
    graph: arg("g") || arg("graph"),
  }
}

function expandPredicate(value?: string) {
  if (!value) return undefined
  return expand(value, {
    type: RDF.type,
    label: RDFS.label,
    children: SHEAF.children,
    text: SHEAF.text,
    creator: DCTERMS.creator,
  })
}

function expandObject(value?: string) {
  if (!value) return undefined
  return expand(value, {
    Document: SHEAF.Document,
    Thesis: SHEAF.Thesis,
    Paper: SHEAF.Paper,
    Section: SHEAF.Section,
    ParagraphBlock: SHEAF.ParagraphBlock,
  })
}

function expand(value: string, names: Record<string, string>) {
  return names[value] || value
}

function compact(value: string) {
  return value
    .replace(SHEAF.base, "sheaf:")
    .replace("http://www.w3.org/1999/02/22-rdf-syntax-ns#", "rdf:")
    .replace("http://www.w3.org/2000/01/rdf-schema#", "rdfs:")
    .replace("http://purl.org/dc/terms/", "dcterms:")
    .replace("http://purl.org/spar/fabio/", "fabio:")
    .replace("http://purl.org/ontology/bibo/", "bibo:")
    .replace("http://purl.org/spar/cito/", "cito:")
    .replace("http://xmlns.com/foaf/0.1/", "foaf:")
}

function term(value: { termType: string; value: string }) {
  return value.termType === "Literal" ? JSON.stringify(value.value) : value.value
}

function requiredArg(index: number, name: string) {
  const value = args._[index]
  if (!value) throw new Error(`missing ${name}`)
  return value
}

function numberArg(name: string, fallback: number) {
  const value = arg(name)
  return value ? Number.parseInt(value, 10) : fallback
}

function parseArgs(argv: string[]) {
  const values = { _: [] as string[] } as Record<string, any> & { _: string[] }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!
    if (!arg.startsWith("--")) {
      values._.push(arg)
      continue
    }
    const key = arg.slice(2)
    const next = argv[i + 1]
    if (next && !next.startsWith("--")) {
      values[key] = next
      i++
    } else {
      values[key] = "true"
    }
  }
  return values
}

function arg(name: string) {
  const value = args[name]
  return typeof value === "string" ? value : undefined
}

function help() {
  console.log(`sheaf-client

Commands:
  count [--s IRI] [--p IRI|alias] [--o IRI|alias] [--g IRI]
  quads [--limit N] [--s IRI] [--p IRI|alias] [--o IRI|alias] [--g IRI]
  resource ID_OR_IRI
  documents [--limit N]
  outline ID_OR_IRI [--block ID_OR_IRI]
  jsonld ID_OR_IRI [--mode graph|resource]
  frame ID_OR_IRI [--frame document.frame.jsonld]
  tree ID_OR_IRI

Aliases:
  predicates: type label children text creator
  objects: Document Thesis Paper Section ParagraphBlock
`)
}
