# Sheaf CLI

The Sheaf CLI gives coding agents and humans a small command-line interface to
a remote research library. The caller does not need the Sheaf source tree or
native MCP support. It only needs the standalone client, a Sheaf URL, and an
access token.

The command surface deliberately matches the bounded external research
capabilities:

- discover the available documents and their outlines
- read documents, sections, blocks, source files, and research notes
- search exact and semantic indexes
- list and create durable research notes

Run `sheaf help` for the complete local command reference. Help does not make a
network request.

## Install

The client is the single zero-dependency Bun script at `bin/sheaf.ts`. Copy it
to the project where the agent will use it:

```sh
mkdir -p /path/to/project/bin
install -m 755 bin/sheaf.ts /path/to/project/bin/sheaf
```

Alternatively, install it once on `PATH`:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/sheaf.ts "$HOME/.local/bin/sheaf"
```

The client requires [Bun](https://bun.sh/) but has no package installation or
runtime dependencies.

## Configure a project

Set these values in the coding project's untracked `.env`, shell environment,
or secret manager:

```sh
SHEAF_URL=https://YOUR-SHEAF-HOST
SHEAF_TOKEN=replace-with-the-sheaf-agent-token
```

With direnv, an untracked `.env` can be loaded from `.envrc`:

```sh
dotenv_if_exists .env
```

Do not put the token in a tracked wrapper script. A project-local wrapper only
needs to invoke the installed client:

```sh
#!/usr/bin/env bash
set -euo pipefail
exec sheaf "$@"
```

To make the capability obvious to coding agents, add one line to the project's
`AGENTS.md`:

```md
The research library is available through `./bin/sheaf`; start with
`./bin/sheaf help`, then use `search`, `read`, and `note`.
```

Inside a Sheaf checkout, the existing `SHEAF_RESOURCE_BASE`, `SHEAF_HOST`, and
`SHEAF_MCP_TOKEN` variables are accepted as fallbacks.

## Use

Check the connection and discover the server's tool schemas:

```sh
sheaf status
sheaf tools
```

Browse the library:

```sh
sheaf documents
sheaf document ABC123
sheaf read ABC123
sheaf read ABC123 --expand
sheaf read ABC123 DEF456
```

Search across the corpus or narrow the search:

```sh
sheaf search "distributed cognition"
sheaf search implementation provenance --document ABC123
sheaf search circular economy --kind literature --limit 5
```

List and create durable research notes:

```sh
sheaf notes
sheaf note "The implementation claim is supported by #ABC123." \
  --title "Implementation evidence" \
  --block ABC123
printf '%s\n' "A note supplied on standard input." | sheaf note
sheaf note --file findings.md --block ABC123 --block DEF456
```

The default output is concise Markdown with stable Sheaf handles, designed to
be readable directly by a coding agent. `--json` prints the underlying
protocol result. `sheaf call TOOL JSON_ARGUMENTS` is a generic escape hatch
for inspecting or scripting the server's published tools.

## HTTP contract

The CLI sends authenticated JSON requests to `SHEAF_URL/mcp`. MCP is an
implementation detail here: a coding agent uses ordinary commands and does
not need an MCP client or integration. Keeping the CLI on this endpoint means
the CLI, MCP clients, and Sheaf's own assistant all reuse the same corpus and
note operations rather than maintaining separate API behavior.

The Sheaf service must have `SHEAF_MCP_TOKEN` configured as described in
[the MCP server documentation](mcp.md). The value supplied to the CLI as
`SHEAF_TOKEN` is that same bearer token.
