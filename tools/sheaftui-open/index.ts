#!/usr/bin/env bun

import { BoxRenderable, createCliRenderer, ScrollBoxRenderable, TextRenderable } from "@opentui/core"
import { mkdirSync, openSync, writeSync } from "fs"
import { dirname } from "path"

type DocumentSummary = {
  id: string
  iri: string
  kind: string
  title?: string | null
  path?: string | null
  metadata?: {
    title?: string | null
    year?: string | null
    kind?: string | null
    status?: string | null
    authors?: string[]
    page_count?: number | null
    pages?: string | null
    venue?: string | null
  } | null
}

type OutlineEntry = {
  id: string
  iri: string
  number?: string | null
  title?: string | null
  children?: OutlineEntry[]
}

type DocumentDetail = DocumentSummary & {
  outline?: OutlineEntry[]
}

type BlockChild = {
  id: string
  iri: string
  type?: string | null
  title?: string | null
}

type BlockDetail = {
  id: string
  iri: string
  type?: string | null
  title?: string | null
  text?: string | null
  children?: BlockChild[]
}

type Row =
  | { kind: "header"; label: string; count: number }
  | { kind: "document"; document: DocumentSummary }
  | { kind: "outline"; entry: OutlineEntry; depth: number }
  | { kind: "block"; block: BlockChild; depth: number }
  | { kind: "text"; text: string; depth: number }
  | { kind: "message"; text: string }

type Frame =
  | { kind: "index"; title: string; rows: Row[]; selected: number }
  | { kind: "document"; title: string; document: DocumentSummary; rows: Row[]; selected: number }
  | { kind: "block"; title: string; document: DocumentSummary; block: BlockDetail; rows: Row[]; selected: number }

const args = parseArgs(Bun.argv.slice(2))
const host = cleanHost(
  args.host ||
    Bun.env.SHEAF_HOST ||
    (Bun.env.PORT
      ? `http://${Bun.env.SHEAF_HTTP_IP || "127.0.0.1"}:${Bun.env.PORT}`
      : Bun.env.PHX_HOST
        ? `https://${Bun.env.PHX_HOST}`
        : "https://sheaf.less.rest"),
)
const log = openLog(args["debug-log"] ?? "var/sheaftui-open.log")

debug(`startup host=${host}`)

const renderer = await createCliRenderer({
  exitOnCtrlC: true,
  useMouse: false,
  useKittyKeyboard: null,
  consoleMode: "disabled",
  openConsoleOnError: false,
  targetFps: 30,
})

let loading = true
let status = "loading documents..."
let frames: Frame[] = [{ kind: "index", title: "Documents", rows: [{ kind: "message", text: status }], selected: 0 }]
let renderGeneration = 0
let rowIds: string[] = []

const app = new BoxRenderable(renderer, {
  id: "app",
  width: "100%",
  height: "100%",
  flexDirection: "column",
})

const list = new ScrollBoxRenderable(renderer, {
  id: "outline",
  width: "100%",
  flexGrow: 1,
  scrollY: true,
  viewportCulling: true,
  rootOptions: { backgroundColor: "#000000" },
  viewportOptions: { backgroundColor: "#000000" },
  contentOptions: { backgroundColor: "#000000", flexDirection: "column" },
  verticalScrollbarOptions: { visible: false } as any,
})

const footer = new TextRenderable(renderer, {
  id: "footer",
  width: "100%",
  height: 1,
  content: status,
  fg: "#8f846e",
  truncate: true,
})

app.add(list)
app.add(footer)
renderer.root.add(app)

renderer.keyInput.on("keypress", (key) => {
  debug(
    `key name=${JSON.stringify(key.name)} sequence=${JSON.stringify(key.sequence)} raw=${JSON.stringify(key.raw)} ctrl=${key.ctrl} meta=${key.meta} shift=${key.shift}`,
  )

  if (key.ctrl && key.name === "c") {
    renderer.destroy()
    return
  }

  switch (key.name) {
    case "q":
      renderer.destroy()
      return
    case "j":
    case "down":
      move(1)
      return
    case "k":
    case "up":
      move(-1)
      return
    case "g":
    case "home":
      select(selectableIndexes(current()).at(0) ?? 0)
      return
    case "G":
    case "end":
      select(selectableIndexes(current()).at(-1) ?? 0)
      return
    case "h":
    case "left":
    case "backspace":
      popFrame()
      return
    case "l":
    case "right":
    case "enter":
    case "return":
      void drill()
      return
    case "space":
    case "pagedown":
      list.scrollBy(1, "viewport")
      return
    case "b":
    case "pageup":
      list.scrollBy(-1, "viewport")
      return
    case "r":
      if (!loading) void refresh()
      return
  }
})

await refresh()

async function refresh() {
  loading = true
  status = frames.length === 1 ? "loading documents..." : "refreshing documents..."
  render()

  try {
    const start = performance.now()
    const documents = await getJson<{ documents?: DocumentSummary[] }>("/api/documents")
    const rows = documentRows((documents.documents || []).filter((document) => !["transcript", "spreadsheet"].includes(document.kind)))
    frames = [{ kind: "index", title: "Documents", rows, selected: firstSelectable(rows) }]
    status = `${selectableIndexes(current()).length} documents from ${host}`
    debug(`documents ok rows=${rows.length} elapsed_ms=${(performance.now() - start).toFixed(1)}`)
  } catch (error) {
    status = `failed: ${error instanceof Error ? error.message : String(error)}`
    frames = [{ kind: "index", title: "Documents", rows: [{ kind: "message", text: status }], selected: 0 }]
    debug(`documents error ${status}`)
  } finally {
    loading = false
    render()
  }
}

async function drill() {
  if (loading) return
  const frame = current()
  const row = frame.rows[frame.selected]
  if (!row || row.kind === "header" || row.kind === "message" || row.kind === "text") return

  loading = true
  status = "loading..."
  render()

  try {
    if (row.kind === "document") {
      const document = await getJson<DocumentDetail>(`/api/documents/${row.document.id}`)
      const outline = document.outline || []
      const rows = outline.length > 0 ? flattenOutline(outline) : [{ kind: "message" as const, text: "no outline" }]
      frames.push({
        kind: "document",
        title: documentTitle(document),
        document,
        rows,
        selected: firstSelectable(rows),
      })
      status = `${outline.length} top-level sections`
      debug(`document open id=${document.id} outline=${outline.length}`)
    } else if (row.kind === "outline") {
      const document = nearestDocument()
      if (!document) return
      await pushBlock(document, row.entry.id, row.entry.title || row.entry.id)
    } else if (row.kind === "block") {
      const document = nearestDocument()
      if (!document) return
      await pushBlock(document, row.block.id, row.block.title || row.block.id)
    }
  } catch (error) {
    status = `failed: ${error instanceof Error ? error.message : String(error)}`
    debug(`drill error ${status}`)
  } finally {
    loading = false
    render()
  }
}

async function pushBlock(document: DocumentSummary, blockId: string, fallbackTitle: string) {
  const block = await getJson<BlockDetail>(`/api/documents/${document.id}/blocks/${blockId}`)
  const rows = blockRows(block)
  frames.push({
    kind: "block",
    title: block.title || fallbackTitle,
    document,
    block,
    rows,
    selected: firstSelectable(rows),
  })
  status = `${block.type || "block"} ${block.id}`
  debug(`block open document=${document.id} block=${block.id} type=${block.type} rows=${rows.length}`)
}

function render() {
  renderGeneration++
  clearRows()

  const frame = current()
  if (frame.rows.length === 0) {
    addText("empty", "nothing here", "#8f846e")
    footer.content = footerText()
    return
  }

  for (let i = 0; i < frame.rows.length; i++) {
    drawRow(frame.rows[i]!, i, i === frame.selected)
  }

  footer.content = footerText()
  list.scrollChildIntoView(rowId(`row-${frame.selected}`))
}

function drawRow(row: Row, index: number, selected: boolean) {
  if (row.kind === "header") {
    const count = String(row.count)
    const label = row.label.toUpperCase()
    addText(`row-${index}`, fitColumns(`  ${label}`, count, renderer.width), "#8f846e", undefined, true)
    return
  }

  if (row.kind === "message") {
    addText(`row-${index}`, row.text, "#8f846e")
    return
  }

  if (row.kind === "document") {
    const meta = row.document.metadata || {}
    const title = documentTitle(row.document)
    const right = meta.page_count ? `${meta.page_count} pp.` : statusLabel(meta.status)
    const marker = selected ? "▌ " : "  "
    addText(`row-${index}`, fitColumns(`${marker}${title}`, right, renderer.width), selected ? "#f0dfb7" : "#d8c7a3", selected ? "#263746" : undefined)
    const byline = [meta.year, authors(meta.authors)].filter(Boolean).join("  ")
    if (byline) addText(`row-${index}-meta`, `    ${fit(byline, renderer.width - 4)}`, "#8f846e")
    return
  }

  if (row.kind === "outline") {
    const indent = "  ".repeat(row.depth)
    const number = row.entry.number ? `${row.entry.number}. ` : ""
    const marker = selected ? "▌ " : "  "
    addText(
      `row-${index}`,
      fit(`${marker}${indent}${number}${row.entry.title || row.entry.id}`, renderer.width),
      selected ? "#f0dfb7" : row.depth === 0 ? "#d8c7a3" : "#bfb092",
      selected ? "#263746" : undefined,
    )
    return
  }

  if (row.kind === "block") {
    const indent = "  ".repeat(row.depth)
    const marker = selected ? "▌ " : "  "
    const type = row.block.type ? `${row.block.type}  ` : ""
    const title = row.block.title || row.block.id
    addText(
      `row-${index}`,
      fit(`${marker}${indent}${type}${title}`, renderer.width),
      selected ? "#f0dfb7" : "#d8c7a3",
      selected ? "#263746" : undefined,
    )
    return
  }

  const indent = "  ".repeat(row.depth)
  addText(`row-${index}`, fit(`  ${indent}${row.text}`, renderer.width), "#bfb092")
}

function documentRows(documents: DocumentSummary[]) {
  const groups = groupDocuments(documents)
  const rows: Row[] = []
  for (const group of groups) {
    rows.push({ kind: "header", label: group.label, count: group.documents.length })
    for (const document of group.documents) rows.push({ kind: "document", document })
  }
  return rows
}

function groupDocuments(documents: DocumentSummary[]) {
  const map = new Map<string, DocumentSummary[]>()
  for (const document of documents) {
    const key = groupLabel(document)
    const group = map.get(key) || []
    group.push(document)
    map.set(key, group)
  }
  return [...map.entries()]
    .map(([label, docs]) => ({
      label,
      documents: docs.sort((a, b) => documentTitle(a).localeCompare(documentTitle(b))),
    }))
    .sort((a, b) => groupOrder(a.label) - groupOrder(b.label) || a.label.localeCompare(b.label))
}

function groupLabel(document: DocumentSummary) {
  if (document.kind === "thesis") return "Thesis"
  const kind = document.metadata?.kind
  if (kind === "Journal article") return "Journal articles"
  if (kind === "Book") return "Books"
  if (kind === "Book chapter") return "Book chapters"
  if (kind === "Doctoral thesis") return "Doctoral theses"
  if (kind === "Report document") return "Reports"
  return kind ? `${kind}s` : "Documents"
}

function groupOrder(label: string) {
  const index = ["Thesis", "Journal articles", "Books", "Book chapters", "Doctoral theses", "Reports", "Documents"].indexOf(label)
  return index === -1 ? 99 : index
}

function flattenOutline(entries: OutlineEntry[], depth = 0): Row[] {
  return entries.flatMap((entry) => [
    { kind: "outline" as const, entry, depth },
    ...flattenOutline(entry.children || [], depth + 1),
  ])
}

function blockRows(block: BlockDetail): Row[] {
  const rows: Row[] = []
  if (block.text) {
    for (const line of wrap(cleanText(block.text), Math.max(20, renderer.width - 4)).slice(0, 40)) {
      rows.push({ kind: "text", text: line, depth: 0 })
    }
  }
  for (const child of block.children || []) {
    rows.push({ kind: "block", block: child, depth: 0 })
  }
  if (rows.length === 0) rows.push({ kind: "message", text: "empty block" })
  return rows
}

function move(delta: number) {
  const frame = current()
  const indexes = selectableIndexes(frame)
  if (indexes.length === 0) return
  const currentPosition = Math.max(0, indexes.indexOf(frame.selected))
  select(indexes[clamp(currentPosition + delta, 0, indexes.length - 1)]!)
}

function select(index: number) {
  current().selected = clamp(index, 0, current().rows.length - 1)
  render()
}

function popFrame() {
  if (frames.length <= 1) return
  frames.pop()
  status = frames.length === 1 ? `${selectableIndexes(current()).length} documents from ${host}` : current().title
  render()
}

function current() {
  return frames[frames.length - 1]!
}

function nearestDocument() {
  for (let i = frames.length - 1; i >= 0; i--) {
    const frame = frames[i]!
    if (frame.kind === "document" || frame.kind === "block") return frame.document
  }
  return undefined
}

function selectableIndexes(frame: Frame) {
  return frame.rows.flatMap((row, index) =>
    row.kind === "document" || row.kind === "outline" || row.kind === "block" ? [index] : [],
  )
}

function firstSelectable(rows: Row[]) {
  return rows.findIndex((row) => row.kind === "document" || row.kind === "outline" || row.kind === "block")
}

async function getJson<T>(path: string): Promise<T> {
  const endpoint = `${host}${path}`
  const start = performance.now()
  debug(`fetch start endpoint=${endpoint}`)
  const res = await fetch(endpoint, { headers: { accept: "application/json" } })
  const text = await res.text()
  debug(`fetch response status=${res.status} bytes=${text.length} elapsed_ms=${(performance.now() - start).toFixed(1)}`)
  const body = JSON.parse(text)
  if (!res.ok) throw new Error(body.error || body.reason || res.statusText)
  return body as T
}

function addText(id: string, content: string, fg: string, bg?: string, _bold = false) {
  const row = new TextRenderable(renderer, {
    id: rowId(id),
    width: "100%",
    height: 1,
    content,
    fg,
    bg,
    truncate: true,
  })
  list.add(row)
  rowIds.push(row.id)
}

function clearRows() {
  for (const id of rowIds) {
    try {
      list.remove(id)
    } catch {
      // OpenTUI remove is best-effort across fast rerenders.
    }
  }
  rowIds = []
}

function footerText() {
  const crumbs = frames.map((frame) => frame.title).join(" / ")
  return fit(`${crumbs}   ${status}   j/k move  enter drill  h back  r refresh  q quit`, renderer.width)
}

function documentTitle(document: DocumentSummary) {
  return document.metadata?.title || document.title || document.id
}

function authors(values?: string[]) {
  return values?.filter(Boolean).join(", ") || ""
}

function statusLabel(value?: string | null) {
  return value ? value.toUpperCase() : ""
}

function fitColumns(left: string, right: string, width: number) {
  if (!right) return fit(left, width)
  const leftWidth = Math.max(1, width - right.length - 2)
  return `${fit(left, leftWidth)}  ${right}`
}

function fit(value: string, width: number) {
  if (value.length <= width) return value.padEnd(width, " ")
  if (width <= 1) return "…"
  return `${value.slice(0, width - 1)}…`
}

function wrap(text: string, width: number) {
  const words = text.split(/\s+/).filter(Boolean)
  const lines: string[] = []
  let line = ""
  for (const word of words) {
    if (!line) {
      line = word
    } else if (line.length + word.length + 1 <= width) {
      line += ` ${word}`
    } else {
      lines.push(line)
      line = word
    }
  }
  if (line) lines.push(line)
  return lines
}

function cleanText(value: string) {
  return value.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim()
}

function rowId(id: string) {
  return `row-${renderGeneration}-${id}`
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value))
}

function cleanHost(value: string) {
  return value.trim().replace(/\/+$/, "")
}

function parseArgs(argv: string[]) {
  const values: Record<string, string | undefined> = {}
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!
    if (!arg.startsWith("--")) continue
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

function openLog(path: string | undefined) {
  if (!path) return undefined
  mkdirSync(dirname(path), { recursive: true })
  return openSync(path, "a")
}

function debug(message: string) {
  if (log === undefined) return
  writeSync(log, `${new Date().toISOString()} ${message}\n`)
}
