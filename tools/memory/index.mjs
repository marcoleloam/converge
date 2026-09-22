#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { lstatSync, readFileSync, writeSync } from "node:fs";
import { lstat, mkdir, readdir, readFile, realpath, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { configureVault, locateSource } from "./vault.mjs";

let activeBinding;

const SCHEMA = "ConvergeMemory/v1";
const MAX_FILE_BYTES = 512 * 1024;
const ACTIONS = new Set(["init", "migrate", "refresh", "status", "search", "read"]);
const BLOCKED_DIRS = new Set([
  "node_modules",
  "templates",
  "runtime",
  "secrets",
  "credentials",
  "tasks",
  "receipts",
  "agents",
  ".git",
]);
const SOURCE_SPECS = [
  { name: "root", rel: "", kind: "files", files: ["README.md", "CLAUDE.md", "AGENTS.md"] },
  { name: "docs", rel: "docs", kind: "glob" },
  { name: "cvgdocs", rel: "cvg/docs", kind: "glob" },
  { name: "cvgbrain", rel: "cvg/brain", kind: "glob" },
  { name: "dfcvgdocs", rel: ".darkfactory/cvg/docs", kind: "glob" },
  { name: "legacybrain", rel: ".darkfactory/cvg/brain", kind: "glob" },
  { name: "sddmemory", rel: ".claude/sdd", kind: "files", files: ["MEMORY.md"] },
];

class BrainIssue extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function issue(status, code, message) {
  return new BrainIssue(status, code, message);
}

function last(arr) {
  return arr && arr.length ? arr[arr.length - 1] : undefined;
}

function parseIntOpt(raw, fallback, { min, max, clamp, name }) {
  if (raw == null || raw === "") return fallback;
  if (!/^-?\d+$/.test(raw)) throw issue("ERROR", "USAGE", `invalid ${name}`);
  let n = Number(raw);
  if (!Number.isSafeInteger(n)) throw issue("ERROR", "USAGE", `invalid ${name}`);
  if (clamp) {
    if (min != null && n < min) n = min;
    if (max != null && n > max) n = max;
    return n;
  }
  if (min != null && n < min) throw issue("ERROR", "USAGE", `invalid ${name}`);
  if (max != null && n > max) throw issue("ERROR", "USAGE", `invalid ${name}`);
  return n;
}

function parseCli(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      strict: true,
      options: {
        root: { type: "string", multiple: true },
        vault: { type: "string", multiple: true },
        "max-bytes": { type: "string", multiple: true },
        limit: { type: "string", multiple: true },
        from: { type: "string", multiple: true },
        lines: { type: "string", multiple: true },
      },
    });
  } catch {
    throw issue("ERROR", "USAGE", "invalid arguments");
  }
  const action = parsed.positionals[0];
  const rest = parsed.positionals.slice(1);
  const root = last(parsed.values.root);
  return {
    action,
    rest,
    root,
    vault: last(parsed.values.vault),
    maxBytes: parseIntOpt(last(parsed.values["max-bytes"]), 6000, {
      min: 512,
      max: 32000,
      clamp: true,
      name: "--max-bytes",
    }),
    limit: parseIntOpt(last(parsed.values.limit), 5, {
      min: 1,
      max: 10,
      clamp: true,
      name: "--limit",
    }),
    from: parseIntOpt(last(parsed.values.from), 1, { min: 1, clamp: false, name: "--from" }),
    lines: parseIntOpt(last(parsed.values.lines), 40, {
      min: 1,
      max: 120,
      clamp: true,
      name: "--lines",
    }),
  };
}

function posixJoin(...parts) {
  return parts.filter((p) => p !== "" && p != null).join("/");
}

function toPosix(rel) {
  return String(rel).split(path.sep).join("/");
}

function repoRel(rootAbs, abs) {
  const rel = path.relative(rootAbs, path.resolve(abs));
  if (!rel || rel.startsWith("..") || path.isAbsolute(rel)) return null;
  return toPosix(rel);
}

function absFromRel(rootAbs, relPosix) {
  return path.resolve(rootAbs, ...String(relPosix).split("/"));
}

async function lstatOrNull(abs) {
  try {
    return await lstat(abs);
  } catch (err) {
    if (err && err.code === "ENOENT") return null;
    throw err;
  }
}

async function inspectInside(rootAbs, abs, { create = false } = {}) {
  const resolved = path.resolve(abs);
  const rel = path.relative(rootAbs, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw issue("ERROR", "PATH", "path outside root");
  }
  let cur = rootAbs;
  const parts = rel === "" ? [] : rel.split(path.sep).filter(Boolean);
  for (const part of parts) {
    cur = path.join(cur, part);
    let st = await lstatOrNull(cur);
    if (!st) {
      if (!create) return { missing: true };
      await mkdir(cur, { mode: 0o700 });
      continue;
    }
    if (st.isSymbolicLink()) throw issue("ERROR", "SYMLINK", "symlink path rejected");
    if (!st.isDirectory() && part !== parts[parts.length - 1]) {
      throw issue("ERROR", "PATH", "path outside root");
    }
  }
  return { missing: false };
}

async function rejectSymlink(rootAbs, abs) {
  const st = await lstatOrNull(abs);
  if (!st) return;
  if (st.isSymbolicLink()) throw issue("ERROR", "SYMLINK", "symlink path rejected");
  await inspectInside(rootAbs, abs);
}

function safeMessage(err) {
  if (err instanceof BrainIssue) return err.message.slice(0, 300);
  const msg = err && err.message ? String(err.message) : "internal error";
  return msg.split("\n")[0].slice(0, 300);
}

function writeJson(payload, maxBytes) {
  const base = {
    schema: SCHEMA,
    status: payload.status,
    execution_authorized: false,
    action: payload.action,
    truncated: false,
    ...(activeBinding ? { project_id: activeBinding.project_id, project_name: activeBinding.project_name } : {}),
    ...(activeBinding && ["init", "migrate", "refresh", "status"].includes(payload.action) ? { vault_path: activeBinding.vault_path } : {}),
  };
  const out = { ...base, ...payload, schema: SCHEMA, execution_authorized: false };
  if (typeof out.truncated !== "boolean") out.truncated = false;
  delete out.bytes;

  const encode = (obj) => Buffer.from(`${JSON.stringify(obj)}\n`, "utf8");
  let buf = encode(out);
  let guard = 0;
  while (buf.byteLength > maxBytes && guard++ < 400) {
    out.truncated = true;
    const before = buf.byteLength;
    if (typeof out.text === "string" && out.text.length > 0) {
      const excess = buf.byteLength - maxBytes;
      const cut = Math.max(0, out.text.length - Math.max(8, excess));
      out.text = out.text.slice(0, cut);
    } else if (Array.isArray(out.results) && out.results.length) {
      const lastHit = out.results[out.results.length - 1];
      if (lastHit && typeof lastHit.snippet === "string" && lastHit.snippet.length > 0) {
        lastHit.snippet = lastHit.snippet.slice(0, Math.max(0, lastHit.snippet.length - 24));
      } else if (out.results.length > 1) {
        out.results.pop();
      } else if (lastHit && Object.prototype.hasOwnProperty.call(lastHit, "score")) {
        delete lastHit.score;
      } else if (lastHit && lastHit.snippet !== "") {
        lastHit.snippet = "";
      } else {
        break;
      }
    } else if (Array.isArray(out.sources) && out.sources.length) {
      out.sources.pop();
    } else {
      for (const key of ["stale", "message", "code", "query", "root"]) {
        if (key in out) {
          delete out[key];
          break;
        }
      }
    }
    buf = encode(out);
    if (buf.byteLength >= before) break;
  }
  if (buf.byteLength > maxBytes) {
    const minimal = {
      ...base,
      status: out.status,
      truncated: true,
    };
    if (out.path) minimal.path = out.path;
    if (out.sha256) minimal.sha256 = out.sha256;
    if (Number.isInteger(out.start_line)) minimal.start_line = out.start_line;
    if (Number.isInteger(out.end_line)) minimal.end_line = out.end_line;
    if (typeof out.text === "string") minimal.text = "";
    if (Array.isArray(out.results) && out.results[0]) {
      minimal.results = [
        {
          path: out.results[0].path,
          sha256: out.results[0].sha256,
          start_line: out.results[0].start_line,
          end_line: out.results[0].end_line,
          snippet: "",
        },
      ];
    }
    buf = encode(minimal);
  }
  if (buf.byteLength > maxBytes) {
    out.status = "ERROR";
    const error = { ...base, status: "ERROR", truncated: true, code: "BUDGET", message: "response exceeds output budget; increase --max-bytes" };
    delete error.vault_path;
    if (encode(error).byteLength > maxBytes) delete error.project_name;
    buf = encode(error);
  }
  writeSync(1, buf);
  process.exitCode = out.status === "READY" ? 0 : 2;
}

async function withQuiet(fn) {
  const methods = ["log", "warn", "info", "debug", "error"];
  const diagnostic = console.error.bind(console);
  const saved = {};
  for (const method of methods) {
    saved[method] = console[method];
    console[method] = diagnostic;
  }
  try {
    return await fn();
  } finally {
    for (const method of methods) console[method] = saved[method];
  }
}

async function loadQmd() {
  try {
    return await import("@tobilu/qmd");
  } catch {
    throw issue("ERROR", "MISSING_DEPENDENCY", "npm ci --prefix tools/memory");
  }
}

function memoryPaths(rootAbs) {
  const cvg = path.join(rootAbs, ".cvg");
  const memory = path.join(cvg, "memory");
  const cache = path.join(memory, "cache");
  return {
    cvg,
    memory,
    cache,
    notes: path.join(activeBinding.vault_path, "notes"),
    indexMd: path.join(activeBinding.vault_path, "INDEX.md"),
    manifest: path.join(memory, "sources.json"),
    sqlite: path.join(cache, "index.sqlite"),
    obsidian: path.join(activeBinding.vault_path, ".obsidian"),
    obsidianApp: path.join(activeBinding.vault_path, ".obsidian", "app.json"),
    ignore: path.join(cvg, ".gitignore"),
  };
}

async function guardLayout(rootAbs, { requireManifest = false } = {}) {
  const p = memoryPaths(rootAbs);
  for (const abs of [p.cvg, p.memory, p.cache, p.manifest, p.sqlite, `${p.sqlite}-wal`, `${p.sqlite}-shm`, p.ignore]) {
    await rejectSymlink(rootAbs, abs);
  }
  for (const abs of [p.indexMd, p.notes, p.obsidian, p.obsidianApp]) {
    await rejectSymlink(activeBinding.vault_path, abs);
  }
  if (requireManifest) {
    const st = await lstatOrNull(p.manifest);
    if (!st) throw issue("UNINITIALIZED", "UNINITIALIZED", "memory is not initialized");
    if (!st.isFile()) throw issue("ERROR", "MANIFEST", "invalid sources manifest");
    if (!(await lstatOrNull(p.sqlite))?.isFile()) {
      throw issue("UNINITIALIZED", "UNINITIALIZED", "search index missing; run init");
    }
  }
}

function normalizeRepoPath(input) {
  if (typeof input !== "string" || input.length === 0) {
    throw issue("ERROR", "PATH", "path outside root");
  }
  if (input.includes("\0") || input.includes("://")) {
    throw issue("ERROR", "PATH", "path outside root");
  }
  const posix = input.replaceAll("\\", "/");
  if (posix.startsWith("/") || posix.startsWith("~")) {
    throw issue("ERROR", "PATH", "path outside root");
  }
  const parts = [];
  for (const part of posix.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") throw issue("ERROR", "PATH", "path outside root");
    parts.push(part);
  }
  if (parts.length === 0) throw issue("ERROR", "PATH", "path outside root");
  return parts.join("/");
}

function blockedRel(relPosix) {
  const parts = relPosix.split("/");
  for (const part of parts) {
    if (BLOCKED_DIRS.has(part.toLowerCase())) return true;
  }
  const base = parts[parts.length - 1];
  if (base === "TEMPLATE.md") return true;
  return false;
}

async function hashFile(abs) {
  const buf = await readFile(abs);
  return {
    sha256: createHash("sha256").update(buf).digest("hex"),
    bytes: buf.byteLength,
    buf,
  };
}

async function collectFile(rootAbs, relPosix, out) {
  if (blockedRel(relPosix)) return;
  const abs = absFromRel(rootAbs, relPosix);
  if (repoRel(rootAbs, abs) !== relPosix) return;
  const st = await lstatOrNull(abs);
  if (!st || st.isSymbolicLink() || !st.isFile()) return;
  if (st.size > MAX_FILE_BYTES) return;
  await inspectInside(rootAbs, abs);
  const hashed = await hashFile(abs);
  if (hashed.bytes > MAX_FILE_BYTES) return;
  if (!hashed.buf.toString("utf8").trim()) return;
  out.set(relPosix, { path: relPosix, sha256: hashed.sha256, bytes: hashed.bytes });
}

async function walkMd(rootAbs, dirAbs, relBase, out) {
  const st = await lstatOrNull(dirAbs);
  if (!st || st.isSymbolicLink() || !st.isDirectory()) return;
  await inspectInside(rootAbs, dirAbs);
  let entries;
  try {
    entries = await readdir(dirAbs, { withFileTypes: true });
  } catch {
    return;
  }
  for (const ent of entries) {
    if (ent.isSymbolicLink()) continue;
    if (BLOCKED_DIRS.has(ent.name.toLowerCase())) continue;
    const rel = posixJoin(relBase, ent.name);
    const abs = path.join(dirAbs, ent.name);
    if (ent.isDirectory()) {
      if (ent.name.startsWith(".")) continue;
      await walkMd(rootAbs, abs, rel, out);
      continue;
    }
    if (!ent.isFile()) continue;
    if (!ent.name.endsWith(".md") || ent.name.startsWith(".")) continue;
    await collectFile(rootAbs, rel, out);
  }
}

async function inventory(rootAbs) {
  const out = new Map();
  for (const spec of SOURCE_SPECS) {
    if (spec.kind === "files") {
      const dirRel = spec.rel;
      if (dirRel) {
        const dirAbs = absFromRel(rootAbs, dirRel);
        const st = await lstatOrNull(dirAbs);
        if (!st || st.isSymbolicLink() || !st.isDirectory()) continue;
      }
      for (const name of spec.files) {
        const rel = posixJoin(dirRel, name);
        await collectFile(rootAbs, rel, out);
      }
      continue;
    }
    const dirAbs = spec.rel ? absFromRel(rootAbs, spec.rel) : rootAbs;
    await walkMd(rootAbs, dirAbs, spec.rel, out);
  }
  const notes = new Map();
  await walkMd(activeBinding.vault_path, path.join(activeBinding.vault_path, "notes"), "notes", notes);
  for (const note of notes.values()) {
    const rel = `vault/${note.path}`;
    out.set(rel, { ...note, path: rel });
  }
  return [...out.values()].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function sourcesEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i += 1) {
    if (a[i].path !== b[i].path || a[i].sha256 !== b[i].sha256 || a[i].bytes !== b[i].bytes) {
      return false;
    }
  }
  return true;
}

function staleDiff(manifestSources, live) {
  const before = new Map(manifestSources.map((s) => [s.path, s]));
  const after = new Map(live.map((s) => [s.path, s]));
  const added = [];
  const removed = [];
  const changed = [];
  for (const [p, src] of after) {
    const prev = before.get(p);
    if (!prev) added.push(p);
    else if (prev.sha256 !== src.sha256 || prev.bytes !== src.bytes) changed.push(p);
  }
  for (const p of before.keys()) {
    if (!after.has(p)) removed.push(p);
  }
  added.sort();
  removed.sort();
  changed.sort();
  return { added, removed, changed };
}

function isStale(diff) {
  return diff.added.length > 0 || diff.removed.length > 0 || diff.changed.length > 0;
}

function readManifestSync(abs) {
  let raw;
  try {
    raw = readFileSync(abs, "utf8");
  } catch (err) {
    if (err && err.code === "ENOENT") throw issue("UNINITIALIZED", "UNINITIALIZED", "memory is not initialized");
    throw issue("ERROR", "MANIFEST", "invalid sources manifest");
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    throw issue("ERROR", "MANIFEST", "invalid sources manifest");
  }
  if (!data || data.schema !== SCHEMA || !Array.isArray(data.sources)) {
    throw issue("ERROR", "MANIFEST", "invalid sources manifest");
  }
  if (data.project_id !== activeBinding.project_id) {
    throw issue("STALE", "INDEX_IDENTITY", "index binding changed; run refresh");
  }
  const sources = [];
  for (const src of data.sources) {
    if (!src || typeof src.path !== "string" || typeof src.sha256 !== "string") {
      throw issue("ERROR", "MANIFEST", "invalid sources manifest");
    }
    const bytes = src.bytes;
    if (typeof bytes !== "number" || !Number.isFinite(bytes) || bytes < 0) {
      throw issue("ERROR", "MANIFEST", "invalid sources manifest");
    }
    sources.push({ path: src.path, sha256: src.sha256, bytes });
  }
  return { sources, index_sha256: typeof data.index_sha256 === "string" ? data.index_sha256 : null };
}

async function atomicWrite(rootAbs, abs, data) {
  await inspectInside(rootAbs, path.dirname(abs), { create: true });
  const st = await lstatOrNull(abs);
  if (st?.isSymbolicLink()) throw issue("ERROR", "SYMLINK", "symlink path rejected");
  const tmp = `${abs}.tmp-${randomUUID()}`;
  try {
    await writeFile(tmp, data, { flag: "wx", mode: 0o600 });
    await rename(tmp, abs);
  } finally {
    await rm(tmp, { force: true });
  }
}

function indexLink(rootAbs, repoRelPath) {
  if (repoRelPath.startsWith("vault/")) return encodeURI(repoRelPath.slice(6)).replaceAll("#", "%23");
  return pathToFileURL(absFromRel(rootAbs, repoRelPath)).href;
}

function renderIndex(rootAbs, sources) {
  const lines = [
    `# ${activeBinding.project_name} — Converge memory`,
    "",
    "Mapa de fontes do repositório, não de fatos automaticamente validados. Preserve as fontes e atualize com `cvg memory refresh --root <raiz-do-projeto>`.",
    "",
    "Notas humanas ficam em `notes/`. A busca é lexical e local (sem LLM, sem rede).",
    "",
    `Projeto: \`${activeBinding.project_root}\`. Identidade: \`${activeBinding.project_id}\`. Este vault não agrega outros projetos.`,
    "",
    "## Fontes",
    "",
  ];
  if (sources.length === 0) {
    lines.push("- (nenhuma fonte autorizada encontrada)");
  } else {
    for (const src of sources) {
      lines.push(`- [${src.path.replaceAll("[", "\\[").replaceAll("]", "\\]")}](${indexLink(rootAbs, src.path)})`);
    }
  }
  lines.push("");
  return `${lines.join("\n")}`;
}

function sha256Text(text) {
  return createHash("sha256").update(text).digest("hex");
}

async function maybeWriteIndex(rootAbs, sources, { forceIfOurs, existingHash }) {
  const p = memoryPaths(rootAbs);
  const body = renderIndex(rootAbs, sources);
  const nextHash = sha256Text(body);
  const st = await lstatOrNull(p.indexMd);
  if (!st) {
    await atomicWrite(activeBinding.vault_path, p.indexMd, body);
    return nextHash;
  }
  if (st.isSymbolicLink()) throw issue("ERROR", "SYMLINK", "symlink path rejected");
  if (!forceIfOurs) return existingHash;
  if (existingHash && existingHash === sha256Text(await readFile(p.indexMd))) {
    await atomicWrite(activeBinding.vault_path, p.indexMd, body);
    return nextHash;
  }
  return existingHash;
}

async function collectionConfig(rootAbs, sources) {
  const collections = {};
  for (const src of sources) {
    const { abs } = await locateSource(rootAbs, activeBinding, src.path);
    const name = `source_${sha256Text(src.path).slice(0, 24)}`;
    const pattern = path.basename(abs)
      .replace(/([\\*?[\]{}()!+@])/g, "\\$1")
      .replaceAll(",", "[,]")
      .replaceAll(" ", "[ ]");
    collections[name] = { path: path.dirname(abs), pattern };
  }
  return collections;
}

async function openStore(rootAbs, collections) {
  const p = memoryPaths(rootAbs);
  await inspectInside(rootAbs, p.cache, { create: true });
  await rejectSymlink(rootAbs, p.sqlite);
  const qmd = await loadQmd();
  return withQuiet(() =>
    qmd.createStore({
      dbPath: p.sqlite,
      config: { collections },
    }),
  );
}

async function reindex(rootAbs, sources) {
  const collections = await collectionConfig(rootAbs, sources);
  const store = await openStore(rootAbs, collections);
  try {
    const listed = await withQuiet(() => store.listCollections());
    const wanted = new Set(Object.keys(collections));
    for (const col of listed) {
      if (!wanted.has(col.name)) {
        await withQuiet(() => store.removeCollection(col.name));
      }
    }
    const update = await withQuiet(() => store.update());
    if (update.skipped > 0) throw issue("ERROR", "INDEX", "QMD skipped a source; index not published");
  } finally {
    await withQuiet(() => store.close());
  }
}

async function writeManifest(rootAbs, sources, indexHash) {
  const p = memoryPaths(rootAbs);
  const body = `${JSON.stringify({
    schema: SCHEMA,
    project_id: activeBinding.project_id,
    sources,
    index_sha256: indexHash || null,
  })}\n`;
  await atomicWrite(rootAbs, p.manifest, body);
}

async function ensureReady(rootAbs, { rewriteIndex }) {
  const p = memoryPaths(rootAbs);
  await inspectInside(rootAbs, p.memory, { create: true });
  await inspectInside(rootAbs, p.cache, { create: true });
  const ignore = (await lstatOrNull(p.ignore)) ? await readFile(p.ignore, "utf8") : "";
  const missing = ["memory/cache/", "memory/vault.json", "memory/sources.json", "memory/migration-backup/"].filter(
    (rule) => !ignore.split(/\r?\n/).includes(rule),
  );
  if (missing.length) {
    await atomicWrite(rootAbs, p.ignore, `${ignore}${ignore && !ignore.endsWith("\n") ? "\n" : ""}${missing.join("\n")}\n`);
  }
  const before = await inventory(rootAbs);
  if (!before.length) throw issue("ERROR", "NO_SOURCES", "no eligible Markdown sources");
  const existing = await lstatOrNull(p.manifest);
  let previousHash = null;
  if (existing && !existing.isSymbolicLink()) {
    try {
      previousHash = readManifestSync(p.manifest).index_sha256;
    } catch {
      previousHash = null;
    }
  }
  if (rewriteIndex) {
    previousHash = await maybeWriteIndex(rootAbs, before, {
      forceIfOurs: true,
      existingHash: previousHash,
    });
  } else {
    previousHash = await maybeWriteIndex(rootAbs, before, {
      forceIfOurs: false,
      existingHash: previousHash,
    });
  }
  await rm(p.manifest, { force: true });
  await reindex(rootAbs, before);
  const after = await inventory(rootAbs);
  if (rewriteIndex) {
    previousHash = await maybeWriteIndex(rootAbs, after, {
      forceIfOurs: true,
      existingHash: previousHash,
    });
  }
  if (!sourcesEqual(before, after)) {
    throw issue("STALE", "STALE_SOURCES", "sources changed during reindex");
  }
  await writeManifest(rootAbs, after, previousHash);
  return after;
}

async function liveVersusManifest(rootAbs) {
  const p = memoryPaths(rootAbs);
  const manifest = readManifestSync(p.manifest);
  const live = await inventory(rootAbs);
  const diff = staleDiff(manifest.sources, live);
  if (isStale(diff)) {
    const err = issue("STALE", "STALE_SOURCES", "sources changed; run refresh");
    err.stale = diff;
    err.sources = live;
    throw err;
  }
  return { manifest, live };
}

function makeSnippet(text, query) {
  const lines = text.split("\n");
  const terms = String(query)
    .toLowerCase()
    .split(/\s+/)
    .map((t) => t.replace(/^-+/, "").replaceAll('"', ""))
    .filter((t) => t.length > 0);
  let best = 0;
  let bestScore = -1;
  for (let i = 0; i < lines.length; i += 1) {
    const lower = lines[i].toLowerCase();
    let score = 0;
    for (const term of terms) {
      if (term && lower.includes(term)) score += 1;
    }
    if (score > bestScore) {
      bestScore = score;
      best = i;
    }
  }
  const start = Math.max(0, best - 1);
  const end = Math.min(lines.length, best + 3);
  let snippet = lines.slice(start, end).join("\n");
  const maxChars = 400;
  if (snippet.length > maxChars) snippet = `${snippet.slice(0, maxChars - 1)}…`;
  return { start_line: start + 1, end_line: Math.max(start + 1, end), snippet };
}

function hitRepoPath(hit, collections, rootAbs) {
  const name = hit.collectionName;
  const col = collections[name];
  if (!col || typeof hit.filepath !== "string") return null;
  const prefix = `qmd://${name}/`;
  if (!hit.filepath.startsWith(prefix)) return null;
  const relInCol = hit.filepath.slice(prefix.length);
  const abs = path.resolve(col.path, relInCol);
  const rel = repoRel(rootAbs, abs);
  if (rel !== null) return rel;
  const note = repoRel(activeBinding.vault_path, abs);
  return note === null ? null : `vault/${note}`;
}

async function runSearch(rootAbs, query, limit) {
  const { live } = await liveVersusManifest(rootAbs);
  const byPath = new Map(live.map((s) => [s.path, s]));
  const collections = await collectionConfig(rootAbs, live);
  const names = Object.keys(collections);
  if (names.length === 0) return [];
  const store = await openStore(rootAbs, collections);
  let hits;
  try {
    hits = await withQuiet(() => store.searchLex(query, { limit: 10, collection: names }));
  } finally {
    await withQuiet(() => store.close());
  }
  await liveVersusManifest(rootAbs);
  const seen = new Set();
  const results = [];
  for (const hit of Array.isArray(hits) ? hits : []) {
    const rel = hitRepoPath(hit, collections, rootAbs);
    if (!rel || seen.has(rel)) continue;
    const meta = byPath.get(rel);
    if (!meta) continue;
    seen.add(rel);
    const { root: sourceRoot, abs } = await locateSource(rootAbs, activeBinding, rel);
    await inspectInside(sourceRoot, abs);
    const st = await lstatOrNull(abs);
    if (!st || st.isSymbolicLink() || !st.isFile()) continue;
    const buf = await readFile(abs);
    if (sha256Text(buf) !== meta.sha256) throw issue("STALE", "STALE_SOURCES", "source changed during read; run refresh");
    const snip = makeSnippet(buf.toString("utf8"), query);
    results.push({
      path: rel,
      sha256: meta.sha256,
      start_line: snip.start_line,
      end_line: snip.end_line,
      snippet: snip.snippet,
      score: typeof hit.score === "number" ? hit.score : 0,
    });
    if (results.length >= limit) break;
  }
  return results;
}

async function runRead(rootAbs, rel, from, lineCount) {
  const { live } = await liveVersusManifest(rootAbs);
  const meta = live.find((s) => s.path === rel);
  if (!meta) throw issue("ERROR", "NOT_INDEXED", "not an indexed source");
  const { root: sourceRoot, abs } = await locateSource(rootAbs, activeBinding, rel);
  await inspectInside(sourceRoot, abs);
  const st = await lstatOrNull(abs);
  if (!st || st.isSymbolicLink() || !st.isFile()) {
    throw issue("ERROR", "NOT_INDEXED", "not an indexed source");
  }
  const buf = await readFile(abs);
  if (sha256Text(buf) !== meta.sha256) throw issue("STALE", "STALE_SOURCES", "source changed during read; run refresh");
  const lines = buf.toString("utf8").split("\n");
  const start = from;
  const slice = lines.slice(start - 1, start - 1 + lineCount);
  return {
    path: rel,
    sha256: meta.sha256,
    start_line: start,
    end_line: start - 1 + slice.length,
    text: slice.join("\n"),
  };
}

function gitToplevel() {
  try {
    const out = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 5000,
    }).trim();
    return out || undefined;
  } catch {
    return undefined;
  }
}

async function realRoot(rootArg) {
  if (!rootArg) throw issue("ERROR", "USAGE", "missing --root");
  const resolved = path.resolve(rootArg);
  try {
    lstatSync(resolved);
  } catch {
    throw issue("ERROR", "PATH", "root not found");
  }
  let real;
  try {
    real = await realpath(resolved);
  } catch {
    throw issue("ERROR", "PATH", "root not found");
  }
  let st;
  try {
    st = lstatSync(real);
  } catch {
    throw issue("ERROR", "PATH", "root not found");
  }
  if (!st.isDirectory() || st.isSymbolicLink()) throw issue("ERROR", "PATH", "root not found");
  return real;
}

async function main() {
  let opts;
  try {
    opts = parseCli(process.argv.slice(2));
  } catch (err) {
    writeJson(
      {
        status: "ERROR",
        action: "error",
        truncated: false,
        code: err instanceof BrainIssue ? err.code : "USAGE",
        message: safeMessage(err),
      },
      6000,
    );
    return;
  }
  const maxBytes = opts.maxBytes;
  const action = opts.action;
  try {
    if (!action || !ACTIONS.has(action)) {
      throw issue("ERROR", "USAGE", "invalid arguments");
    }
    const rootAbs = await realRoot(opts.root ?? gitToplevel());
    if (!["init", "migrate"].includes(action) && !(await lstatOrNull(path.join(rootAbs, ".cvg/memory/vault.json")))) {
      throw issue("UNINITIALIZED", "VAULT", "named vault not bound; run init or migrate");
    }
    try {
      activeBinding = await configureVault(rootAbs, { vault: opts.vault, action });
    } catch (err) {
      throw issue("ERROR", "VAULT", err.message);
    }
    if (action === "init" || action === "migrate") {
      await guardLayout(rootAbs, { requireManifest: false });
      const sources = await ensureReady(rootAbs, { rewriteIndex: action === "migrate" });
      writeJson(
        {
          status: "READY",
          action,
          truncated: false,
          source_count: sources.length,
          indexed_bytes: sources.reduce((sum, source) => sum + source.bytes, 0),
        },
        maxBytes,
      );
      return;
    }
    await guardLayout(rootAbs, { requireManifest: true });
    if (action === "refresh") {
      const sources = await ensureReady(rootAbs, { rewriteIndex: true });
      writeJson(
        {
          status: "READY",
          action,
          truncated: false,
          source_count: sources.length,
          indexed_bytes: sources.reduce((sum, source) => sum + source.bytes, 0),
        },
        maxBytes,
      );
      return;
    }
    if (action === "status") {
      const { live } = await liveVersusManifest(rootAbs);
      writeJson(
        {
          status: "READY",
          action,
          truncated: false,
          source_count: live.length,
          indexed_bytes: live.reduce((sum, source) => sum + source.bytes, 0),
        },
        maxBytes,
      );
      return;
    }
    if (action === "search") {
      const query = opts.rest.join(" ").trim();
      if (!query) throw issue("ERROR", "USAGE", "invalid arguments");
      const results = await runSearch(rootAbs, query, opts.limit);
      writeJson({ status: "READY", action, truncated: false, results }, maxBytes);
      return;
    }
    if (action === "read") {
      const rel = normalizeRepoPath(opts.rest[0] || "");
      const payload = await runRead(rootAbs, rel, opts.from, opts.lines);
      writeJson({ status: "READY", action, truncated: false, ...payload }, maxBytes);
    }
  } catch (err) {
    const status = err instanceof BrainIssue ? err.status : "ERROR";
    const payload = {
      status,
      action: ACTIONS.has(action) ? action : "error",
      truncated: false,
      code: err instanceof BrainIssue ? err.code : "IO",
      message: safeMessage(err),
    };
    if (err && err.stale) payload.stale = err.stale;
    if (Array.isArray(err?.sources)) {
      payload.source_count = err.sources.length;
    }
    writeJson(payload, maxBytes);
  }
}

await main();
