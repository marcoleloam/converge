import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const CLI = fileURLToPath(new URL('../index.mjs', import.meta.url));

const TOKEN_A = 'xylophagebrainalpha';
const TOKEN_EARLY = 'earlytokenbrainprefix';
const TOKEN_B = 'quokkaorbicularis';
const TOKEN_GONE = 'removedsourcelemma';
const TOKEN_NEW = 'addedsourcelemma';
const TOKEN_NOTE = 'ownereditedbrainnote';
const TOKEN_SECRET = 'outervaultsecretum';
const MISSING_TERM = 'noSuchLexemeZqqq';
const TOKEN_LEGACY_INDEX = 'ownerlegacyindexlemma';
const TOKEN_LEGACY_NOTE = 'ownerlegacynotelemma';
const TOKEN_CVG = 'convergecontrollemma';
const TOKEN_TASK = 'taskcontrollemma';
const TOKEN_RECEIPT = 'receiptcontrollemma';
const TOKEN_CLASH_SRC = 'clashsourcelemma';
const TOKEN_CLASH_DST = 'clashdestlemma';
const TOKEN_VAULT_NOTE = 'vaultliveeditlemma';
const TOKEN_VAULT_NOTE_2 = 'vaultliveeditrefresh';
const TOKEN_INDEX_ONLY = 'indexonlylemmazzz';
const TOKEN_DECISION = 'historicaldecisionlemma';
const TOKEN_LOOP = 'historicallooplemma';

function childEnv(home) {
  const env = {};
  for (const key of ['PATH', 'TMPDIR', 'USER', 'LANG', 'LC_ALL']) {
    if (process.env[key]) env[key] = process.env[key];
  }
  env.HOME = home;
  return env;
}

async function runBrain(root, argv, { timeoutMs = 60_000, vault, home } = {}) {
  if (!home) throw new Error('tests must pass a sandbox HOME');
  const args = [...argv, '--root', root];
  if (vault != null) args.push('--vault', vault);
  const child = spawn(process.execPath, [CLI, ...args], {
    cwd: path.dirname(CLI),
    env: childEnv(home),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const stdoutChunks = [];
  const stderrChunks = [];
  child.stdout.on('data', (chunk) => stdoutChunks.push(chunk));
  child.stderr.on('data', (chunk) => stderrChunks.push(chunk));

  const code = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      child.kill('SIGKILL');
      reject(new Error(`timed out: ${argv.join(' ')}`));
    }, timeoutMs);
    child.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on('close', (exitCode) => {
      clearTimeout(timer);
      resolve(exitCode ?? 1);
    });
  });

  const stdoutBuf = Buffer.concat(stdoutChunks);
  const stdout = stdoutBuf.toString('utf8');
  const stderr = Buffer.concat(stderrChunks).toString('utf8');
  let json;
  try {
    json = JSON.parse(stdout.trim());
  } catch {
    json = undefined;
  }
  return { code, stdout, stdoutBuf, stderr, json, bytes: stdoutBuf.byteLength };
}

function requireJson(result) {
  assert.ok(
    result.json && typeof result.json === 'object' && !Array.isArray(result.json),
    `stdout must be a JSON object, got ${JSON.stringify(result.stdout.slice(0, 500))} stderr=${result.stderr.slice(0, 500)}`,
  );
  return result.json;
}

function assertEnvelope(json, status) {
  assert.equal(json.schema, 'ConvergeMemory/v1');
  assert.equal(json.status, status);
  assert.equal(json.execution_authorized, false);
}

function assertStatus(result, status, action) {
  const json = requireJson(result);
  assertEnvelope(json, status);
  if (status === 'READY') assert.equal(result.code, 0);
  else assert.equal(result.code, 2);
  return json;
}

function posix(relPath) {
  return String(relPath).replaceAll('\\', '/');
}

function leaked(result, token) {
  return result.stdout.includes(token) || result.stderr.includes(token);
}

async function sha256File(filePath) {
  return createHash('sha256').update(await readFile(filePath)).digest('hex');
}

function projectIdFor(rootAbs) {
  return createHash('sha256').update(rootAbs).digest('hex').slice(0, 16);
}

async function assertProjectFields(json, root, vault, { vaultPath = false } = {}) {
  const rootAbs = await realpath(root);
  const vaultAbs = await realpath(vault);
  assert.equal(json.project_id, projectIdFor(rootAbs));
  assert.equal(json.project_name, path.basename(vaultAbs));
  if (vaultPath) {
    assert.ok(typeof json.vault_path === 'string' && path.isAbsolute(json.vault_path));
    assert.equal(await realpath(json.vault_path), vaultAbs);
  }
}

function paddingLines(count) {
  return Array.from(
    { length: count },
    (_, i) => `padding line ${i} lorem ipsum dolor sit amet`,
  ).join('\n');
}

async function writeDocs(root, relative, body) {
  const filePath = path.join(root, ...relative.split('/'));
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, body, 'utf8');
  return filePath;
}

async function exists(filePath) {
  try {
    await lstat(filePath);
    return true;
  } catch (err) {
    if (err && err.code === 'ENOENT') return false;
    throw err;
  }
}

async function writeLegacyBinding(root, vault) {
  const rootAbs = await realpath(root);
  const vaultAbs = await realpath(vault);
  const binding = {
    schema: 'DarkfactoryBrainBinding/v1',
    project_id: projectIdFor(rootAbs),
    project_name: path.basename(vaultAbs),
    project_root: rootAbs,
    vault_path: vaultAbs,
  };
  const body = `${JSON.stringify(binding)}\n`;
  await writeDocs(root, '.darkfactory/brain/vault.json', body);
  await writeFile(path.join(vaultAbs, '.darkfactory-project.json'), body);
  return binding;
}

async function withTempWorkspace(fn) {
  const dirs = [];
  const alloc = async (label = 'cvg-memory-') => {
    const dir = await mkdtemp(path.join(tmpdir(), label));
    dirs.push(dir);
    return dir;
  };
  try {
    const home = await alloc('cvg-memory-home-');
    return await fn({ home, alloc });
  } finally {
    await Promise.all(dirs.map((dir) => rm(dir, { recursive: true, force: true })));
  }
}

test('init indexes unique terms, honors byte budget, and preserves owner notes', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    const alpha = [
      `# ${TOKEN_EARLY}`,
      '',
      TOKEN_A,
      '',
      paddingLines(220),
      '',
    ].join('\n');
    await writeFile(path.join(root, 'README.md'), '# Brownfield fixture\n', 'utf8');
    const alphaPath = await writeDocs(root, 'docs/alpha.md', alpha);
    const alphaHash = await sha256File(alphaPath);

    assertStatus(await run(['status']), 'UNINITIALIZED', 'status');

    const inited = assertStatus(await run(['init'], { vault }), 'READY', 'init');
    await assertProjectFields(inited, root, vault, { vaultPath: true });
    assert.equal(await exists(path.join(root, '.darkfactory')), false);
    assert.equal(await exists(path.join(root, '.cvg', 'memory', 'vault.json')), true);
    assert.equal(await exists(path.join(vault, '.converge-project.json')), true);
    assert.equal(await exists(path.join(vault, '.darkfactory-project.json')), false);

    const indexPath = path.join(vault, 'INDEX.md');
    const manifestPath = path.join(root, '.cvg', 'memory', 'sources.json');

    const indexMd = await readFile(indexPath, 'utf8');
    assert.match(indexMd, /docs\/alpha\.md/);
    const manifest = await readFile(manifestPath, 'utf8');
    assert.doesNotMatch(manifest, new RegExp(TOKEN_A));
    const manifestJson = JSON.parse(manifest);
    assert.equal(manifestJson.schema, 'ConvergeMemory/v1');
    assert.equal(manifestJson.project_id, projectIdFor(await realpath(root)));

    const missing = assertStatus(await run(['search', MISSING_TERM]), 'READY', 'search');
    await assertProjectFields(missing, root, vault);
    assert.deepEqual(missing.results, []);

    const searchProc = await run(['search', TOKEN_A, '--limit', '5']);
    const search = assertStatus(searchProc, 'READY', 'search');
    await assertProjectFields(search, root, vault);
    assert.ok(searchProc.bytes <= 6000, `default budget ${searchProc.bytes} > 6000`);
    const hits = search.results;
    assert.ok(hits.every((item) => posix(item.path) === 'docs/alpha.md'));
    const hit = hits.find((item) => String(item.snippet).includes(TOKEN_A)) ?? hits[0];
    assert.equal(posix(hit.path), 'docs/alpha.md');
    assert.doesNotMatch(posix(hit.path), /^\//);
    assert.ok(!posix(hit.path).includes('..'));
    assert.equal(hit.sha256, alphaHash);
    assert.equal(typeof hit.start_line, 'number');
    assert.equal(typeof hit.end_line, 'number');
    assert.ok(hit.start_line >= 1);
    assert.ok(hit.end_line >= hit.start_line);
    assert.ok(hit.start_line <= 3 && 3 <= hit.end_line);
    assert.equal(typeof hit.snippet, 'string');
    assert.match(hit.snippet, new RegExp(TOKEN_A));
    assert.ok(hit.snippet.length < alpha.length);
    assert.ok(!JSON.stringify(hit).includes(paddingLines(220)));

    const tightSearch = await run([
      'search',
      TOKEN_A,
      '--limit',
      '5',
      '--max-bytes',
      '512',
    ]);
    const tightJson = assertStatus(tightSearch, 'READY', 'search');
    assert.ok(tightSearch.bytes <= 512, `512 budget exceeded: ${tightSearch.bytes}`);
    assert.ok(tightJson.results.length > 0 || tightJson.truncated === true);

    const windowed = assertStatus(
      await run([
        'read',
        'docs/alpha.md',
        '--from',
        '3',
        '--lines',
        '2',
        '--max-bytes',
        '6000',
      ]),
      'READY',
      'read',
    );
    await assertProjectFields(windowed, root, vault);
    assert.equal(posix(windowed.path), 'docs/alpha.md');
    assert.equal(windowed.sha256, alphaHash);
    assert.equal(windowed.start_line, 3);
    assert.equal(windowed.end_line, 4);
    assert.equal(typeof windowed.text, 'string');
    assert.match(windowed.text, new RegExp(TOKEN_A));
    assert.doesNotMatch(windowed.text, new RegExp(TOKEN_EARLY));

    const bulkyRead = await run([
      'read',
      'docs/alpha.md',
      '--from',
      '1',
      '--lines',
      '120',
      '--max-bytes',
      '512',
    ]);
    const bulkyJson = assertStatus(bulkyRead, 'READY', 'read');
    assert.ok(bulkyRead.bytes <= 512, `read 512 budget exceeded: ${bulkyRead.bytes}`);
    assert.equal(bulkyJson.truncated, true);
    assert.equal(posix(bulkyJson.path), 'docs/alpha.md');
    assert.equal(bulkyJson.sha256, alphaHash);
    assert.equal(typeof bulkyJson.text, 'string');

    await writeFile(indexPath, `${indexMd.trimEnd()}\n\n${TOKEN_INDEX_ONLY}\n`, 'utf8');
    assertStatus(await run(['status']), 'READY', 'status');
    const indexHits = assertStatus(await run(['search', TOKEN_INDEX_ONLY]), 'READY', 'search');
    assert.deepEqual(indexHits.results, []);

    const notePath = path.join(vault, 'notes', 'human.md');
    await mkdir(path.dirname(notePath), { recursive: true });
    const noteBody = `# Owner note\n\n${TOKEN_NOTE}\n`;
    await writeFile(notePath, noteBody, 'utf8');
    await writeFile(indexPath, `${indexMd.trimEnd()}\n\n${TOKEN_NOTE}\n`, 'utf8');

    assertStatus(await run(['init']), 'READY', 'init');
    assert.equal(await readFile(notePath, 'utf8'), noteBody);
    assert.match(await readFile(indexPath, 'utf8'), new RegExp(TOKEN_NOTE));
    assert.equal(await exists(path.join(root, '.darkfactory')), false);
  });
});

test('source add remove mutate go STALE until refresh and stay isolated across roots', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const rootA = await alloc('cvg-memory-a-');
    const vaultA = await alloc('cvg-memory-va-');
    const rootB = await alloc('cvg-memory-b-');
    const vaultB = await alloc('cvg-memory-vb-');
    const runA = (argv, extra = {}) => runBrain(rootA, argv, { home, ...extra });
    const runB = (argv, extra = {}) => runBrain(rootB, argv, { home, ...extra });

    await writeFile(path.join(rootA, 'README.md'), '# Project A\n', 'utf8');
    await writeFile(path.join(rootB, 'README.md'), '# Project B\n', 'utf8');
    const keepPath = await writeDocs(rootA, 'docs/keep.md', `# Keep\n\n${TOKEN_A}\n`);
    await writeDocs(rootA, 'docs/gone.md', `# Gone\n\n${TOKEN_GONE}\n`);
    await writeDocs(rootB, 'docs/beta.md', `# Beta\n\n${TOKEN_B}\n`);

    const initA = assertStatus(await runA(['init'], { vault: vaultA }), 'READY', 'init');
    const initB = assertStatus(await runB(['init'], { vault: vaultB }), 'READY', 'init');
    await assertProjectFields(initA, rootA, vaultA, { vaultPath: true });
    await assertProjectFields(initB, rootB, vaultB, { vaultPath: true });
    assert.notEqual(initA.project_id, initB.project_id);

    const before = assertStatus(await runA(['search', TOKEN_GONE]), 'READY', 'search');
    assert.equal(posix(before.results[0].path), 'docs/gone.md');

    await writeDocs(rootA, 'docs/new.md', `# New\n\n${TOKEN_NEW}\n`);
    const staleA = assertStatus(await runA(['status']), 'STALE', 'status');
    await assertProjectFields(staleA, rootA, vaultA, { vaultPath: true });
    assertStatus(await runA(['search', TOKEN_NEW]), 'STALE', 'search');
    assertStatus(await runB(['status']), 'READY', 'status');
    const stillB = assertStatus(await runB(['search', TOKEN_B]), 'READY', 'search');
    assert.equal(posix(stillB.results[0].path), 'docs/beta.md');
    const cross = assertStatus(await runB(['search', TOKEN_A]), 'READY', 'search');
    assert.deepEqual(cross.results, []);

    const refreshed = assertStatus(await runA(['refresh']), 'READY', 'refresh');
    await assertProjectFields(refreshed, rootA, vaultA, { vaultPath: true });
    const added = assertStatus(await runA(['search', TOKEN_NEW]), 'READY', 'search');
    assert.equal(posix(added.results[0].path), 'docs/new.md');
    assert.equal(added.results[0].sha256, await sha256File(path.join(rootA, 'docs', 'new.md')));

    await rm(path.join(rootA, 'docs', 'gone.md'));
    assertStatus(await runA(['status']), 'STALE', 'status');
    assertStatus(await runA(['read', 'docs/gone.md']), 'STALE', 'read');
    assertStatus(await runA(['refresh']), 'READY', 'refresh');
    const gone = assertStatus(await runA(['search', TOKEN_GONE]), 'READY', 'search');
    assert.deepEqual(gone.results, []);
    const goneRead = await runA(['read', 'docs/gone.md']);
    assertStatus(goneRead, 'ERROR', 'read');
    assert.equal(leaked(goneRead, TOKEN_GONE), false);

    await writeFile(keepPath, `# Keep\n\n${TOKEN_A}\nmutated\n`, 'utf8');
    const mutatedHash = await sha256File(keepPath);
    assertStatus(await runA(['status']), 'STALE', 'status');
    assertStatus(await runA(['search', TOKEN_A]), 'STALE', 'search');
    assertStatus(await runA(['read', 'docs/keep.md']), 'STALE', 'read');
    assertStatus(await runA(['refresh']), 'READY', 'refresh');
    const mutated = assertStatus(await runA(['search', TOKEN_A]), 'READY', 'search');
    assert.equal(posix(mutated.results[0].path), 'docs/keep.md');
    assert.equal(mutated.results[0].sha256, mutatedHash);
    const mutatedRead = assertStatus(await runA(['read', 'docs/keep.md']), 'READY', 'read');
    assert.equal(mutatedRead.sha256, mutatedHash);
    assert.match(mutatedRead.text, /mutated/);

    const bAfter = assertStatus(await runB(['search', TOKEN_NEW]), 'READY', 'search');
    assert.deepEqual(bAfter.results, []);
    assertStatus(await runB(['status']), 'READY', 'status');
    const aHasB = assertStatus(await runA(['search', TOKEN_B]), 'READY', 'search');
    assert.deepEqual(aHasB.results, []);
  });
});

test('read traversal and source/cache symlinks do not leak external content', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const outside = await alloc('cvg-memory-out-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    const secretPath = path.join(outside, 'secret.md');
    await writeFile(secretPath, `# Secret\n\n${TOKEN_SECRET}\n`, 'utf8');
    await writeFile(path.join(root, 'README.md'), '# Safe\n', 'utf8');
    await writeDocs(root, 'docs/alpha.md', `# Alpha\n\n${TOKEN_A}\n`);
    await mkdir(path.join(root, 'docs'), { recursive: true });
    await symlink(secretPath, path.join(root, 'docs', 'leaked.md'));
    await writeDocs(root, 'docs/large.md', `${TOKEN_SECRET}\n${'x'.repeat(512 * 1024)}`);

    assertStatus(await run(['init'], { vault }), 'READY', 'init');
    const { createStore } = await import('@tobilu/qmd');
    const store = await createStore({
      dbPath: path.join(root, '.cvg/memory/cache/index.sqlite'),
    });
    try {
      assert.deepEqual(
        await store.searchLex(TOKEN_SECRET),
        [],
        'excluded content must not enter the search index',
      );
    } finally {
      await store.close();
    }

    const secretSearch = assertStatus(await run(['search', TOKEN_SECRET]), 'READY', 'search');
    assert.deepEqual(secretSearch.results, []);

    const safeSearch = await run(['search', TOKEN_A]);
    const safeResult = assertStatus(safeSearch, 'READY', 'search');
    assert.equal(posix(safeResult.results[0].path), 'docs/alpha.md');
    assert.equal(leaked(safeSearch, TOKEN_SECRET), false);

    const leakedRead = await run(['read', 'docs/leaked.md']);
    assertStatus(leakedRead, 'ERROR', 'read');
    assert.equal(leaked(leakedRead, TOKEN_SECRET), false);

    const traversals = [
      '../secret.md',
      'docs/../../secret.md',
      secretPath,
      'vault/../secret.md',
      'vault/notes/../../secret.md',
    ];
    for (const target of traversals) {
      const blocked = await run(['read', target]);
      assertStatus(blocked, 'ERROR', 'read');
      assert.equal(leaked(blocked, TOKEN_SECRET), false);
    }

    const cacheDir = path.join(root, '.cvg', 'memory', 'cache');
    const outsideCache = path.join(outside, 'memory-cache');
    await cp(cacheDir, outsideCache, { recursive: true });
    await writeFile(path.join(outsideCache, 'planted.md'), `${TOKEN_SECRET}\n`, 'utf8');
    await rm(cacheDir, { recursive: true, force: true });
    await symlink(outsideCache, cacheDir);

    const cacheSearch = await run(['search', TOKEN_A]);
    assertStatus(cacheSearch, 'ERROR', 'search');
    assert.equal(leaked(cacheSearch, TOKEN_SECRET), false);

    const cacheStatus = await run(['status']);
    assertStatus(cacheStatus, 'ERROR', 'status');
    assert.equal(leaked(cacheStatus, TOKEN_SECRET), false);
  });
});

test('UTF-8 citations cannot overflow a tight output budget', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });
    const rel = `docs/${Array(4).fill('á'.repeat(60)).join('/')}/note.md`;
    await writeDocs(root, rel, '# Evidence\n\nlongpathbudgetlemma\n');
    assertStatus(await run(['init'], { vault }), 'READY');
    const tight = await run(['read', rel, '--max-bytes', '512']);
    assert.ok(tight.bytes <= 512);
    assertStatus(tight, 'ERROR');
    const expanded = assertStatus(await run(['read', rel, '--max-bytes', '6000']), 'READY');
    assert.equal(expanded.path, rel);
    assert.match(expanded.text, /longpathbudgetlemma/);
  });
});

test('migrate moves legacy notes and keeps converge controls byte-identical', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    await writeFile(path.join(root, 'README.md'), '# Legacy project\n', 'utf8');
    const noteBody = `# Legacy note\n\n${TOKEN_LEGACY_NOTE}\n`;
    const indexBody = `# Human index\n\n${TOKEN_LEGACY_INDEX}\n`;
    const cvgBody = `# Spec\n\n${TOKEN_CVG}\n`;
    const taskBody = `# Task\n\n${TOKEN_TASK}\n`;
    const receiptBody = `{"k":"${TOKEN_RECEIPT}"}\n`;
    const pluginManifest = '{"id":"example-sync-plugin"}\n';
    const oldApp = `${JSON.stringify({
      alwaysUpdateLinks: true,
      plugins: { sync: { enabled: true } },
      sync: { enabled: true },
    })}\n`;

    const notePath = await writeDocs(root, '.darkfactory/brain/notes/human.md', noteBody);
    const indexPath = await writeDocs(root, '.darkfactory/brain/INDEX.md', indexBody);
    const cvgPath = await writeDocs(root, 'cvg/docs/spec.md', cvgBody);
    const taskPath = await writeDocs(root, 'tasks/T-keep.md', taskBody);
    const receiptPath = await writeDocs(root, 'receipts/keep.json', receiptBody);
    await writeDocs(root, '.darkfactory/.obsidian/app.json', oldApp);
    await writeDocs(root, '.darkfactory/.obsidian/plugins/example/manifest.json', pluginManifest);

    const cvgHash = await sha256File(cvgPath);
    const taskHash = await sha256File(taskPath);
    const receiptHash = await sha256File(receiptPath);
    const readmeHash = await sha256File(path.join(root, 'README.md'));

    assertStatus(await run(['init'], { vault }), 'ERROR', 'init');
    assert.equal(await exists(path.join(root, '.cvg', 'memory', 'vault.json')), false);
    assert.equal(await readFile(notePath, 'utf8'), noteBody);
    assert.equal(await readFile(indexPath, 'utf8'), indexBody);
    assert.equal(await sha256File(cvgPath), cvgHash);
    assert.equal(await sha256File(taskPath), taskHash);
    assert.equal(await sha256File(receiptPath), receiptHash);

    const migrated = assertStatus(await run(['migrate'], { vault }), 'READY', 'migrate');
    await assertProjectFields(migrated, root, vault, { vaultPath: true });

    assert.equal(await readFile(path.join(vault, 'notes', 'human.md'), 'utf8'), noteBody);
    assert.equal(await readFile(path.join(vault, 'LEGACY-INDEX.md'), 'utf8'), indexBody);
    assert.equal(await sha256File(cvgPath), cvgHash);
    assert.equal(await sha256File(taskPath), taskHash);
    assert.equal(await sha256File(receiptPath), receiptHash);
    assert.equal(await sha256File(path.join(root, 'README.md')), readmeHash);

    const backupApp = path.join(
      root,
      '.cvg',
      'memory',
      'migration-backup',
      'obsidian',
      'app.json',
    );
    const backupPlugin = path.join(
      root,
      '.cvg',
      'memory',
      'migration-backup',
      'obsidian',
      'plugins',
      'example',
      'manifest.json',
    );
    assert.equal(await readFile(backupApp, 'utf8'), oldApp);
    assert.equal(await readFile(backupPlugin, 'utf8'), pluginManifest);
    assert.equal(await exists(path.join(vault, '.obsidian', 'plugins')), false);
  });
});

test('vault ownership rejects another project including same basename', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const parentA = await alloc('cvg-memory-pa-');
    const parentB = await alloc('cvg-memory-pb-');
    const rootA = path.join(parentA, 'sameproj');
    const rootB = path.join(parentB, 'sameproj');
    const vaultA = await alloc('cvg-memory-va-');
    const vaultB = await alloc('cvg-memory-vb-');
    await mkdir(rootA);
    await mkdir(rootB);
    assert.equal(path.basename(rootA), path.basename(rootB));

    await writeFile(path.join(rootA, 'README.md'), '# Project A\n', 'utf8');
    await writeFile(path.join(rootB, 'README.md'), '# Project B\n', 'utf8');
    await writeDocs(rootA, 'docs/alpha.md', `# A\n\n${TOKEN_A}\n`);
    await writeDocs(rootB, 'docs/beta.md', `# B\n\n${TOKEN_B}\n`);

    const initA = assertStatus(
      await runBrain(rootA, ['init'], { home, vault: vaultA }),
      'READY',
      'init',
    );
    await assertProjectFields(initA, rootA, vaultA, { vaultPath: true });
    const markerPath = path.join(vaultA, '.converge-project.json');
    const markerBefore = await readFile(markerPath, 'utf8');

    const stolen = await runBrain(rootB, ['init'], { home, vault: vaultA });
    assertStatus(stolen, 'ERROR', 'init');
    assert.equal(await readFile(markerPath, 'utf8'), markerBefore);
    const marker = JSON.parse(markerBefore);
    assert.equal(marker.schema, 'ConvergeMemoryBinding/v1');
    assert.equal(marker.project_id, projectIdFor(await realpath(rootA)));
    assert.notEqual(marker.project_id, projectIdFor(await realpath(rootB)));

    const initB = assertStatus(
      await runBrain(rootB, ['init'], { home, vault: vaultB }),
      'READY',
      'init',
    );
    await assertProjectFields(initB, rootB, vaultB, { vaultPath: true });
    assert.notEqual(initB.project_id, initA.project_id);
    assert.notEqual(await realpath(initB.vault_path), await realpath(vaultA));

    const stillA = assertStatus(await runBrain(rootA, ['status'], { home }), 'READY', 'status');
    await assertProjectFields(stillA, rootA, vaultA, { vaultPath: true });
    const searchA = assertStatus(
      await runBrain(rootA, ['search', TOKEN_A], { home }),
      'READY',
      'search',
    );
    assert.equal(posix(searchA.results[0].path), 'docs/alpha.md');
    const cross = assertStatus(
      await runBrain(rootB, ['search', TOKEN_A], { home }),
      'READY',
      'search',
    );
    assert.deepEqual(cross.results, []);
  });
});

test('vault note mutation goes STALE until refresh', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    await writeFile(path.join(root, 'README.md'), '# Notes project\n', 'utf8');
    assertStatus(await run(['init'], { vault }), 'READY', 'init');

    const noteRel = 'vault/notes/live.md';
    const notePath = path.join(vault, 'notes', 'live.md');
    await mkdir(path.dirname(notePath), { recursive: true });
    await writeFile(notePath, `# Live\n\n${TOKEN_VAULT_NOTE}\n`, 'utf8');

    assertStatus(await run(['status']), 'STALE', 'status');
    assertStatus(await run(['search', TOKEN_VAULT_NOTE]), 'STALE', 'search');
    assertStatus(await run(['read', noteRel]), 'STALE', 'read');

    const refreshed = assertStatus(await run(['refresh']), 'READY', 'refresh');
    await assertProjectFields(refreshed, root, vault, { vaultPath: true });
    const found = assertStatus(await run(['search', TOKEN_VAULT_NOTE]), 'READY', 'search');
    assert.equal(posix(found.results[0].path), noteRel);
    assert.equal(found.results[0].sha256, await sha256File(notePath));
    const readHit = assertStatus(await run(['read', noteRel]), 'READY', 'read');
    assert.equal(posix(readHit.path), noteRel);
    assert.match(readHit.text, new RegExp(TOKEN_VAULT_NOTE));

    await writeFile(notePath, `# Live\n\n${TOKEN_VAULT_NOTE_2}\n`, 'utf8');
    const mutatedHash = await sha256File(notePath);
    assertStatus(await run(['status']), 'STALE', 'status');
    assertStatus(await run(['search', TOKEN_VAULT_NOTE_2]), 'STALE', 'search');
    assertStatus(await run(['read', noteRel]), 'STALE', 'read');
    assertStatus(await run(['refresh']), 'READY', 'refresh');
    const updated = assertStatus(await run(['search', TOKEN_VAULT_NOTE_2]), 'READY', 'search');
    assert.equal(posix(updated.results[0].path), noteRel);
    assert.equal(updated.results[0].sha256, mutatedHash);
    const updatedRead = assertStatus(await run(['read', noteRel]), 'READY', 'read');
    assert.match(updatedRead.text, new RegExp(TOKEN_VAULT_NOTE_2));
    assert.doesNotMatch(updatedRead.text, new RegExp(TOKEN_VAULT_NOTE));
  });
});

test('migrate note collision leaves source and destination bytes intact', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    await writeFile(path.join(root, 'README.md'), '# Collision project\n', 'utf8');
    const okBody = '# Ok note\n\nsafe to copy\n';
    const srcBody = `# Clash\n\n${TOKEN_CLASH_SRC}\n`;
    const dstBody = `# Clash\n\n${TOKEN_CLASH_DST}\n`;
    await writeDocs(root, '.darkfactory/brain/notes/ok.md', okBody);
    await writeDocs(root, '.darkfactory/brain/notes/clash.md', srcBody);
    await writeDocs(root, '.darkfactory/brain/INDEX.md', '# Human index\n');
    await writeDocs(
      root,
      '.darkfactory/.obsidian/app.json',
      `${JSON.stringify({ alwaysUpdateLinks: true })}\n`,
    );

    assertStatus(await run(['migrate'], { vault }), 'READY', 'migrate');
    const destClash = path.join(vault, 'notes', 'clash.md');
    const destOk = path.join(vault, 'notes', 'ok.md');
    assert.equal(await readFile(destClash, 'utf8'), srcBody);
    assert.equal(await readFile(destOk, 'utf8'), okBody);

    await writeFile(destClash, dstBody, 'utf8');
    const sourceClash = await writeDocs(root, '.darkfactory/brain/notes/clash.md', srcBody);
    const destOkBefore = await readFile(destOk, 'utf8');

    assertStatus(await run(['migrate'], { vault }), 'ERROR', 'migrate');
    assert.equal(await readFile(destClash, 'utf8'), dstBody);
    assert.equal(await readFile(sourceClash, 'utf8'), srcBody);
    assert.equal(await readFile(destOk, 'utf8'), destOkBefore);
  });
});

test('migration rejects a nested destination symlink without moving notes outside the vault', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const outside = await alloc('cvg-memory-outside-');
    await writeFile(path.join(root, 'README.md'), '# Project\n');
    assertStatus(await runBrain(root, ['init'], { home, vault }), 'READY');
    const source = await writeDocs(root, '.darkfactory/brain/notes/nested/private.md', TOKEN_NOTE);
    await symlink(outside, path.join(vault, 'notes', 'nested'), 'dir');

    assertStatus(await runBrain(root, ['migrate'], { home }), 'ERROR');
    assert.equal(await readFile(source, 'utf8'), TOKEN_NOTE);
    assert.equal(await exists(path.join(outside, 'private.md')), false);
  });
});

test('migrate imports bound darkfactory vault identity and copies historical records', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    await writeFile(path.join(root, 'README.md'), '# Bound project\n', 'utf8');
    const noteBody = `# Live vault note\n\n${TOKEN_VAULT_NOTE}\n`;
    await mkdir(path.join(vault, 'notes'), { recursive: true });
    await writeFile(path.join(vault, 'notes', 'human.md'), noteBody, 'utf8');
    const legacy = await writeLegacyBinding(root, vault);
    const decisionBody = `# Decision\n\n${TOKEN_DECISION}\n`;
    const loopBody = `# Loop\n\n${TOKEN_LOOP}\n`;
    const queueBody = `# Queue\n\n${TOKEN_RECEIPT}\n`;
    const refBody = `# Ref\n\n${TOKEN_LEGACY_INDEX}\n`;
    await writeDocs(root, '.darkfactory/brain/decisions/keep.md', decisionBody);
    await writeDocs(root, '.darkfactory/brain/loops/keep.md', loopBody);
    await writeDocs(root, '.darkfactory/brain/queue/DECISIONS.md', queueBody);
    await writeDocs(root, '.darkfactory/brain/refs/keep.md', refBody);
    await writeDocs(root, '.darkfactory/brain/STATE.md', '# generated board\n');
    await writeDocs(root, '.darkfactory/brain/decisions/TEMPLATE.md', '# template\n');
    await writeDocs(root, 'cvg/brain/decisions/.gitkeep', '');

    const dfOwnerBefore = await readFile(path.join(vault, '.darkfactory-project.json'), 'utf8');
    const noteBefore = await readFile(path.join(vault, 'notes', 'human.md'), 'utf8');

    assertStatus(await run(['init'], { vault }), 'ERROR', 'init');
    assert.equal(await exists(path.join(root, '.cvg', 'memory', 'vault.json')), false);
    assert.equal(await readFile(path.join(vault, 'notes', 'human.md'), 'utf8'), noteBefore);
    assert.equal(await readFile(path.join(vault, '.darkfactory-project.json'), 'utf8'), dfOwnerBefore);

    const migrated = assertStatus(await run(['migrate']), 'READY', 'migrate');
    await assertProjectFields(migrated, root, vault, { vaultPath: true });
    assert.equal(migrated.project_id, legacy.project_id);

    assert.equal(await readFile(path.join(vault, 'notes', 'human.md'), 'utf8'), noteBody);
    assert.equal(await readFile(path.join(vault, '.darkfactory-project.json'), 'utf8'), dfOwnerBefore);
    const nativeOwner = JSON.parse(await readFile(path.join(vault, '.converge-project.json'), 'utf8'));
    assert.equal(nativeOwner.schema, 'ConvergeMemoryBinding/v1');
    assert.equal(nativeOwner.project_id, legacy.project_id);
    assert.equal(nativeOwner.vault_path, legacy.vault_path);

    const nativeRepo = JSON.parse(await readFile(path.join(root, '.cvg', 'memory', 'vault.json'), 'utf8'));
    assert.equal(nativeRepo.schema, 'ConvergeMemoryBinding/v1');
    assert.equal(nativeRepo.project_id, legacy.project_id);
    assert.equal(nativeRepo.project_root, legacy.project_root);
    assert.equal(nativeRepo.vault_path, legacy.vault_path);

    assert.equal(await readFile(path.join(root, 'cvg/brain/decisions/keep.md'), 'utf8'), decisionBody);
    assert.equal(await readFile(path.join(root, 'cvg/brain/loops/keep.md'), 'utf8'), loopBody);
    assert.equal(await readFile(path.join(root, 'cvg/brain/queue/DECISIONS.md'), 'utf8'), queueBody);
    assert.equal(await readFile(path.join(root, 'cvg/brain/refs/keep.md'), 'utf8'), refBody);
    assert.equal(await exists(path.join(root, 'cvg/brain/STATE.md')), false);
    assert.equal(await exists(path.join(root, 'cvg/brain/decisions/TEMPLATE.md')), false);
    assert.equal(await exists(path.join(root, '.darkfactory/brain/decisions/keep.md')), true);
    assert.equal(await exists(path.join(root, '.darkfactory/brain/STATE.md')), true);

    const backupVault = path.join(root, '.cvg', 'memory', 'migration-backup', 'darkfactory-brain-vault.json');
    const backupOwner = path.join(root, '.cvg', 'memory', 'migration-backup', 'darkfactory-project.json');
    assert.equal(JSON.parse(await readFile(backupVault, 'utf8')).project_id, legacy.project_id);
    assert.equal(JSON.parse(await readFile(backupOwner, 'utf8')).project_id, legacy.project_id);

    const foundDecision = assertStatus(await run(['search', TOKEN_DECISION]), 'READY', 'search');
    assert.equal(posix(foundDecision.results[0].path), 'cvg/brain/decisions/keep.md');
    const foundNote = assertStatus(await run(['search', TOKEN_VAULT_NOTE]), 'READY', 'search');
    assert.equal(posix(foundNote.results[0].path), 'vault/notes/human.md');
    assertStatus(await run(['status']), 'READY', 'status');

    const retried = assertStatus(await run(['migrate']), 'READY', 'migrate');
    await assertProjectFields(retried, root, vault, { vaultPath: true });
    assert.equal(await readFile(path.join(vault, 'notes', 'human.md'), 'utf8'), noteBody);
    assert.equal(await readFile(path.join(root, 'cvg/brain/decisions/keep.md'), 'utf8'), decisionBody);
  });
});

test('historical copy refuses conflicting cvg/brain records without writes', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    await writeFile(path.join(root, 'README.md'), '# Conflict project\n', 'utf8');
    await writeLegacyBinding(root, vault);
    const okBody = `# Ok\n\n${TOKEN_DECISION}\n`;
    const srcBody = `# Clash\n\n${TOKEN_CLASH_SRC}\n`;
    const dstBody = `# Clash\n\n${TOKEN_CLASH_DST}\n`;
    await writeDocs(root, '.darkfactory/brain/decisions/ok.md', okBody);
    assertStatus(await run(['migrate']), 'READY', 'migrate');
    assert.equal(await readFile(path.join(root, 'cvg/brain/decisions/ok.md'), 'utf8'), okBody);

    await writeDocs(root, 'cvg/brain/decisions/clash.md', dstBody);
    const sourceClash = await writeDocs(root, '.darkfactory/brain/decisions/clash.md', srcBody);
    const destClash = path.join(root, 'cvg/brain/decisions/clash.md');
    const destOk = path.join(root, 'cvg/brain/decisions/ok.md');
    const destOkBefore = await readFile(destOk, 'utf8');
    const nativeBefore = await readFile(path.join(root, '.cvg', 'memory', 'vault.json'), 'utf8');

    assertStatus(await run(['migrate']), 'ERROR', 'migrate');
    assert.equal(await readFile(destClash, 'utf8'), dstBody);
    assert.equal(await readFile(sourceClash, 'utf8'), srcBody);
    assert.equal(await readFile(destOk, 'utf8'), destOkBefore);
    assert.equal(await readFile(path.join(root, '.cvg', 'memory', 'vault.json'), 'utf8'), nativeBefore);
  });
});

test('migrate rejects mismatched darkfactory identity markers without native writes', async () => {
  await withTempWorkspace(async ({ home, alloc }) => {
    const root = await alloc('cvg-memory-root-');
    const vault = await alloc('cvg-memory-vault-');
    const other = await alloc('cvg-memory-other-');
    const run = (argv, extra = {}) => runBrain(root, argv, { home, ...extra });

    await writeFile(path.join(root, 'README.md'), '# Mismatch project\n', 'utf8');
    const noteBody = `# Keep\n\n${TOKEN_NOTE}\n`;
    await mkdir(path.join(vault, 'notes'), { recursive: true });
    await writeFile(path.join(vault, 'notes', 'human.md'), noteBody, 'utf8');
    await writeLegacyBinding(root, vault);
    const otherAbs = await realpath(other);
    const stolen = {
      schema: 'DarkfactoryBrainBinding/v1',
      project_id: projectIdFor(otherAbs),
      project_name: path.basename(await realpath(vault)),
      project_root: otherAbs,
      vault_path: await realpath(vault),
    };
    await writeFile(path.join(vault, '.darkfactory-project.json'), `${JSON.stringify(stolen)}\n`);

    assertStatus(await run(['migrate']), 'ERROR', 'migrate');
    assert.equal(await readFile(path.join(vault, 'notes', 'human.md'), 'utf8'), noteBody);
    assert.equal(await exists(path.join(root, '.cvg', 'memory', 'vault.json')), false);
    assert.equal(await exists(path.join(vault, '.converge-project.json')), false);
    assert.equal(JSON.parse(await readFile(path.join(vault, '.darkfactory-project.json'), 'utf8')).project_id, stolen.project_id);
  });
});

