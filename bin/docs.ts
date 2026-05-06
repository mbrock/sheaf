#!/usr/bin/env bun

import { parseArgs } from "util";

type DocsResponse = {
  targets: DocsTarget[];
};

type DocsTarget =
  | DocsOverview
  | DocsModule
  | DocsFunctionGroup
  | DocsError;

type DocsOverview = {
  kind: "overview";
  app: string;
  title: string;
  modules: Array<{ name: string; depth: number; summary?: string | null }>;
};

type DocsModule = {
  kind: "module";
  module: string;
  requested_as: string;
  source?: string | null;
  doc?: string | null;
  public_function_count: number;
  public_functions: DocsFunction[];
  source_excerpt?: SourceExcerpt | null;
};

type DocsFunctionGroup = {
  kind: "function_group";
  requested_as: string;
  functions: DocsFunction[];
};

type DocsFunction = {
  name: string;
  arity: number;
  kind: string;
  signature: string;
  doc?: string | null;
  module?: string;
  source?: { path?: string | null; line?: number | null };
  source_excerpt?: SourceExcerpt | null;
};

type DocsError = {
  kind: "error";
  requested_as?: string;
  module?: string;
  error: string;
};

type SourceExcerpt = {
  from: number;
  to: number;
  language: string;
  lines: string[];
};

const usage = `Usage: bin/docs [--source] [--json] [--host URL] [:app_name | Module.Name | Module.function/arity ...]

Examples:
  bin/docs
  bin/docs :rdf
  bin/docs Sheaf
  bin/docs Sheaf.mint/0
  bin/docs --source Sheaf.query/2 RDF.Graph`;

const { values, positionals } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  options: {
    source: { type: "boolean", short: "s" },
    json: { type: "boolean" },
    host: { type: "string" },
    help: { type: "boolean", short: "h" },
  },
});

if (values.help) {
  console.log(usage);
  process.exit(0);
}

const baseUrl = (
  values.host ||
  process.env.SHEAF_DOCS_HOST ||
  process.env.SHEAF_HOST ||
  `http://127.0.0.1:${process.env.PORT || "4000"}`
).replace(/\/+$/, "");

const params = new URLSearchParams();
for (const target of positionals) params.append("target", target);
if (values.source) params.set("source", "true");

const path = `/api/docs${params.size ? `?${params}` : ""}`;
const response = await fetch(`${baseUrl}${path}`, {
  headers: { accept: "application/json" },
});

if (!response.ok) {
  fail(`GET ${path} failed: HTTP ${response.status}\n${await response.text()}`);
}

const data = (await response.json()) as DocsResponse;

if (values.json) {
  console.log(JSON.stringify(data, null, 2));
} else {
  console.log(data.targets.map(renderTarget).join("\n\n---\n\n"));
}

function renderTarget(target: DocsTarget): string {
  switch (target.kind) {
    case "overview":
      return renderOverview(target);
    case "module":
      return renderModule(target);
    case "function_group":
      return target.functions.map(renderFunction).join("\n\n");
    case "error":
      return renderError(target);
  }
}

function renderOverview(target: DocsOverview): string {
  return [
    `# ${target.title} module overview`,
    "",
    `Application: \`:${target.app}\``,
    "Use `bin/docs Module.Name` or `bin/docs Module.function/arity` for details.",
    "Use `bin/docs :app_name` to list modules for another loaded OTP application.",
    "Use `bin/docs --source Module.function/arity` to include a source clip.",
    "",
    `${target.title} modules`,
    ...target.modules.map((mod) => {
      const summary = mod.summary ? ` - ${mod.summary}` : "";
      return `${"  ".repeat(mod.depth)}- ${mod.name}${summary}`;
    }),
  ].join("\n");
}

function renderModule(target: DocsModule): string {
  return compact([
    `# ${target.module}`,
    "",
    `Requested as: ${target.requested_as}`,
    `Source: ${target.source || "(unknown)"}`,
    `Public functions: ${target.public_function_count}`,
    target.doc ? "" : null,
    target.doc,
    "",
    "Public API",
    ...target.public_functions.map((fn) => `- ${fn.signature}`),
    target.source_excerpt ? "" : null,
    renderSourceExcerpt(target.source_excerpt),
  ]).join("\n");
}

function renderFunction(fn: DocsFunction): string {
  return compact([
    `# ${fn.module}.${fn.name}/${fn.arity}`,
    "",
    `Signature: ${fn.signature}`,
    `Source: ${fn.source?.path || "(unknown)"}:${fn.source?.line || 0}`,
    fn.doc ? "" : null,
    fn.doc,
    fn.source_excerpt ? "" : null,
    renderSourceExcerpt(fn.source_excerpt),
  ]).join("\n");
}

function renderError(target: DocsError): string {
  const heading = target.requested_as || target.module || "docs error";
  return `# ${heading}\n\n${target.error}`;
}

function renderSourceExcerpt(excerpt?: SourceExcerpt | null): string | null {
  if (!excerpt) return null;

  const body = excerpt.lines
    .map((line, index) => `${excerpt.from + index}: ${line}`)
    .join("\n");

  return [
    `Source excerpt ${excerpt.from}-${excerpt.to}:`,
    `\`\`\`${excerpt.language || ""}`,
    body,
    "```",
  ].join("\n");
}

function compact<T>(values: Array<T | null | undefined | false>): T[] {
  return values.filter((value): value is T => value !== null && value !== undefined && value !== false);
}

function fail(message: string): never {
  console.error(`bin/docs: ${message}`);
  process.exit(1);
}
