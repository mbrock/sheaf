#!/usr/bin/env bun

import { parseArgs } from "util";

export {}; // top level await plz

const usage = `Usage:
  sheaf docs
  sheaf doc ID
  sheaf outline ID
  sheaf block DOC BLOCK
  sheaf read DOC
  sheaf text DOC [BLOCK]
  sheaf notes
  sheaf get ID
  sheaf open ID

Flags:
  --host URL   default: SHEAF_HOST or https://sheaf.less.rest`;

type Command = {
  usage: string;
  min?: number;
  max?: number;
  path: (...args: string[]) => string;
};

const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: {
    host: { type: "string" },
    help: { type: "boolean", short: "h" },
  },
});

const host =
  values.host || process.env.SHEAF_HOST || "https://sheaf.less.rest";
const [cmd = "help", ...args] = values.help ? ["help"] : positionals;

const commands: Record<string, Command> = {
  docs: {
    usage: "sheaf docs",
    path: () => "/api/documents",
  },
  doc: {
    usage: "sheaf doc ID",
    min: 1,
    max: 1,
    path: (id) => `/api/documents/${id}`,
  },
  outline: {
    usage: "sheaf outline ID",
    min: 1,
    max: 1,
    path: (id) => `/api/documents/${id}`,
  },
  block: {
    usage: "sheaf block DOC BLOCK",
    min: 2,
    max: 2,
    path: (doc, block) => `/api/documents/${doc}/blocks/${block}`,
  },
  read: {
    usage: "sheaf read DOC",
    min: 1,
    max: 1,
    path: (doc) => `/api/documents/${doc}/chunks`,
  },
  text: {
    usage: "sheaf text DOC [BLOCK]",
    min: 1,
    max: 2,
    path: (doc, block) =>
      block
        ? `/api/documents/${doc}/blocks/${block}`
        : `/api/documents/${doc}/chunks`,
  },
  notes: {
    usage: "sheaf notes",
    path: () => "/api/notes",
  },
  get: {
    usage: "sheaf get ID",
    min: 1,
    max: 1,
    path: (id) => `/${id}`,
  },
};

if (["help", "-h", "--help"].includes(cmd)) {
  console.log(usage);
  process.exit(0);
} else if (cmd === "open") {
  requireArgs(
    { usage: "sheaf open ID", min: 1, max: 1, path: () => "" },
    args,
  );
  console.log(`${host.replace(/\/+$/, "")}/${args[0]}`);
  process.exit(0);
}

const command = commands[cmd] || fail(`unknown command: ${cmd}`);
requireArgs(command, args);

const path = command.path(...args.map(encodeURIComponent));

const res = await fetch(`${host.replace(/\/+$/, "")}${path}`, {
  headers: { accept: "application/json" },
});

if (!res.ok)
  fail(`GET ${path} failed: HTTP ${res.status}\n${await res.text()}`);

console.log(JSON.stringify(await res.json(), null, 2));

function requireArgs(command: Command, args: string[]) {
  const min = command.min ?? 0;
  const max = command.max ?? min;

  if (args.length < min || args.length > max) {
    console.error(`usage: ${command.usage}`);
    process.exit(1);
  }
}

function fail(message: string): never {
  console.error(`sheaf: ${message}`);
  process.exit(1);
}
