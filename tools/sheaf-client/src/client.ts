import { Readable } from "stream"
import { DataFactory, Store, StreamParser } from "n3"
import type { Quad, Term } from "@rdfjs/types"

const { namedNode } = DataFactory

export type QuadPattern = {
  subject?: string | Term | Array<string | Term>
  predicate?: string | Term | Array<string | Term>
  object?: string | Term | Array<string | Term>
  graph?: string | Term | Array<string | Term>
}

export type SheafClientOptions = {
  host?: string
  fetch?: typeof fetch
}

export class SheafClient {
  readonly host: string
  readonly fetch: typeof fetch

  constructor(options: SheafClientOptions = {}) {
    this.host = cleanHost(options.host || defaultHost())
    this.fetch = options.fetch || fetch
  }

  iri(idOrIri: string) {
    if (/^https?:\/\//.test(idOrIri)) return idOrIri
    return `https://sheaf.less.rest/${idOrIri.replace(/^\/+/, "")}`
  }

  id(iri: string | Term) {
    const value = typeof iri === "string" ? iri : iri.value
    return value.replace(/^https:\/\/sheaf\.less\.rest\//, "")
  }

  async *streamQuads(pattern: QuadPattern = {}): AsyncIterable<Quad> {
    const endpoint = this.quadsUrl(pattern)
    const response = await this.fetch(endpoint, {
      headers: { accept: "application/n-quads" },
    })

    if (!response.ok) {
      throw new Error(`GET ${endpoint} returned ${response.status} ${response.statusText}`)
    }

    if (!response.body) return

    const parser = new StreamParser({ format: "N-Quads", blankNodePrefix: "" })
    Readable.fromWeb(response.body as any).pipe(parser)

    for await (const quad of parser) {
      yield quad as Quad
    }
  }

  async nquads(pattern: QuadPattern = {}) {
    const endpoint = this.quadsUrl(pattern)
    const response = await this.fetch(endpoint, {
      headers: { accept: "application/n-quads" },
    })

    if (!response.ok) {
      throw new Error(`GET ${endpoint} returned ${response.status} ${response.statusText}`)
    }

    return response.text()
  }

  async loadStore(patterns: QuadPattern | QuadPattern[]) {
    const store = new Store()
    let count = 0
    for (const pattern of Array.isArray(patterns) ? patterns : [patterns]) {
      for await (const quad of this.streamQuads(pattern)) {
        store.addQuad(quad as any)
        count++
      }
    }
    return { store, count }
  }

  async loadGraph(graph: string | Term) {
    return this.loadStore({ graph })
  }

  async loadResource(resource: string | Term) {
    return this.loadStore({ subject: resource })
  }

  quadsUrl(pattern: QuadPattern = {}) {
    const url = new URL("/rdf/quads", this.host)
    addTerms(url, "s", pattern.subject)
    addTerms(url, "p", pattern.predicate)
    addTerms(url, "o", pattern.object)
    addTerms(url, "g", pattern.graph)
    return url.toString()
  }
}

export function term(value: string | Term) {
  return typeof value === "string" ? namedNode(value) : value
}

function addTerms(url: URL, key: string, value?: string | Term | Array<string | Term>) {
  if (value === undefined) return
  for (const term of Array.isArray(value) ? value : [value]) {
    url.searchParams.append(key, typeof term === "string" ? term : term.value)
  }
}

function defaultHost() {
  if (Bun.env.SHEAF_HOST) return Bun.env.SHEAF_HOST
  if (Bun.env.PORT) return `http://${Bun.env.SHEAF_HTTP_IP || "127.0.0.1"}:${Bun.env.PORT}`
  if (Bun.env.PHX_HOST) return `https://${Bun.env.PHX_HOST}`
  return "https://sheaf.less.rest"
}

function cleanHost(value: string) {
  return value.trim().replace(/\/+$/, "")
}
