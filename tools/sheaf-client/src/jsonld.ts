import jsonld from "jsonld"
import type { ContextDefinition, JsonLdDocument } from "jsonld"
import { BIBO, CITO, DCTERMS, FABIO, FOAF, RDF, RDFS, SHEAF } from "./ns.ts"
import { SheafClient, type QuadPattern } from "./client.ts"

export const builtinContext = {
  as: "https://www.w3.org/ns/activitystreams#",
  bibo: "http://purl.org/ontology/bibo/",
  biro: "http://purl.org/spar/biro/",
  cito: "http://purl.org/spar/cito/",
  dcterms: "http://purl.org/dc/terms/",
  fabio: "http://purl.org/spar/fabio/",
  foaf: "http://xmlns.com/foaf/0.1/",
  rdf: "http://www.w3.org/1999/02/22-rdf-syntax-ns#",
  rdfs: "http://www.w3.org/2000/01/rdf-schema#",
  sheaf: SHEAF.base,
  xsd: "http://www.w3.org/2001/XMLSchema#",
  id: "@id",
  type: "@type",
  label: RDFS.label,
  first: { "@id": RDF.first, "@type": "@id" },
  rest: { "@id": RDF.rest, "@type": "@id" },
  children: { "@id": SHEAF.children, "@type": "@id" },
  paragraph: { "@id": SHEAF.paragraph, "@type": "@id" },
  text: SHEAF.text,
  sourceHtml: SHEAF.sourceHtml,
  sourceKey: SHEAF.sourceKey,
  sourcePage: SHEAF.sourcePage,
  cites: { "@id": CITO.cites, "@type": "@id" },
  title: DCTERMS.title,
  creator: { "@id": DCTERMS.creator, "@type": "@id" },
  name: FOAF.name,
  pageCount: { "@id": BIBO.numPages, "@type": "xsd:integer" },
  status: { "@id": BIBO.status, "@type": "@id" },
  publicationYear: FABIO.hasPublicationYear,
  representationOf: { "@id": FABIO.isRepresentationOf, "@type": "@id" },
  volume: FABIO.hasVolumeIdentifier,
  issue: FABIO.hasIssueIdentifier,
  pages: FABIO.hasPageRange,
}

export async function jsonldForPattern(client: SheafClient, pattern: QuadPattern = {}) {
  const nquads = await client.nquads(pattern)
  return jsonld.fromRDF(nquads, { format: "application/n-quads" }) as Promise<JsonLdDocument>
}

export async function compactJsonldForPattern(client: SheafClient, pattern: QuadPattern = {}, context?: ContextDefinition) {
  const document = await jsonldForPattern(client, pattern)
  return jsonld.compact(document, context || (await sheafContext()))
}

export async function compactResourceJsonld(client: SheafClient, idOrIri: string) {
  return compactJsonldForPattern(client, { subject: client.iri(idOrIri) })
}

export async function compactGraphJsonld(client: SheafClient, idOrIri: string) {
  return compactJsonldForPattern(client, { graph: client.iri(idOrIri) })
}

export async function compactGraphTreeJsonld(client: SheafClient, idOrIri: string) {
  return materializeNamedLists(await compactGraphJsonld(client, idOrIri))
}

export async function frameGraphJsonld(client: SheafClient, idOrIri: string, frameName = "document.frame.jsonld") {
  const iri = client.iri(idOrIri)
  const document = await jsonldForPattern(client, { graph: iri })
  const frame = await jsonldFrame(frameName, { id: iri })
  return jsonld.frame(document, frame)
}

export function materializeNamedLists<T>(document: T): T {
  const root = structuredClone(document) as Json
  const nodes = new Map<string, JsonObject>()
  collectNodes(root, nodes)

  const listIds = new Set([...nodes].filter(([_id, node]) => isListNode(node)).map(([id]) => id))
  replaceListRefs(root, nodes, listIds)
  pruneListNodes(root, listIds)
  return root as T
}

export async function sheafContext() {
  const document = await jsonldAsset("sheaf.context.jsonld")
  return (document as { "@context": ContextDefinition })["@context"]
}

export async function jsonldFrame(name: string, overrides: Record<string, unknown> = {}) {
  return inlineContext({ ...(await jsonldAsset(name)), ...overrides })
}

async function inlineContext<T>(document: T): Promise<T> {
  if (document && typeof document === "object" && "@context" in document && (document as Record<string, unknown>)["@context"] === "sheaf.context.jsonld") {
    return { ...document, "@context": await sheafContext() }
  }
  return document
}

async function jsonldAsset(name: string) {
  const path = new URL(`../../../priv/jsonld/${name}`, import.meta.url)
  try {
    return await Bun.file(path).json()
  } catch (error) {
    if (name === "sheaf.context.jsonld") return { "@context": builtinContext }
    throw error
  }
}

type Json = null | boolean | number | string | Json[] | JsonObject
type JsonObject = { [key: string]: Json }

function collectNodes(value: Json, nodes: Map<string, JsonObject>) {
  if (Array.isArray(value)) {
    for (const item of value) collectNodes(item, nodes)
    return
  }

  if (!isObject(value)) return

  const id = jsonldId(value)
  if (id) nodes.set(id, value)

  for (const child of Object.values(value)) collectNodes(child, nodes)
}

function replaceListRefs(value: Json, nodes: Map<string, JsonObject>, listIds: Set<string>): Json {
  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) value[i] = replaceListRefs(value[i]!, nodes, listIds)
    return value
  }

  if (!isObject(value)) return value

  for (const [key, child] of Object.entries(value)) {
    if (key === "id" || key === "@id") continue
    value[key] = replaceValue(child, nodes, listIds)
  }

  return value
}

function replaceValue(value: Json, nodes: Map<string, JsonObject>, listIds: Set<string>): Json {
  const id = refId(value)
  if (id && listIds.has(id)) return materializeList(id, nodes, new Set())
  return replaceListRefs(value, nodes, listIds)
}

function materializeList(id: string, nodes: Map<string, JsonObject>, seen: Set<string>): Json[] {
  if (seen.has(id)) return []
  seen.add(id)

  const node = nodes.get(id)
  if (!node) return []

  const first = listFirst(node)
  const rest = listRest(node)
  const values: Json[] = first === undefined ? [] : [first]

  if (rest === undefined) return values
  if (isObject(rest)) {
    const list = rest["@list"]
    if (Array.isArray(list)) return values.concat(list.filter((item): item is Json => item !== undefined))
  }
  if (Array.isArray(rest)) return values.concat(rest)

  const next = refId(rest)
  return next ? values.concat(materializeList(next, nodes, seen)) : values
}

function pruneListNodes(value: Json, listIds: Set<string>) {
  if (Array.isArray(value)) {
    for (let i = value.length - 1; i >= 0; i--) {
      const item = value[i]
      if (item !== undefined && isObject(item) && listIds.has(jsonldId(item) || "")) {
        value.splice(i, 1)
      } else {
        if (item !== undefined) pruneListNodes(item, listIds)
      }
    }
    return
  }

  if (!isObject(value)) return
  for (const child of Object.values(value)) pruneListNodes(child, listIds)
}

function isListNode(value: JsonObject) {
  return listFirst(value) !== undefined || listRest(value) !== undefined
}

function listFirst(value: JsonObject) {
  return value.first ?? value["rdf:first"] ?? value[RDF.first]
}

function listRest(value: JsonObject) {
  return value.rest ?? value["rdf:rest"] ?? value[RDF.rest]
}

function refId(value: Json) {
  if (typeof value === "string") return value
  if (isObject(value)) return jsonldId(value)
  return undefined
}

function jsonldId(value: JsonObject) {
  const id = value.id ?? value["@id"]
  return typeof id === "string" ? id : undefined
}

function isObject(value: Json): value is JsonObject {
  return Boolean(value && typeof value === "object" && !Array.isArray(value))
}
