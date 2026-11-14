#!/usr/bin/env node
// Memory on Dev 5001: captain.md, captain-shared.md, learnings.md and memory-archive.md as insert-only fm_doc versions.
// Configuration: FM_TASK_BASE_URL, FM_TASK_TOKEN_FILE and FM_TASK_AUTH match fm-doc.sh; FM_HOME picks the home.
// The 5001 text is the source; data/<file> is a cache plus data/.memory-sync/<file>.base (version and sha256 last pulled).
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

export const FILES = ['captain.md', 'captain-shared.md', 'learnings.md', 'memory-archive.md'];
const RULE_FILES = ['captain.md', 'captain-shared.md', 'learnings.md'];
const GROUP_LIMIT = 400;
const help = `fm-memory.sh seed|pull|put|history|rules|sync [--home NAME] [--data DIR] [--file FILE] [--by ACTOR]
seed     insert version 1 of every local memory file that 5001 lacks; identical text is a no-op.
pull     write each cache file from its current 5001 version; a file with a waiting local edit is kept.
put      insert version n+1 of --file from the cache; refuse with a diff when 5001 moved on; exit 3 on that refusal.
history  list the versions of --file on 5001.
show     print the current 5001 text of --file (or --version N).
rules    print the rule items of the local --file as JSON (no network).
sync     pull the three startup files when config/memory-home exists (not the archive); print one status line; always exit 0.
--rebase (put only) publishes this text on top of the current 5001 version: use it after reconciling a refusal by hand, or on a first cutover when no pull record exists.
--home defaults to the first line of $FM_HOME/config/memory-home; --data defaults to $FM_HOME/data.
Examples: fm-memory.sh put --file learnings.md
          fm-memory.sh history --file captain.md`;

export const sha = (text) => crypto.createHash('sha256').update(text).digest('hex');
const bytesOf = (text) => Buffer.byteLength(text, 'utf8');
const tokensOf = (bytes) => Math.ceil(bytes / 3);

// ---- rule splitter -------------------------------------------------------------------------------------------
const MARKER = /<!--(?:(a|p):(\d{4}-\d{2}-\d{2})(?:\/\d+)?|(P)|(g))-->/;
const TIER = { a: 'aging', p: 'perishable', P: 'pinned', g: 'grace' };
function tierOf(text, fallback) {
  const m = MARKER.exec(text);
  if (!m) return fallback;
  return { tier: TIER[m[1] || m[3] || m[4]], date: m[2] || '' };
}
// Cut one paragraph into sentence groups of at most GROUP_LIMIT characters, never inside backticks or parentheses.
export function sentenceGroups(paragraph, limit = GROUP_LIMIT) {
  const sentences = []; let start = 0, tick = false, depth = 0;
  for (let i = 0; i < paragraph.length; i++) {
    const c = paragraph[i];
    if (c === '`') tick = !tick;
    else if (!tick && c === '(') depth++;
    else if (!tick && c === ')' && depth > 0) depth--;
    else if (!tick && depth === 0 && c === '.' && paragraph[i + 1] === ' ' && !/(?:e\.g|i\.e|vs|etc)$/.test(paragraph.slice(Math.max(0, i - 3), i))) {
      sentences.push(paragraph.slice(start, i + 1)); start = i + 2; i++;
    }
  }
  if (start < paragraph.length) sentences.push(paragraph.slice(start));
  const groups = [];
  for (const sentence of sentences) {
    const last = groups.length - 1;
    if (last >= 0 && groups[last].length + 1 + sentence.length <= limit) groups[last] += ' ' + sentence;
    else groups.push(sentence);
  }
  return groups;
}
export function splitRules(file, text) {
  const fallback = { tier: file === 'learnings.md' ? 'aging' : 'pinned', date: '' };
  const items = []; let section = '', sectionMark = fallback, block = [];
  const flush = () => {
    if (!block.length) return;
    const whole = block.join('\n'); block = [];
    const blockMark = tierOf(whole, sectionMark); // the marker may sit in the last sentence; it governs the whole learning
    const parts = file === 'learnings.md' ? sentenceGroups(whole) : [whole];
    for (const part of parts) {
      const bytes = bytesOf(part), mark = blockMark;
      items.push({ n: items.length + 1, section, text: part, bytes, tokens: tokensOf(bytes), tier: mark.tier, date: mark.date || '' });
    }
  };
  for (const line of text.split('\n')) {
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flush();
      if (heading[1].length >= 2) { section = heading[2].replace(/\s*<!--.*?-->/g, '').trim(); sectionMark = tierOf(heading[2], fallback); }
      continue;
    }
    if (!line.trim()) { flush(); continue; }
    if (/^<!--[^]*-->$/.test(line.trim()) && !MARKER.test(line)) continue; // header pointer comment
    if (/^- /.test(line)) flush();
    block.push(line);
  }
  flush();
  return items;
}

// ---- 5001 access -----------------------------------------------------------------------------------------------
let token, timeoutMs = 20000;
function fail(message, code = 1) { const error = new Error(message); error.code = code; throw error; }
async function http(method, suffix = '', body) {
  if (!token) {
    const file = process.env.FM_TASK_TOKEN_FILE || path.join(os.homedir(), '.local/share/cfw-scripts-private/notify-firstmate.token');
    let stat; try { stat = fs.lstatSync(file); } catch { fail('token file is missing; configure FM_TASK_TOKEN_FILE'); }
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.mode & 0o077) fail('token must be an owner-only regular file');
    token = fs.readFileSync(file, 'utf8').trim();
    if (!token || /[\r\n"\\]/.test(token)) fail('invalid token file');
  }
  const base = (process.env.FM_TASK_BASE_URL || 'http://127.0.0.1:5001').replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) fail('FM_TASK_BASE_URL must use http or https', 2);
  const headers = { accept: 'application/json', 'content-type': 'application/json' };
  if (process.env.FM_TASK_AUTH === 'cookie') headers.cookie = `cfw.auth.session=${token}`; else headers.authorization = `Bearer ${token}`;
  let response;
  try { response = await fetch(`${base}/api/fm_doc${suffix}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(timeoutMs) }); }
  catch { const error = new Error('document service unavailable'); error.code = 'offline'; throw error; }
  if (!response.ok) fail(`document service refused ${method}: HTTP ${response.status}`, response.status === 409 ? 409 : 1);
  if (response.status === 204) return null;
  try { return await response.json(); } catch { fail('document service returned invalid JSON'); }
}
const META = 'id,scope,path,version,kind,source,mediaType,by,at';
async function latest(scope, name, withContent = true) {
  const query = new URLSearchParams({ $top: '1', $orderby: 'version desc', $select: withContent ? META + ',content' : META, $filter: `scope eq '${scope}' and path eq '${name}'` });
  const data = await http('GET', `?${query}`);
  if (!Array.isArray(data.value)) fail('document service returned no collection');
  const row = data.value[0];
  if (!row) return null;
  if (!Number.isSafeInteger(Number(row.version)) || Number(row.version) < 1) fail('document version is invalid');
  if (typeof row.content !== 'string') { const body = await http('GET', `/${encodeURIComponent(row.id)}`); row.content = (body?.data ?? body)?.content; }
  if (typeof row.content !== 'string') fail('document service returned no content');
  return { ...row, version: Number(row.version) };
}
async function insert(scope, name, version, kind, mediaType, content, by) {
  return http('POST', '', { scope, path: name, version, kind, source: '5001', mediaType, content, by, at: new Date().toISOString() });
}

// ---- local cache ------------------------------------------------------------------------------------------------
function baseFile(data, name) { return path.join(data, '.memory-sync', name + '.base'); }
function readBase(data, name) { try { return JSON.parse(fs.readFileSync(baseFile(data, name), 'utf8')); } catch { return null; } }
function writeBase(data, name, scope, version, text) {
  fs.mkdirSync(path.join(data, '.memory-sync'), { recursive: true });
  fs.writeFileSync(baseFile(data, name), JSON.stringify({ scope, version, sha256: sha(text) }) + '\n');
}
function readLocal(data, name) { try { return fs.readFileSync(path.join(data, name), 'utf8'); } catch { return null; } }
function writeLocal(data, name, text) {
  const target = path.join(data, name), tmp = `${target}.memory-${process.pid}`;
  fs.mkdirSync(data, { recursive: true });
  fs.writeFileSync(tmp, text, { mode: 0o644 }); fs.renameSync(tmp, target);
}
function unifiedDiff(winner, local) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fm-memory-diff-'));
  try {
    fs.writeFileSync(path.join(dir, '5001'), winner); fs.writeFileSync(path.join(dir, 'local'), local);
    try { execFileSync('diff', ['-u', '--label', '5001', '--label', 'local', path.join(dir, '5001'), path.join(dir, 'local')], { encoding: 'utf8' }); return ''; }
    catch (error) { return error.stdout || ''; }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}

// ---- commands ---------------------------------------------------------------------------------------------------
async function writeRules(scope, name, version, text, by) {
  if (!RULE_FILES.includes(name)) return;
  const rulesPath = `${name}.rules.json`, content = JSON.stringify(splitRules(name, text));
  try { await insert(scope, rulesPath, version, 'memory', 'application/json', content, by); }
  catch (error) {
    if (error.code !== 409) throw error;
    const existing = await latest(scope, rulesPath);
    if (existing.version !== version || existing.content !== content) fail(`rules row of ${name} version ${version} differs; inspect with history`);
  }
}
async function hasRules(scope, name, version) {
  if (!RULE_FILES.includes(name)) return true;
  const row = await latest(scope, `${name}.rules.json`, false);
  return !!row && row.version >= version;
}
async function seed(ctx) {
  const results = [];
  for (const name of ctx.files) {
    const text = readLocal(ctx.data, name);
    if (text === null) { results.push({ file: name, result: 'no local file' }); continue; }
    const row = await latest(ctx.scope, name);
    if (row) {
      if (row.content !== text) fail(`${name} exists on 5001 at version ${row.version} with different text; pull or put instead of seed`);
      await writeRules(ctx.scope, name, row.version, text, ctx.by);
      writeBase(ctx.data, name, ctx.scope, row.version, text);
      results.push({ file: name, result: 'unchanged', version: row.version }); continue;
    }
    await insert(ctx.scope, name, 1, 'memory', 'text/markdown', text, ctx.by);
    await writeRules(ctx.scope, name, 1, text, ctx.by);
    const back = await latest(ctx.scope, name);
    if (!back || back.content !== text) fail(`readback of ${name} differs after insert`);
    writeBase(ctx.data, name, ctx.scope, 1, text);
    results.push({ file: name, result: 'inserted', version: 1, bytes: bytesOf(text) });
  }
  return results;
}
async function pull(ctx, files = ctx.files) {
  const results = [];
  for (const name of files) {
    const row = await latest(ctx.scope, name);
    if (!row) { results.push({ file: name, result: 'absent on 5001' }); continue; }
    const local = readLocal(ctx.data, name), base = readBase(ctx.data, name);
    if (local !== null && local !== row.content && !(base && base.sha256 === sha(local))) { results.push({ file: name, result: 'kept: local edit waiting for put', version: row.version }); continue; }
    if (local !== row.content) writeLocal(ctx.data, name, row.content);
    writeBase(ctx.data, name, ctx.scope, row.version, row.content);
    results.push({ file: name, result: local === row.content ? 'current' : 'written', version: row.version });
  }
  return results;
}
async function put(ctx) {
  const name = ctx.file, text = readLocal(ctx.data, name); let base = readBase(ctx.data, name);
  if (text === null) fail(`data/${name} does not exist`);
  // A pull record of another home is never published here, also when this home has no row yet.
  const otherHome = () => { if (base && base.scope && base.scope !== ctx.scope && !ctx.rebase) fail(`the pull record of ${name} is for ${base.scope}, not ${ctx.scope}; run fm-memory.sh pull, or put --rebase to publish this text on top of ${ctx.scope}`); };
  const row = await latest(ctx.scope, name);
  if (!row) {
    otherHome();
    await insert(ctx.scope, name, 1, 'memory', 'text/markdown', text, ctx.by);
    await writeRules(ctx.scope, name, 1, text, ctx.by); writeBase(ctx.data, name, ctx.scope, 1, text);
    return { file: name, result: 'inserted', version: 1 };
  }
  if (row.content === text) {
    if (!(await hasRules(ctx.scope, name, row.version))) await writeRules(ctx.scope, name, row.version, text, ctx.by);
    writeBase(ctx.data, name, ctx.scope, row.version, text);
    return { file: name, result: 'unchanged', version: row.version };
  }
  otherHome();
  if (ctx.rebase) base = { version: row.version };
  if (!base) fail(`no pull record for ${name}; run fm-memory.sh pull first, or put --rebase to publish this text on top of version ${row.version}`);
  const refuse = () => { const error = new Error(`5001 holds version ${row.version} of ${name}, but this cache started from version ${base.version}; nothing was written.\n${unifiedDiff(row.content, text)}`); error.code = 3; throw error; };
  if (row.version !== base.version) refuse();
  const next = base.version + 1;
  try { await insert(ctx.scope, name, next, 'memory', 'text/markdown', text, ctx.by); }
  catch (error) { if (error.code !== 409) throw error; const winner = await latest(ctx.scope, name); row.version = winner.version; row.content = winner.content; refuse(); }
  await writeRules(ctx.scope, name, next, text, ctx.by);
  const back = await latest(ctx.scope, name);
  if (!back || back.version !== next || back.content !== text) fail(`readback of ${name} differs after insert`);
  writeBase(ctx.data, name, ctx.scope, next, text);
  return { file: name, result: 'inserted', version: next, bytes: bytesOf(text) };
}
async function history(ctx) {
  const rows = [];
  for (let skip = 0; ; skip += 100) {
    const query = new URLSearchParams({ $top: '100', $skip: String(skip), $orderby: 'version desc', $select: META, $filter: `scope eq '${ctx.scope}' and path eq '${ctx.file}'` });
    const data = await http('GET', `?${query}`); rows.push(...data.value);
    if (data.value.length < 100) return rows.map(r => ({ file: r.path, version: Number(r.version), at: r.at, by: r.by }));
  }
}

function parse(argv) {
  const args = argv.slice(2); const command = args.shift() || '';
  if (!command || command === '--help' || args.includes('--help')) { console.log(help); process.exit(0); }
  if (!['seed', 'pull', 'put', 'history', 'show', 'rules', 'sync'].includes(command)) fail(`unknown command; ${help}`, 2);
  const flags = {};
  while (args.length) {
    const key = args.shift();
    if (key === '--rebase') { flags.rebase = true; continue; }
    if (!['--home', '--data', '--file', '--by', '--version'].includes(key) || args[0] === undefined) fail(`bad argument ${key}; ${help}`, 2);
    flags[key.slice(2)] = args.shift();
  }
  const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE;
  const configDir = process.env.FM_CONFIG_OVERRIDE || (fmHome && path.join(fmHome, 'config'));
  if (!fmHome && !(flags.home && flags.data)) fail('FM_HOME is required unless --home and --data are given', 2);
  let home = flags.home;
  if (!home && fmHome) { try { home = fs.readFileSync(path.join(configDir, 'memory-home'), 'utf8').split('\n')[0].trim(); } catch { home = ''; } }
  if (!home && command !== 'rules') { if (command === 'sync') return { command, off: true }; fail('no memory home: pass --home or create config/memory-home', 2); }
  if (home && !/^[a-z0-9][a-z0-9-]{0,40}$/.test(home)) fail('memory home must be lowercase letters, digits and dashes', 2);
  const secondmate = !!fmHome && fs.existsSync(path.join(fmHome, '.fm-secondmate-home'));
  const files = secondmate ? FILES.filter(f => f !== 'captain-shared.md') : FILES; // inherited from the primary, read-only here
  if (secondmate && flags.file === 'captain-shared.md' && command !== 'rules') fail('captain-shared.md is inherited from the primary home; this secondmate home never reads or writes it on 5001', 2);
  const data = flags.data || process.env.FM_DATA_OVERRIDE || path.join(fmHome, 'data');
  if (flags.file && !FILES.includes(flags.file)) fail(`--file must be one of ${FILES.join(', ')}`, 2);
  if (['put', 'history', 'show', 'rules'].includes(command) && !flags.file) fail('--file is required', 2);
  return { command, home, data, files, scope: `home:${home}`, file: flags.file, rebase: !!flags.rebase, version: flags.version, by: flags.by || process.env.FM_TASK_ACTOR || os.userInfo().username };
}
function print(rows) { for (const r of Array.isArray(rows) ? rows : [rows]) console.log(Object.entries(r).map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(' ')); }

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    const ctx = parse(process.argv);
    if (ctx.command === 'sync') {
      if (ctx.off) process.exit(0);
      timeoutMs = 5000;
      try {
        const rows = await pull(ctx, ctx.files.filter(f => RULE_FILES.includes(f))), waiting = rows.filter(r => r.result.startsWith('kept')).map(r => r.file), wrote = rows.filter(r => r.result === 'written').map(r => r.file);
        console.log(`memory_source=5001 scope=${ctx.scope} ${rows.filter(r => r.version).map(r => `${r.file}=v${r.version}`).join(' ')}${waiting.length ? ` waiting_for_put=${waiting.join(',')}` : ''}${wrote.length ? ` written=${wrote.join(',')}` : ''}`);
      }
      catch (error) {
        let age = 'absent'; try { age = fs.statSync(path.join(ctx.data, 'captain.md')).mtime.toISOString(); } catch {}
        console.log(`memory_source=cache scope=${ctx.scope} cache_written=${age} reason=${JSON.stringify(error.message.split('\n')[0])}`);
      }
    }
    else if (ctx.command === 'rules') { const text = readLocal(ctx.data || '.', ctx.file); if (text === null) fail(`data/${ctx.file} does not exist`); console.log(JSON.stringify(splitRules(ctx.file, text), null, 1)); }
    else if (ctx.command === 'seed') print(await seed(ctx));
    else if (ctx.command === 'pull') print(await pull(ctx));
    else if (ctx.command === 'put') print(await put(ctx));
    else if (ctx.command === 'show') {
      let row;
      if (ctx.version) { const q = new URLSearchParams({ $top: '1', $select: META + ',content', $filter: `scope eq '${ctx.scope}' and path eq '${ctx.file}' and version eq ${Number(ctx.version)}` }); row = (await http('GET', `?${q}`)).value?.[0]; }
      else row = await latest(ctx.scope, ctx.file);
      if (!row) fail(`no such version of ${ctx.file}`);
      process.stdout.write(row.content);
    }
    else print(await history(ctx));
  } catch (error) {
    console.error(`error: ${error.message}${error.code === 'offline' ? '; retry fm-memory.sh ' + process.argv[2] : ''}`);
    process.exitCode = typeof error.code === 'number' ? error.code : 1;
  }
}
