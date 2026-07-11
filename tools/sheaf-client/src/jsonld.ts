import jsonld from "jsonld"
import type { ContextDefinition, JsonLdDocument } from "jsonld"
import { SheafClient, type QuadPattern } from "./client.ts"

export async function jsonldForPattern(
  client: SheafClient,
  pattern: QuadPattern = {},
) {
  // JSON-LD is not a different data model here; it is another serialization of
  // the same RDF quads. fromRDF() converts the N-Quads response into expanded
  // JSON-LD, where predicates are still full IRIs and references are still RDF
  // node identifiers.
  const nquads = await client.nquads(pattern)
  return jsonld.fromRDF(nquads, {
    format: "application/n-quads",
  }) as Promise<JsonLdDocument>
}

export async function compactJsonldForPattern(
  client: SheafClient,
  pattern: QuadPattern = {},
  context?: ContextDefinition,
) {
  // Compaction applies a @context: long predicate IRIs become keys like
  // "title" and "children", and selected values are known to be ids or typed
  // literals. It does not define command-specific projection shapes such as a
  // document summary or outline; projections.ts does that.
  const document = await jsonldForPattern(client, pattern)
  return jsonld.compact(document, context || (await sheafContext()))
}

export async function compactResourceJsonld(
  client: SheafClient,
  idOrIri: string,
) {
  return compactJsonldForPattern(client, { subject: client.iri(idOrIri) })
}

export async function compactGraphJsonld(
  client: SheafClient,
  idOrIri: string,
) {
  return compactJsonldForPattern(client, { graph: client.iri(idOrIri) })
}

export async function compactGraphTreeJsonld(
  client: SheafClient,
  idOrIri: string,
) {
  return compactGraphJsonld(client, idOrIri)
}

export async function frameGraphJsonld(
  client: SheafClient,
  idOrIri: string,
  frameName = "document.frame.jsonld",
) {
  // Framing is JSON-LD's way of asking for a tree-shaped view rooted at a
  // particular node. It can embed related nodes, but it is still constrained by
  // RDF identity and by the frame file; it is not a general UI projection.
  const iri = client.iri(idOrIri)
  const document = await jsonldForPattern(client, { graph: iri })
  const frame = await jsonldFrame(frameName, { id: iri })
  return jsonld.frame(document, frame)
}

export async function sheafContext() {
  const document = await jsonldAsset("sheaf.context.jsonld")
  return (document as { "@context": ContextDefinition })["@context"]
}

export async function jsonldFrame(
  name: string,
  overrides: Record<string, unknown> = {},
) {
  return inlineContext({ ...(await jsonldAsset(name)), ...overrides })
}

async function inlineContext<T>(document: T): Promise<T> {
  if (
    document &&
    typeof document === "object" &&
    "@context" in document &&
    (document as Record<string, unknown>)["@context"] ===
      "sheaf.context.jsonld"
  ) {
    return { ...document, "@context": await sheafContext() }
  }
  return document
}

async function jsonldAsset(name: string) {
  const path = new URL(`../jsonld/${name}`, import.meta.url)
  try {
    return await Bun.file(path).json()
  } catch (error) {
    throw new Error(
      `failed to load JSON-LD asset ${path.pathname}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    )
  }
}
