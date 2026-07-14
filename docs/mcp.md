# Sheaf MCP server

Sheaf exposes its research library to external agents through a stateless
Model Context Protocol endpoint:

```text
https://YOUR-SHEAF-HOST/mcp
```

The endpoint uses Streamable HTTP and supports MCP protocol revisions
`2025-11-25`, `2025-06-18`, and `2025-03-26`. It does not open a server-sent
event stream because all current Sheaf operations complete in the POST
response.

## Configuration

Set a long random bearer token in the Sheaf environment and restart the
service:

```sh
SHEAF_MCP_TOKEN=replace-with-a-long-random-secret
```

The endpoint returns `503` until this variable is set. MCP clients must send:

```text
Authorization: Bearer replace-with-a-long-random-secret
```

Most remote MCP clients have a `headers` field for static HTTP headers. Point
the client at `https://YOUR-SHEAF-HOST/mcp` and add the authorization header
there. Keep the token out of tracked client configuration.

Non-browser clients normally omit `Origin` and need no further setup. Browser
requests are accepted only from the same origin by default. Additional trusted
origins can be supplied as a comma-separated list:

```sh
SHEAF_MCP_ALLOWED_ORIGINS=https://client.example,https://another.example
```

## Tools

- `list_documents` lists the corpus with stable document ids and metadata.
- `get_document` returns one document's metadata and section outline.
- `read` reads document roots, blocks, or research notes; `expand: true`
  recursively expands documents and sections.
- `search_text` performs hybrid exact and semantic search, optionally scoped
  by document id or kind.
- `list_notes` lists durable research notes, newest first.
- `write_note` creates a durable research note and records explicitly related
  block ids.

Document and block ids are six-character Sheaf handles without the leading
`#` in tool arguments. Agents should retain the leading `#` when citing those
handles in prose so Sheaf can render and resolve them.

## Smoke test

An MCP initialize request can be checked directly:

```sh
curl https://YOUR-SHEAF-HOST/mcp \
  -H 'Authorization: Bearer replace-with-a-long-random-secret' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```
