import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { copyFile, lstat, mkdir, readdir, readFile, realpath, rename, rm, rmdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const SCHEMA = "ConvergeMemoryBinding/v1";
const LEGACY_SCHEMA = "DarkfactoryBrainBinding/v1";
const NATIVE_OWNER = ".converge-project.json";
const LEGACY_OWNER = ".darkfactory-project.json";
const INIT_ACTIONS = new Set(["init", "migrate"]);
const VALIDATE_ACTIONS = new Set(["status", "search", "read", "refresh"]);
const HISTORICAL_DIRS = ["decisions", "loops", "queue", "refs"];
const HISTORICAL_SKIP = new Set([
  "STATE.md",
  "INVENTORY.md",
  "TEMPLATE.md",
  "vault.json",
  "sources.json",
  ".gitkeep",
]);

function fail(message) {
  throw new Error(message);
}

function trap(err) {
  if (err instanceof Error && typeof err.code === "string") fail("vault operation failed");
  throw err;
}

function projectId(rootAbs) {
  return createHash("sha256").update(rootAbs).digest("hex").slice(0, 16);
}

function makeBinding(rootAbs, vaultPath) {
  return {
    schema: SCHEMA,
    project_id: projectId(rootAbs),
    project_name: path.basename(vaultPath),
    project_root: rootAbs,
    vault_path: vaultPath,
  };
}

function bindingBody(binding) {
  return `${JSON.stringify({
    schema: binding.schema,
    project_id: binding.project_id,
    project_name: binding.project_name,
    project_root: binding.project_root,
    vault_path: binding.vault_path,
  })}\n`;
}

function bindingsEqual(a, b) {
  return (
    a.schema === b.schema &&
    a.project_id === b.project_id &&
    a.project_name === b.project_name &&
    a.project_root === b.project_root &&
    a.vault_path === b.vault_path
  );
}

function identityFieldsEqual(a, b) {
  return (
    a.project_id === b.project_id &&
    a.project_name === b.project_name &&
    a.project_root === b.project_root &&
    a.vault_path === b.vault_path
  );
}

async function lstatOrNull(abs) {
  try {
    return await lstat(abs);
  } catch (err) {
    if (err && err.code === "ENOENT") return null;
    throw err;
  }
}

function parseBinding(raw, label, schema = SCHEMA) {
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    fail(`invalid ${label}`);
  }
  if (!data || data.schema !== schema) fail(`invalid ${label}`);
  for (const key of ["project_id", "project_name", "project_root", "vault_path"]) {
    if (typeof data[key] !== "string" || data[key].length === 0) fail(`invalid ${label}`);
  }
  if (!path.isAbsolute(data.project_root) || !path.isAbsolute(data.vault_path)) fail(`invalid ${label}`);
  return {
    schema,
    project_id: data.project_id,
    project_name: data.project_name,
    project_root: path.resolve(data.project_root),
    vault_path: path.resolve(data.vault_path),
  };
}

async function readBindingAt(abs, label, schema = SCHEMA) {
  const st = await lstatOrNull(abs);
  if (!st) return null;
  if (st.isSymbolicLink()) fail("symlink path rejected");
  if (!st.isFile()) fail(`invalid ${label}`);
  return parseBinding(await readFile(abs, "utf8"), label, schema);
}

function repoMemory(rootAbs) {
  const cvg = path.join(rootAbs, ".cvg");
  const memory = path.join(cvg, "memory");
  return {
    cvg,
    memory,
    vaultJson: path.join(memory, "vault.json"),
    manifest: path.join(memory, "sources.json"),
    cache: path.join(memory, "cache"),
    backup: path.join(memory, "migration-backup"),
    obsidianBackup: path.join(memory, "migration-backup", "obsidian"),
  };
}

function legacyRepoBrain(rootAbs) {
  const dark = path.join(rootAbs, ".darkfactory");
  const brain = path.join(dark, "brain");
  return {
    dark,
    brain,
    vaultJson: path.join(brain, "vault.json"),
    notes: path.join(brain, "notes"),
    indexMd: path.join(brain, "INDEX.md"),
    manifest: path.join(brain, "sources.json"),
    obsidian: path.join(dark, ".obsidian"),
    decisions: path.join(brain, "decisions"),
    loops: path.join(brain, "loops"),
    queue: path.join(brain, "queue"),
    refs: path.join(brain, "refs"),
  };
}

async function rejectIfSymlink(abs) {
  const st = await lstatOrNull(abs);
  if (st?.isSymbolicLink()) fail("symlink path rejected");
  return st;
}

function isContained(inner, outer) {
  const rel = path.relative(path.resolve(outer), path.resolve(inner));
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

async function canonicalizeVaultPath(input) {
  if (typeof input !== "string" || input.length === 0 || input.includes("\0")) fail("invalid vault path");
  const abs = path.resolve(input);
  let cur = abs;
  const missing = [];
  for (;;) {
    const st = await lstatOrNull(cur);
    if (st) {
      if (st.isSymbolicLink() && missing.length === 0) fail("vault path is a symlink");
      let real;
      try {
        real = await realpath(cur);
      } catch {
        fail("vault path is not reachable");
      }
      return missing.length === 0 ? real : path.resolve(real, ...missing.reverse());
    }
    const parent = path.dirname(cur);
    if (parent === cur) fail("vault path is not reachable");
    missing.push(path.basename(cur));
    cur = parent;
  }
}

async function assertVaultLocation(rootAbs, vaultPath) {
  if (isContained(vaultPath, rootAbs)) fail("vault path is inside the project repository");
  if (isContained(rootAbs, vaultPath)) fail("vault path overlaps the project repository");
  let dir = path.dirname(vaultPath);
  for (;;) {
    if (await lstatOrNull(path.join(dir, ".obsidian"))) {
      fail("vault is nested inside another Obsidian vault");
    }
    if (dir === path.dirname(dir)) break;
    dir = path.dirname(dir);
  }
}

async function hasLegacyBrain(rootAbs) {
  const p = legacyRepoBrain(rootAbs);
  if (await lstatOrNull(p.indexMd)) return true;
  if (await lstatOrNull(p.obsidian)) return true;
  const notes = await lstatOrNull(p.notes);
  if (!notes) return false;
  if (notes.isSymbolicLink()) fail("symlink path rejected");
  if (notes.isFile()) return true;
  if (!notes.isDirectory()) return false;
  return (await readdir(p.notes)).length > 0;
}

async function hasLegacyOwnerOnly(vaultPath) {
  if (!(await lstatOrNull(vaultPath))) return false;
  const native = await readBindingAt(path.join(vaultPath, NATIVE_OWNER), "vault ownership marker");
  if (native) return false;
  const legacy = await readBindingAt(path.join(vaultPath, LEGACY_OWNER), "legacy vault ownership marker", LEGACY_SCHEMA);
  return Boolean(legacy);
}

async function writeRepoBinding(abs, binding) {
  if ((await lstatOrNull(abs))?.isSymbolicLink()) fail("symlink path rejected");
  await mkdir(path.dirname(abs), { recursive: true, mode: 0o700 });
  const tmp = `${abs}.tmp-${randomUUID()}`;
  try {
    await writeFile(tmp, bindingBody(binding), { flag: "wx", mode: 0o600 });
    await rename(tmp, abs);
  } finally {
    await rm(tmp, { force: true });
  }
}

async function claimOwnerMarker(vaultPath, binding) {
  const abs = path.join(vaultPath, NATIVE_OWNER);
  const existing = await readBindingAt(abs, "vault ownership marker");
  if (existing) {
    if (
      existing.project_id !== binding.project_id ||
      existing.project_root !== binding.project_root ||
      existing.vault_path !== vaultPath
    ) {
      fail("vault is bound to a different project");
    }
    return existing;
  }
  try {
    await writeFile(abs, bindingBody(binding), { flag: "wx", mode: 0o600 });
  } catch (err) {
    if (!err || err.code !== "EEXIST") fail("cannot write vault ownership marker");
    const raced = await readBindingAt(abs, "vault ownership marker");
    if (
      !raced ||
      raced.project_id !== binding.project_id ||
      raced.project_root !== binding.project_root ||
      raced.vault_path !== vaultPath
    ) {
      fail("vault is bound to a different project");
    }
    return raced;
  }
  return binding;
}

async function ensureDestDir(vaultPath) {
  const st = await lstatOrNull(vaultPath);
  if (!st) {
    await mkdir(vaultPath, { recursive: true, mode: 0o700 });
  }
  const created = await lstatOrNull(vaultPath);
  if (!created || created.isSymbolicLink()) fail("vault path is a symlink");
  if (!created.isDirectory()) fail("vault path is not a directory");
}

async function destOccupancy(vaultPath, wantedId, { allowLegacy = false, rootAbs } = {}) {
  const marker = await readBindingAt(path.join(vaultPath, NATIVE_OWNER), "vault ownership marker");
  if (marker) {
    if (marker.project_id !== wantedId) fail("vault is bound to a different project");
    if (marker.vault_path !== vaultPath) fail("vault is bound to a different project");
    if (rootAbs && marker.project_root !== rootAbs) fail("vault is bound to a different project");
    return "ours";
  }
  if (allowLegacy) {
    const legacy = await readBindingAt(
      path.join(vaultPath, LEGACY_OWNER),
      "legacy vault ownership marker",
      LEGACY_SCHEMA,
    );
    if (legacy) {
      if (legacy.project_id !== wantedId) fail("vault is bound to a different project");
      if (legacy.vault_path !== vaultPath) fail("vault is bound to a different project");
      if (rootAbs && legacy.project_root !== rootAbs) fail("vault is bound to a different project");
      return "ours";
    }
  }
  const ents = await readdir(vaultPath);
  if (ents.length === 0) return "empty";
  fail("refusing to take over a non-empty unmarked vault");
}

async function ensureSkeleton(vaultPath) {
  const ignore = path.join(vaultPath, ".gitignore");
  const obsidian = path.join(vaultPath, ".obsidian");
  const app = path.join(obsidian, "app.json");
  const notes = path.join(vaultPath, "notes");

  if ((await lstatOrNull(obsidian))?.isSymbolicLink()) fail("symlink path rejected");
  await mkdir(obsidian, { recursive: true, mode: 0o700 });
  if ((await lstatOrNull(obsidian))?.isSymbolicLink()) fail("symlink path rejected");

  const appSt = await lstatOrNull(app);
  if (appSt?.isSymbolicLink()) fail("symlink path rejected");
  if (!appSt) {
    try {
      await writeFile(app, `${JSON.stringify({ alwaysUpdateLinks: true })}\n`, { flag: "wx", mode: 0o600 });
    } catch (err) {
      if (!err || err.code !== "EEXIST") fail("cannot write vault app.json");
    }
  }

  const ignSt = await lstatOrNull(ignore);
  if (ignSt?.isSymbolicLink()) fail("symlink path rejected");
  if (!ignSt) {
    try {
      await writeFile(ignore, ".obsidian/\n", { flag: "wx", mode: 0o600 });
    } catch (err) {
      if (!err || err.code !== "EEXIST") fail("cannot write vault gitignore");
    }
  } else if (ignSt.isFile()) {
    const text = await readFile(ignore, "utf8");
    if (!text.split(/\r?\n/).includes(".obsidian/")) {
      const next = `${text}${text.length === 0 || text.endsWith("\n") ? "" : "\n"}.obsidian/\n`;
      await writeFile(ignore, next, { mode: 0o600 });
    }
  }

  const notesSt = await lstatOrNull(notes);
  if (!notesSt) await mkdir(notes, { mode: 0o700 });
  else if (notesSt.isSymbolicLink()) fail("symlink path rejected");
  else if (!notesSt.isDirectory()) fail("vault notes path is not a directory");
}

async function hashFile(abs) {
  return createHash("sha256").update(await readFile(abs)).digest("hex");
}

async function collectFiles(dirAbs, relBase, out) {
  const st = await rejectIfSymlink(dirAbs);
  if (!st) return;
  if (!st.isDirectory()) fail("migration conflict: destination already has different content");
  const ents = await readdir(dirAbs, { withFileTypes: true });
  for (const ent of ents) {
    const rel = relBase ? `${relBase}/${ent.name}` : ent.name;
    const abs = path.join(dirAbs, ent.name);
    if (ent.isSymbolicLink()) fail("symlink path rejected");
    if (ent.isDirectory()) await collectFiles(abs, rel, out);
    else if (ent.isFile()) out.push({ rel, abs });
    else fail("unsupported file type in migration");
  }
}

async function preflightFile(fromAbs, toAbs) {
  const src = await rejectIfSymlink(fromAbs);
  if (!src) return false;
  if (!src.isFile()) fail("migration conflict: destination already has different content");
  const dst = await rejectIfSymlink(toAbs);
  if (!dst) return true;
  if (!dst.isFile()) fail("migration conflict: destination already has different content");
  if ((await hashFile(fromAbs)) !== (await hashFile(toAbs))) {
    fail("migration conflict: destination already has different content");
  }
  return false;
}

async function copyExclusive(copies, destinationRoot) {
  for (const c of copies) {
    await walkNoSymlink(destinationRoot, path.dirname(c.to));
    await mkdir(path.dirname(c.to), { recursive: true, mode: 0o700 });
    if (await lstatOrNull(c.to)) fail("migration conflict: destination already has different content");
    await copyFile(c.from, c.to, fsConstants.COPYFILE_EXCL);
  }
}

async function isGeneratedIndex(indexAbs, manifestAbs) {
  const manSt = await rejectIfSymlink(manifestAbs);
  if (!manSt?.isFile()) return false;
  let man;
  try {
    man = JSON.parse(await readFile(manifestAbs, "utf8"));
  } catch {
    return false;
  }
  if (!man || typeof man.index_sha256 !== "string" || man.index_sha256.length === 0) return false;
  return (await hashFile(indexAbs)) === man.index_sha256;
}

async function migrateLegacy(rootAbs, vaultPath) {
  const p = legacyRepoBrain(rootAbs);
  const native = repoMemory(rootAbs);
  for (const abs of [p.dark, p.brain, p.notes, p.indexMd, p.obsidian, native.obsidianBackup, native.backup]) {
    await rejectIfSymlink(abs);
  }

  const jobs = [];
  if (await lstatOrNull(p.notes)) {
    jobs.push({ kind: "tree", from: p.notes, to: path.join(vaultPath, "notes") });
  }
  const indexSt = await rejectIfSymlink(p.indexMd);
  const generatedHash = indexSt?.isFile() && (await isGeneratedIndex(p.indexMd, p.manifest)) ? await hashFile(p.indexMd) : null;
  if (indexSt?.isFile() && !generatedHash) {
    jobs.push({ kind: "file", from: p.indexMd, to: path.join(vaultPath, "LEGACY-INDEX.md") });
  }
  if (await lstatOrNull(p.obsidian)) {
    jobs.push({ kind: "tree", from: p.obsidian, to: native.obsidianBackup });
  }

  const copies = [];
  const movedFiles = [];
  for (const job of jobs) {
    const destinationRoot = isContained(job.to, vaultPath) ? vaultPath : rootAbs;
    await walkNoSymlink(destinationRoot, job.to);
    if (job.kind === "file") {
      if (await preflightFile(job.from, job.to)) copies.push({ from: job.from, to: job.to });
      movedFiles.push({ from: job.from, to: job.to });
      continue;
    }
    const st = await rejectIfSymlink(job.from);
    if (!st) continue;
    if (!st.isDirectory()) fail("migration conflict: destination already has different content");
    const files = [];
    await collectFiles(job.from, "", files);
    for (const f of files) {
      const dest = path.join(job.to, ...f.rel.split("/"));
      await walkNoSymlink(destinationRoot, dest);
      if (await preflightFile(f.abs, dest)) copies.push({ from: f.abs, to: dest });
      movedFiles.push({ from: f.abs, to: dest });
    }
  }

  for (const c of copies) {
    await mkdir(path.dirname(c.to), { recursive: true, mode: 0o700 });
    if (await lstatOrNull(c.to)) fail("migration conflict: destination already has different content");
    await copyFile(c.from, c.to, fsConstants.COPYFILE_EXCL);
  }
  // Verify every preserved copy before removing any original. Never recursively
  // delete source trees: a concurrently added note must survive migration.
  for (const file of movedFiles) {
    if (await preflightFile(file.from, file.to)) fail("migration copy is missing");
  }
  if (generatedHash && (await hashFile(p.indexMd)) !== generatedHash) fail("index changed during migration");
  for (const file of movedFiles) await rm(file.from);
  if (generatedHash) await rm(p.indexMd);
  for (const job of jobs) {
    if (job.kind === "tree") await removeEmptyTree(job.from);
  }
}

async function backupLegacyMetadata(rootAbs, vaultPath) {
  const legacy = legacyRepoBrain(rootAbs);
  const native = repoMemory(rootAbs);
  await rejectIfSymlink(native.backup);
  const jobs = [];
  if (await lstatOrNull(legacy.vaultJson)) {
    jobs.push({ from: legacy.vaultJson, to: path.join(native.backup, "darkfactory-brain-vault.json") });
  }
  const ownerAbs = path.join(vaultPath, LEGACY_OWNER);
  if (await lstatOrNull(ownerAbs)) {
    jobs.push({ from: ownerAbs, to: path.join(native.backup, "darkfactory-project.json") });
  }
  if (jobs.length === 0) return;
  await walkNoSymlink(rootAbs, native.backup);
  const copies = [];
  for (const job of jobs) {
    await walkNoSymlink(rootAbs, job.to);
    if (await preflightFile(job.from, job.to)) copies.push(job);
  }
  if (copies.length) {
    await mkdir(native.backup, { recursive: true, mode: 0o700 });
    await copyExclusive(copies, rootAbs);
  }
  for (const job of jobs) {
    if (await preflightFile(job.from, job.to)) fail("migration copy is missing");
  }
}

async function copyHistoricalRecords(rootAbs) {
  const legacy = legacyRepoBrain(rootAbs);
  const destRoot = path.join(rootAbs, "cvg", "brain");
  await rejectIfSymlink(legacy.brain);
  await rejectIfSymlink(destRoot);
  if (!(await lstatOrNull(legacy.brain))) return;

  const copies = [];
  const preserved = [];
  for (const dir of HISTORICAL_DIRS) {
    const fromDir = path.join(legacy.brain, dir);
    const toDir = path.join(destRoot, dir);
    const st = await rejectIfSymlink(fromDir);
    if (!st) continue;
    if (!st.isDirectory()) fail("migration conflict: destination already has different content");
    await walkNoSymlink(rootAbs, toDir);
    const files = [];
    await collectFiles(fromDir, "", files);
    for (const f of files) {
      const base = path.posix.basename(f.rel);
      if (HISTORICAL_SKIP.has(base)) continue;
      const dest = path.join(toDir, ...f.rel.split("/"));
      await walkNoSymlink(rootAbs, dest);
      if (await preflightFile(f.abs, dest)) copies.push({ from: f.abs, to: dest });
      preserved.push({ from: f.abs, to: dest });
    }
  }

  if (copies.length) await copyExclusive(copies, rootAbs);
  for (const file of preserved) {
    if (await preflightFile(file.from, file.to)) fail("migration copy is missing");
  }
}

async function removeEmptyTree(dir) {
  const st = await lstatOrNull(dir);
  if (!st) return;
  if (!st.isDirectory()) return;
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) await removeEmptyTree(path.join(dir, entry.name));
  }
  await rmdir(dir);
}

async function verifyLegacyIdentity(rootAbs, vaultPath, legacyRepo, nativeExisting) {
  if (!legacyRepo) return;
  if (legacyRepo.project_id !== projectId(rootAbs) || legacyRepo.project_root !== rootAbs) {
    fail("vault binding does not match this repository");
  }
  if (legacyRepo.vault_path !== vaultPath) fail("--vault does not match the bound vault path");
  const owner = await readBindingAt(
    path.join(vaultPath, LEGACY_OWNER),
    "legacy vault ownership marker",
    LEGACY_SCHEMA,
  );
  if (!owner) {
    if (!nativeExisting) fail("legacy vault ownership marker missing");
    return;
  }
  if (!identityFieldsEqual(legacyRepo, owner) || owner.vault_path !== vaultPath) {
    fail("vault binding markers do not match");
  }
}

async function validateBinding(rootAbs, vaultOpt) {
  const p = repoMemory(rootAbs);
  await walkNoSymlink(rootAbs, p.vaultJson);
  const repo = await readBindingAt(p.vaultJson, "vault binding");
  if (!repo) fail("memory vault is not initialized; run init or migrate");
  if (repo.project_id !== projectId(rootAbs) || repo.project_root !== rootAbs) {
    fail("vault binding does not match this repository");
  }
  if (vaultOpt != null && String(vaultOpt).length > 0) {
    const wanted = await canonicalizeVaultPath(String(vaultOpt));
    if (wanted !== repo.vault_path) fail("--vault does not match the bound vault path");
  }
  const vaultPath = repo.vault_path;
  const st = await lstatOrNull(vaultPath);
  if (!st) fail("bound vault path is missing");
  if (st.isSymbolicLink()) fail("vault path is a symlink");
  if (!st.isDirectory()) fail("vault path is not a directory");
  if ((await realpath(vaultPath)) !== vaultPath) fail("bound vault location changed");
  const owner = await readBindingAt(path.join(vaultPath, NATIVE_OWNER), "vault ownership marker");
  if (!owner) fail("memory vault is not initialized; run init or migrate");
  if (!bindingsEqual(repo, owner) || owner.vault_path !== vaultPath) fail("vault binding markers do not match");
  await assertVaultLocation(rootAbs, vaultPath);
  return repo;
}

async function configureVaultInner(rootAbs, { vault, action } = {}) {
  if (typeof rootAbs !== "string" || !path.isAbsolute(rootAbs)) fail("project root must be an absolute path");
  const root = path.resolve(rootAbs);
  const rst = await lstatOrNull(root);
  if (!rst || rst.isSymbolicLink() || !rst.isDirectory()) fail("project root not found");

  if (VALIDATE_ACTIONS.has(action)) return await validateBinding(root, vault);
  if (!INIT_ACTIONS.has(action)) fail("unsupported vault action");

  const p = repoMemory(root);
  const legacy = legacyRepoBrain(root);
  for (const abs of [p.cvg, p.memory, p.vaultJson]) await rejectIfSymlink(abs);
  for (const abs of [legacy.dark, legacy.brain, legacy.vaultJson]) await rejectIfSymlink(abs);

  const existing = await readBindingAt(p.vaultJson, "vault binding");
  const legacyRepo = await readBindingAt(legacy.vaultJson, "legacy vault binding", LEGACY_SCHEMA);

  let vaultPath;
  if (existing) {
    if (existing.project_id !== projectId(root) || existing.project_root !== root) {
      fail("vault binding does not match this repository");
    }
    vaultPath = existing.vault_path;
    if (vault != null && String(vault).length > 0) {
      const wanted = await canonicalizeVaultPath(String(vault));
      if (wanted !== vaultPath) fail("--vault does not match the bound vault path");
    }
  } else if (action === "migrate" && legacyRepo) {
    if (legacyRepo.project_id !== projectId(root) || legacyRepo.project_root !== root) {
      fail("vault binding does not match this repository");
    }
    vaultPath = legacyRepo.vault_path;
    if (vault != null && String(vault).length > 0) {
      const wanted = await canonicalizeVaultPath(String(vault));
      if (wanted !== vaultPath) fail("--vault does not match the bound vault path");
    }
  } else if (vault != null && String(vault).length > 0) {
    vaultPath = await canonicalizeVaultPath(String(vault));
  } else {
    const home = os.homedir();
    if (!home) fail("cannot resolve home directory for default vault");
    vaultPath = await canonicalizeVaultPath(path.join(home, "SegundoCerebro", path.basename(root)));
  }

  if (action === "init" && !existing) {
    if (legacyRepo || (await hasLegacyBrain(root)) || (await hasLegacyOwnerOnly(vaultPath))) {
      fail("unmigrated darkfactory memory binding; run memory migrate");
    }
  }

  await assertVaultLocation(root, vaultPath);
  await ensureDestDir(vaultPath);
  await destOccupancy(vaultPath, projectId(root), {
    allowLegacy: action === "migrate",
    rootAbs: root,
  });

  const binding = makeBinding(root, vaultPath);
  if (existing && !bindingsEqual(existing, binding)) fail("cannot rebind vault to a different repository");
  if (action === "migrate") await verifyLegacyIdentity(root, vaultPath, legacyRepo, existing);

  if (action === "migrate") {
    await ensureSkeleton(vaultPath);
    await backupLegacyMetadata(root, vaultPath);
    await migrateLegacy(root, vaultPath);
    await copyHistoricalRecords(root);
    await claimOwnerMarker(vaultPath, binding);
    if (!existing) await writeRepoBinding(p.vaultJson, binding);
  } else {
    await claimOwnerMarker(vaultPath, binding);
    if (!existing) await writeRepoBinding(p.vaultJson, binding);
    await ensureSkeleton(vaultPath);
  }

  const repo = await readBindingAt(p.vaultJson, "vault binding");
  const owner = await readBindingAt(path.join(vaultPath, NATIVE_OWNER), "vault ownership marker");
  if (!repo || !owner || !bindingsEqual(repo, owner)) fail("vault binding markers do not match");
  return repo;
}

function normalizeRel(input) {
  if (typeof input !== "string" || input.length === 0) fail("path outside root");
  if (input.includes("\0") || input.includes("://")) fail("path outside root");
  const posix = input.replaceAll("\\", "/");
  if (posix.startsWith("/") || posix.startsWith("~")) fail("path outside root");
  const parts = [];
  for (const part of posix.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") fail("path outside root");
    parts.push(part);
  }
  if (parts.length === 0) fail("path outside root");
  return parts;
}

async function walkNoSymlink(root, abs) {
  const resolvedRoot = path.resolve(root);
  const resolvedAbs = path.resolve(abs);
  const rel = path.relative(resolvedRoot, resolvedAbs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) fail("path outside root");
  const rootSt = await lstatOrNull(resolvedRoot);
  if (rootSt?.isSymbolicLink()) fail("symlink path rejected");
  let cur = resolvedRoot;
  const parts = rel === "" ? [] : rel.split(path.sep).filter(Boolean);
  for (const part of parts) {
    cur = path.join(cur, part);
    const st = await lstatOrNull(cur);
    if (!st) return;
    if (st.isSymbolicLink()) fail("symlink path rejected");
  }
}

async function locateSourceInner(rootAbs, binding, rel) {
  if (typeof rootAbs !== "string" || !path.isAbsolute(rootAbs)) fail("project root must be an absolute path");
  const root = path.resolve(rootAbs);
  const parts = normalizeRel(rel);
  let base;
  let rest;
  if (parts[0] === "vault") {
    if (!binding || typeof binding.vault_path !== "string" || !path.isAbsolute(binding.vault_path)) {
      fail("memory vault is not initialized; run init or migrate");
    }
    base = path.resolve(binding.vault_path);
    rest = parts.slice(1);
  } else {
    base = root;
    rest = parts;
  }
  const abs = rest.length ? path.resolve(base, ...rest) : path.resolve(base);
  const relToBase = path.relative(base, abs);
  if (relToBase.startsWith("..") || path.isAbsolute(relToBase)) fail("path outside root");
  await walkNoSymlink(base, abs);
  return { root: base, abs };
}

export async function configureVault(rootAbs, opts = {}) {
  try {
    return await configureVaultInner(rootAbs, opts);
  } catch (err) {
    trap(err);
  }
}

export async function locateSource(rootAbs, binding, rel) {
  try {
    return await locateSourceInner(rootAbs, binding, rel);
  } catch (err) {
    trap(err);
  }
}
