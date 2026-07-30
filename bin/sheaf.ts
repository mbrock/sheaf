#!/usr/bin/env bun

import { parseArgs } from "util"

export {}

const usage = `Sheaf research-library client

Usage:
  sheaf status
  sheaf tools
  sheaf documents
  sheaf document ID
  sheaf read ID... [--expand]
  sheaf search QUERY... [--document ID] [--kind KIND] [--limit N]
  sheaf notes
  sheaf note TEXT... [--title TITLE] [--block ID...]
  sheaf note --file PATH [--title TITLE] [--block ID...]
  sheaf call TOOL [JSON_ARGUMENTS]
  sheaf open ID

Configuration:
  SHEAF_URL       Sheaf instance URL, for example https://sheaf.example
  SHEAF_TOKEN     Bearer token for agent access

  SHEAF_RESOURCE_BASE, SHEAF_HOST, and SHEAF_MCP_TOKEN are also accepted for
  use inside a Sheaf checkout. Keep tokens in an untracked .env or your shell
  environment.

Output:
  Commands print concise Markdown suitable for humans and coding agents.
  Pass --json to print the underlying protocol result as JSON.

Examples:
  sheaf documents
  sheaf search "distributed cognition" --kind literature --limit 5
  sheaf read ABC123 DEF456 --expand
  sheaf note "The implementation follows #ABC123." --block ABC123
  printf '%s\\n' "A note read from stdin." | sheaf note`

class CliError extends Error {}

type JsonObject = Record<string, unknown>

type RpcResult = {
  content?: Array<{ type?: string; text?: string }>
  isError?: boolean
  tools?: Array<{
    name: string
    description?: string
    inputSchema?: JsonObject
  }>
  [key: string]: unknown
}

const { values, positionals } = cliArgs()

const [command = "help", ...commandArgs] = positionals

try {
  if (values.help || command === "help") {
    console.log(usage)
  } else {
    await run(command, commandArgs)
  }
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  console.error(`sheaf: ${message}`)
  process.exitCode = 1
}

async function run(command: string, args: string[]) {
  switch (command) {
    case "status":
      requireCount(command, args, 0)
      printResult(await initialize())
      return

    case "tools":
      requireCount(command, args, 0)
      printTools(await request("tools/list"))
      return

    case "documents":
      requireCount(command, args, 0)
      printResult(await callTool("list_documents"))
      return

    case "document":
      requireCount(command, args, 1)
      printResult(
        await callTool("get_document", { id: normalizeHandle(args[0]!) }),
      )
      return

    case "read":
      requireCount(command, args, 1, Infinity)
      printResult(
        await callTool("read", {
          blocks: args.map(normalizeHandle),
          expand: values.expand || false,
        }),
      )
      return

    case "search":
      await search(args)
      return

    case "notes":
      requireCount(command, args, 0)
      printResult(await callTool("list_notes"))
      return

    case "note":
      await writeNote(args)
      return

    case "call":
      await genericCall(args)
      return

    case "open":
      requireCount(command, args, 1)
      console.log(
        new URL(encodeURIComponent(normalizeHandle(args[0]!)), baseUrl())
          .href,
      )
      return

    default:
      throw new CliError(`unknown command: ${command}\n\n${usage}`)
  }
}

async function search(args: string[]) {
  requireCount("search", args, 1, Infinity)

  const limit = values.limit ? parsePositiveInteger(values.limit) : undefined
  const arguments_: JsonObject = { query: args.join(" ") }

  if (values.document)
    arguments_.document_id = normalizeHandle(values.document)
  if (values.kind) arguments_.document_kind = values.kind
  if (limit !== undefined) arguments_.limit = limit

  printResult(await callTool("search_text", arguments_))
}

async function writeNote(args: string[]) {
  if (values.file && args.length > 0)
    throw new CliError(
      "note text must come from arguments or --file, not both",
    )

  let text: string

  if (values.file === "-") {
    text = await Bun.stdin.text()
  } else if (values.file) {
    const file = Bun.file(values.file)
    if (!(await file.exists()))
      throw new CliError(`note file does not exist: ${values.file}`)
    text = await file.text()
  } else if (args.length > 0) {
    text = args.join(" ")
  } else if (!process.stdin.isTTY) {
    text = await Bun.stdin.text()
  } else {
    throw new CliError("note requires text, --file PATH, or standard input")
  }

  text = text.trim()
  if (text === "") throw new CliError("note text cannot be empty")

  const arguments_: JsonObject = {
    text,
    block_ids: (values.block || []).map(normalizeHandle),
  }
  if (values.title) arguments_.title = values.title

  printResult(await callTool("write_note", arguments_))
}

async function genericCall(args: string[]) {
  requireCount("call", args, 1, 2)

  let arguments_: JsonObject = {}
  if (args[1]) {
    try {
      const parsed = JSON.parse(args[1])
      if (!parsed || Array.isArray(parsed) || typeof parsed !== "object")
        throw new Error("arguments must be a JSON object")
      arguments_ = parsed
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      throw new CliError(`invalid JSON arguments: ${message}`)
    }
  }

  printResult(await callTool(args[0]!, arguments_))
}

async function initialize() {
  return request("initialize", {
    protocolVersion: "2025-11-25",
    capabilities: {},
    clientInfo: { name: "sheaf-cli", version: "0.1.0" },
  })
}

async function callTool(name: string, arguments_: JsonObject = {}) {
  return request("tools/call", { name, arguments: arguments_ })
}

async function request(
  method: string,
  params?: JsonObject,
): Promise<RpcResult> {
  const endpoint = mcpEndpoint()
  const token = process.env.SHEAF_TOKEN || process.env.SHEAF_MCP_TOKEN

  if (!token)
    throw new CliError(
      "SHEAF_TOKEN is not set; put the Sheaf bearer token in your environment",
    )

  let response: Response
  try {
    response = await fetch(endpoint, {
      method: "POST",
      headers: {
        accept: "application/json",
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        "mcp-protocol-version": "2025-11-25",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method,
        ...(params ? { params } : {}),
      }),
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    throw new CliError(`could not reach ${endpoint}: ${message}`)
  }

  const bodyText = await response.text()
  let body: Record<string, any>
  try {
    body = bodyText ? JSON.parse(bodyText) : {}
  } catch {
    throw new CliError(
      `${method} returned HTTP ${response.status} with a non-JSON response`,
    )
  }

  if (!response.ok) {
    const detail = body.error || body.message || bodyText
    const hint =
      response.status === 401
        ? " (check SHEAF_TOKEN)"
        : response.status === 503
          ? " (agent access is not configured on this Sheaf instance)"
          : ""
    throw new CliError(`HTTP ${response.status}: ${detail}${hint}`)
  }

  if (body.error) {
    const detail = body.error.message || JSON.stringify(body.error)
    throw new CliError(`${method} failed: ${detail}`)
  }

  if (!body.result || typeof body.result !== "object")
    throw new CliError(`${method} returned no result`)

  return body.result
}

function printResult(result: RpcResult) {
  if (values.json) {
    console.log(JSON.stringify(result, null, 2))
    if (result.isError) process.exitCode = 1
    return
  }

  const text = result.content
    ?.filter((part) => part.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n")

  if (text) {
    if (result.isError) console.error(text)
    else console.log(text)
  } else {
    console.log(JSON.stringify(result, null, 2))
  }

  if (result.isError) process.exitCode = 1
}

function printTools(result: RpcResult) {
  if (values.json) {
    console.log(JSON.stringify(result, null, 2))
    return
  }

  for (const tool of result.tools || []) {
    console.log(tool.name)
    if (tool.description) console.log(`  ${tool.description}`)

    const schema = tool.inputSchema as
      | {
          properties?: Record<string, unknown>
          required?: string[]
        }
      | undefined
    const names = Object.keys(schema?.properties || {})
    if (names.length) {
      const required = new Set(schema?.required || [])
      console.log(
        `  arguments: ${names
          .map((name) => `${name}${required.has(name) ? " (required)" : ""}`)
          .join(", ")}`,
      )
    }
    console.log("")
  }
}

function configuredUrl() {
  const raw =
    values.url ||
    values.host ||
    process.env.SHEAF_URL ||
    process.env.SHEAF_RESOURCE_BASE ||
    process.env.SHEAF_HOST

  if (!raw)
    throw new CliError(
      "SHEAF_URL is not set; point it at the Sheaf instance, for example https://sheaf.example",
    )

  try {
    return new URL(raw)
  } catch {
    throw new CliError(`invalid Sheaf URL: ${raw}`)
  }
}

function mcpEndpoint() {
  const url = configuredUrl()
  const path = url.pathname.replace(/\/+$/, "")
  url.pathname = path.endsWith("/mcp") ? path : `${path}/mcp`
  url.search = ""
  url.hash = ""
  return url.href
}

function baseUrl() {
  const url = configuredUrl()
  url.pathname = `${url.pathname.replace(/\/mcp\/?$/, "").replace(/\/+$/, "")}/`
  url.search = ""
  url.hash = ""
  return url
}

function normalizeHandle(value: string) {
  return /^#[A-Za-z0-9]{6}$/.test(value) ? value.slice(1) : value
}

function parsePositiveInteger(value: string) {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number < 1)
    throw new CliError(`expected a positive integer, got: ${value}`)
  return number
}

function requireCount(
  command: string,
  args: string[],
  minimum: number,
  maximum = minimum,
) {
  if (args.length >= minimum && args.length <= maximum) return

  const expectation =
    minimum === maximum
      ? `${minimum} argument${minimum === 1 ? "" : "s"}`
      : `at least ${minimum} argument${minimum === 1 ? "" : "s"}`
  throw new CliError(`${command} expects ${expectation}; run sheaf help`)
}

function cliArgs() {
  try {
    return parseArgs({
      args: Bun.argv.slice(2),
      allowPositionals: true,
      strict: true,
      options: {
        url: { type: "string" },
        host: { type: "string" },
        json: { type: "boolean" },
        help: { type: "boolean", short: "h" },
        expand: { type: "boolean" },
        document: { type: "string" },
        kind: { type: "string" },
        limit: { type: "string" },
        title: { type: "string" },
        block: { type: "string", multiple: true },
        file: { type: "string" },
      },
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error(`sheaf: ${message}; run sheaf help`)
    process.exit(1)
  }
}
