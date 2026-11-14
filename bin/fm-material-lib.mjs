#!/usr/bin/env node
// Private material on Dev 5001: portable config, roles, private skills, the ChatGPT reader notes and the private tools
// as insert-only fm_doc versions (source 5001). Run through bin/fm-doc.sh; see --help.
// Configuration: FM_HOME picks the home; FM_TASK_BASE_URL, FM_TASK_TOKEN_FILE and FM_TASK_AUTH match fm-doc.sh;
// FM_HOST_ID (else config/host-id, else the host name) names this machine.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const help = `fm-doc.sh seed|status|sync|put|remove|materialize --home NAME [--path P] [--rebase] [--record]
seed         insert version 1 of every portable file 5001 does not hold; text that differs on 5001 is reported, not written.
status       one line per portable file (current, waiting-edit, not-seeded, behind, conflict, 5001-only) and one per file found
             in a portable folder that is not on the list (not-portable).
materialize  write every current 5001 version into $FM_HOME; a file with a local edit is kept. --record also writes this
             machine's holdings and the Settings index. Without --home it is the git export of fm-doc.sh (--repo --output).
sync         materialize, then upload local edits that sit on the version they started from; a conflict prints
             material_conflict and keeps the local text. Prints one material_source line; always exits 0.
put          upload the local text of --path as version n+1; refuses with a diff (exit 3) when 5001 moved first.
             --rebase publishes on top of the current 5001 version after you reconciled by hand.
remove       copy the local file of --path to state/material-backup/, insert a tombstone and delete the file.
--home defaults to the first line of $FM_HOME/config/material-home. Exit codes: 3 lost race, 4 secret guard.
The portable list is fixed in this file (PORTABLE below); a new file is never uploaded until a code change names it.`;

// ---- the fixed list ----------------------------------------------------------------------------------------------
const SEGMENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const BAD_NAME = /\.bak|\.pyc$|\.(?:pem|key|p12|pfx)$|token|secret|credential|password/i;
const CONFIG_FILES = new Set(['crew-harness', 'dispatch-plan-gate', 'handoff-thresholds', 'notify-recipient', 'pr-review.json', 'reply-language', 'secondmate-harness', 'startup-memory-budget']);
export const PORTABLE = { configFiles: [...CONFIG_FILES], hostFiles: ['config/claude-account'], configFolders: ['config/assistances', 'config/roles'], skillRoot: '.agents/skills', docs: ['data/chatgpt-review.md'], toolRoot: 'data/firstmate-tools' };
const KINDS = ['config', 'role', 'private-skill', 'doc', 'tool'];
const TOMBSTONE = 'application/x-fm-deleted';
const MAX_BYTES = 1024 * 1024;
const SECRETS = [
  [/Bearer\s+[A-Za-z0-9._~+/=-]{20,}/, 'bearer token'], [/\bgh[pousr]_[A-Za-z0-9]{20,}/, 'GitHub token'], [/\bsk-[A-Za-z0-9_-]{20,}/, 'API key'],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, 'private key'], [/\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}/, 'JWT'],
  [/(?:password|passwd|secret|api[_-]?key|token)["']?\s*[:=]\s*["']?[A-Za-z0-9/+_=.-]{20,}/i, 'credential assignment'],
];
// The only way a path becomes portable. Returns {kind, host} or null.
export function classify(rel) {
  const parts = rel.split('/');
  if (parts.some((part, i) => !(i === 0 && part === '.agents') && !SEGMENT.test(part)) || BAD_NAME.test(rel)) return null;
  if (parts.length === 2 && parts[0] === 'config') {
    if (PORTABLE.hostFiles.includes(rel)) return { kind: 'config', host: true };
    return CONFIG_FILES.has(parts[1]) ? { kind: 'config' } : null;
  }
  if (parts.length === 3 && parts[0] === 'config' && /\.(?:json|md)$/.test(parts[2])) {
    if (parts[1] === 'roles') return { kind: 'role' };
    if (parts[1] === 'assistances') return { kind: 'config' };
  }
  if (parts.length >= 4 && parts[0] === '.agents' && parts[1] === 'skills') return { kind: 'private-skill' };
  if (PORTABLE.docs.includes(rel)) return { kind: 'doc' };
  if (parts.length >= 3 && parts[0] === 'data' && parts[1] === 'firstmate-tools') return { kind: 'tool' };
  return null;
}
export const scanSecret = (text) => (SECRETS.find(([pattern]) => pattern.test(text)) || [])[1] || null;

// ---- helpers ------------------------------------------------------------------------------------------------------
const sha = (text) => crypto.createHash('sha256').update(text).digest('hex');
function fail(message, code = 1) { const error = new Error(message); error.code = code; throw error; }
let timeoutMs = 15000, token;
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
const META = 'id,scope,path,version,kind,mediaType,by,at';
async function rows(filter) {
  const out = [];
  for (let skip = 0; ; skip += 100) {
    const query = new URLSearchParams({ $top: '100', $skip: String(skip), $orderby: 'id', $select: META, $filter: filter });
    const data = await http('GET', `?${query}`);
    if (!Array.isArray(data.value)) fail('document service returned no collection');
    out.push(...data.value);
    if (data.value.length < 100) return out;
  }
}
function newest(list) {
  const latest = new Map();
  for (const row of list) {
    const version = Number(row.version);
    if (!Number.isSafeInteger(version) || version < 1) fail('document version is invalid');
    if (!latest.has(row.path) || latest.get(row.path).version < version) latest.set(row.path, { ...row, version });
  }
  return latest;
}
async function content(row) {
  if (typeof row.content === 'string') return row.content;
  const body = await http('GET', `/${encodeURIComponent(row.id)}`);
  const text = (body?.data ?? body)?.content;
  row.content = typeof text === 'string' ? text : '';
  return row.content;
}
const mediaOf = (rel) => rel.endsWith('.md') ? 'text/markdown' : rel.endsWith('.json') ? 'application/json' : 'text/plain';
const insert = (scope, rel, version, kind, mediaType, text, by) => http('POST', '', { scope, path: rel, version, kind, source: '5001', mediaType, content: text, by, at: new Date().toISOString() });
const quote = (value) => { if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/.test(value)) fail(`unsafe scope part: ${value}`, 2); return `'${value}'`; };

// ---- context ------------------------------------------------------------------------------------------------------
let ctx;
function context(command, flags) {
  const fmHome = process.env.FM_HOME;
  if (!fmHome) fail('FM_HOME is required', 2);
  let home = flags.home;
  if (!home) { try { home = fs.readFileSync(path.join(fmHome, 'config', 'material-home'), 'utf8').split('\n')[0].trim(); } catch { home = ''; } }
  if (!home) { if (command === 'sync') return { off: true }; fail('no material home: pass --home or create config/material-home', 2); }
  if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(home)) fail('material home must be lowercase letters, digits and dashes', 2);
  let host = process.env.FM_HOST_ID;
  if (!host) { try { host = fs.readFileSync(path.join(fmHome, 'config', 'host-id'), 'utf8').trim(); } catch { host = os.hostname(); } }
  quote(host);
  return { fmHome, home, host, scope: `home:${home}`, hostScope: `host:${host}`, by: process.env.FM_TASK_ACTOR || os.userInfo().username, flags, state: path.join(fmHome, 'state', 'material-sync.json') };
}
const scopeOf = (rel) => classify(rel)?.host ? ctx.hostScope : ctx.scope;
function loadState() { try { return JSON.parse(fs.readFileSync(ctx.state, 'utf8')); } catch { return {}; } }
function saveState(state) { fs.mkdirSync(path.dirname(ctx.state), { recursive: true }); const tmp = `${ctx.state}.${process.pid}`; fs.writeFileSync(tmp, JSON.stringify(state, null, 1) + '\n'); fs.renameSync(tmp, ctx.state); }
function readLocal(rel) { try { return fs.readFileSync(path.join(ctx.fmHome, rel), 'utf8'); } catch { return null; } }
function writeLocal(rel, text) {
  const target = path.join(ctx.fmHome, rel), tmp = `${target}.material-${process.pid}`;
  const mode = rel === 'config/claude-account' ? 0o600 : text.startsWith('#!') ? 0o755 : 0o644;
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(tmp, text, { mode }); fs.chmodSync(tmp, mode); fs.renameSync(tmp, target);
}
function backup(rel) {
  const source = path.join(ctx.fmHome, rel);
  if (!fs.existsSync(source)) return null;
  const target = path.join(ctx.fmHome, 'state', 'material-backup', new Date().toISOString().replace(/[:.]/g, '-'), rel);
  fs.mkdirSync(path.dirname(target), { recursive: true }); fs.copyFileSync(source, target);
  return target;
}
function unifiedDiff(winner, local) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fm-material-diff-'));
  try {
    fs.writeFileSync(path.join(dir, '5001'), winner); fs.writeFileSync(path.join(dir, 'local'), local);
    try { execFileSync('diff', ['-u', '--label', '5001', '--label', 'local', path.join(dir, '5001'), path.join(dir, 'local')], { encoding: 'utf8' }); return ''; }
    catch (error) { return error.stdout || ''; }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
function git(...args) { try { return execFileSync('git', ['-C', ctx.fmHome, ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); } catch { return null; } }

// ---- local discovery ----------------------------------------------------------------------------------------------
// entries: portable files with their text; skipped: files in a portable folder the list does not take, with the reason.
function discover() {
  const entries = [], skipped = [];
  const add = (rel) => {
    const abs = path.join(ctx.fmHome, rel), stat = fs.lstatSync(abs);
    const info = classify(rel);
    if (!stat.isFile()) return skipped.push({ path: rel, reason: 'not a regular file' });
    if (!info) return /\.bak|^\./.test(path.basename(rel)) ? undefined : skipped.push({ path: rel, reason: 'not on the portable list' });
    if (stat.size > MAX_BYTES) return skipped.push({ path: rel, reason: 'larger than 1 MiB' });
    const bytes = fs.readFileSync(abs), text = bytes.toString('utf8');
    if (bytes.includes(0) || !Buffer.from(text).equals(bytes)) return skipped.push({ path: rel, reason: 'not text' });
    entries.push({ path: rel, ...info, scope: info.host ? ctx.hostScope : ctx.scope, text });
  };
  const walk = (rel) => {
    const abs = path.join(ctx.fmHome, rel);
    let names; try { names = fs.readdirSync(abs).sort(); } catch { return; }
    for (const name of names) {
      const child = `${rel}/${name}`, stat = fs.lstatSync(path.join(ctx.fmHome, child));
      if (stat.isDirectory() && SEGMENT.test(name) && name !== '__pycache__') walk(child);
      else if (name === '__pycache__' || name.startsWith('.')) continue;
      else if (stat.isDirectory() || stat.isSymbolicLink()) skipped.push({ path: child, reason: 'folder or link the list does not take' });
      else add(child);
    }
  };
  let top; try { top = fs.readdirSync(path.join(ctx.fmHome, 'config')).sort(); } catch { top = []; }
  for (const name of top) {
    const rel = `config/${name}`, stat = fs.lstatSync(path.join(ctx.fmHome, rel));
    if (stat.isDirectory() && PORTABLE.configFolders.includes(rel)) walk(rel);
    else if (stat.isDirectory()) skipped.push({ path: rel, reason: 'machine-only folder' });
    else add(rel);
  }
  for (const rel of PORTABLE.docs) if (fs.existsSync(path.join(ctx.fmHome, rel))) add(rel);
  if (fs.existsSync(path.join(ctx.fmHome, PORTABLE.toolRoot))) walk(PORTABLE.toolRoot);
  // A private skill is a top-level skill folder in which git tracks nothing; without git nothing is taken.
  let skills = []; try { skills = fs.readdirSync(path.join(ctx.fmHome, PORTABLE.skillRoot)).sort(); } catch {}
  for (const name of skills) {
    const rel = `${PORTABLE.skillRoot}/${name}`, stat = fs.lstatSync(path.join(ctx.fmHome, rel));
    if (!stat.isDirectory() || !SEGMENT.test(name)) continue;
    const tracked = git('ls-files', '--', rel);
    if (tracked === null) skipped.push({ path: rel, reason: 'cannot tell without git whether the skill is private' });
    else if (tracked.trim()) continue;
    else walk(rel);
  }
  return { entries, skipped };
}
function guardSecrets(entries) {
  const hits = [];
  for (const entry of entries) { const found = scanSecret(entry.text); if (found) hits.push(`${entry.path} (${found})`); }
  if (hits.length) fail(`secret guard: nothing uploaded; remove or rename ${hits.join(', ')}`, 4);
}

// ---- 5001 state ---------------------------------------------------------------------------------------------------
async function remoteCurrent() {
  const kinds = KINDS.map(kind => `kind eq '${kind}'`).join(' or ');
  const home = newest(await rows(`scope eq ${quote(ctx.scope)} and (${kinds})`));
  const host = newest(await rows(`scope eq ${quote(ctx.hostScope)} and kind eq 'config'`));
  return new Map([...home, ...host]);
}
const live = (row) => row && row.mediaType !== TOMBSTONE;

async function recordHoldings(map) {
  const rel = `holdings/${ctx.home}.json`, text = JSON.stringify(Object.fromEntries(Object.entries(map).sort()));
  const list = await rows(`scope eq ${quote(ctx.hostScope)} and path eq '${rel}'`);
  const last = newest(list).get(rel);
  if (last && (await content(last)) === text) return;
  try { await insert(ctx.hostScope, rel, (last?.version || 0) + 1, 'holding', 'application/json', text, ctx.by); }
  catch (error) { if (error.code !== 409) throw error; }
}
async function rebuildIndex() {
  const remote = await remoteCurrent();
  const holdingRows = newest((await rows(`kind eq 'holding' and path eq 'holdings/${ctx.home}.json'`)).filter(r => /^host:/.test(r.scope)).map(r => ({ ...r, path: r.scope }))); // newest holdings per host
  const holders = [];
  for (const row of holdingRows.values()) { try { holders.push({ host: row.path.slice(5), map: JSON.parse(await content(row)) }); } catch {} }
  const hostConfig = new Map();
  for (const holder of holders) {
    const pin = newest(await rows(`scope eq ${quote('host:' + holder.host)} and kind eq 'config'`)).get('config/claude-account');
    if (live(pin)) hostConfig.set(holder.host, pin);
  }
  const lines = [];
  for (const row of remote.values()) if (live(row) && row.scope === ctx.scope) lines.push({ path: row.path, kind: row.kind, version: row.version, holders: holders.filter(h => h.map[row.path] !== undefined).map(h => `${h.host}=v${h.map[row.path]}`) });
  for (const [host, pin] of hostConfig) lines.push({ path: `config/claude-account (${host})`, kind: pin.kind, version: pin.version, holders: holders.filter(h => h.host === host && h.map['config/claude-account'] !== undefined).map(h => `${h.host}=v${h.map['config/claude-account']}`) });
  const text = JSON.stringify(lines.sort((a, b) => a.path.localeCompare(b.path)).map(l => ({ path: l.path, kind: l.kind, version: l.version, machines: l.holders.join(', ') })));
  const rel = 'settings.index.json';
  for (let attempt = 0; attempt < 3; attempt++) {
    const last = newest(await rows(`scope eq ${quote(ctx.scope)} and path eq '${rel}'`)).get(rel);
    if (last && (await content(last)) === text) return;
    try { await insert(ctx.scope, rel, (last?.version || 0) + 1, 'index', 'application/json', text, ctx.by); return; }
    catch (error) { if (error.code !== 409) throw error; }
  }
}
async function publishRecord(state) {
  const holdings = {};
  for (const [key, base] of Object.entries(state)) { const rel = key.split('\u0000')[1]; if (base.exists !== false && rel) holdings[rel] = base.version; }
  await recordHoldings(holdings); await rebuildIndex();
}
const keyOf = (scope, rel) => `${scope}\u0000${rel}`;

// ---- commands -----------------------------------------------------------------------------------------------------
async function putOne(entry, remote, state, { rebase = false } = {}) {
  const found = scanSecret(entry.text);
  if (found) fail(`secret guard: ${entry.path} (${found}); nothing uploaded`, 4);
  const row = remote.get(entry.path), key = keyOf(entry.scope, entry.path), base = state[key];
  if (live(row) && (await content(row)) === entry.text) { state[key] = { version: row.version, sha256: sha(entry.text) }; return { path: entry.path, result: 'unchanged', version: row.version }; }
  if (!row) { await insert(entry.scope, entry.path, 1, entry.kind, mediaOf(entry.path), entry.text, ctx.by); state[key] = { version: 1, sha256: sha(entry.text) }; return { path: entry.path, result: 'inserted', version: 1 }; }
  const known = rebase ? { version: row.version } : base;
  if (!known) fail(`no pull record for ${entry.path}; run materialize first, or put --rebase to publish on top of version ${row.version}`, 3);
  const refuse = (winner) => { const error = new Error(`5001 holds version ${winner.version} of ${entry.path}, but this copy started from version ${known.version}; nothing was written.\n${unifiedDiff(winner.content ?? '', entry.text)}`); error.code = 3; throw error; };
  if (row.version !== known.version) { await content(row); refuse(row); }
  const next = row.version + 1;
  try { await insert(entry.scope, entry.path, next, entry.kind, mediaOf(entry.path), entry.text, ctx.by); }
  catch (error) { if (error.code !== 409) throw error; const winner = newest(await rows(`scope eq ${quote(entry.scope)} and path eq '${entry.path}'`)).get(entry.path); await content(winner); refuse(winner); }
  state[key] = { version: next, sha256: sha(entry.text) };
  return { path: entry.path, result: 'inserted', version: next };
}
async function seed() {
  const { entries } = discover(); guardSecrets(entries);
  const remote = await remoteCurrent(), state = loadState(), results = [];
  for (const entry of entries) {
    const row = remote.get(entry.path);
    if (live(row) && (await content(row)) !== entry.text) { results.push({ path: entry.path, result: 'differs on 5001: use put', version: row.version }); continue; }
    if (row && !live(row)) { results.push(await putOne(entry, remote, state, { rebase: true })); continue; }
    results.push(await putOne(entry, remote, state));
  }
  saveState(state); await publishRecord(state);
  return results;
}
// Pull every current 5001 version; with upload, also push local edits and new portable files.
async function pull({ upload }) {
  const remote = await remoteCurrent(), state = loadState(), results = [], conflicts = [];
  for (const row of remote.values()) {
    const info = classify(row.path);
    if (!info || !!info.host !== (row.scope === ctx.hostScope)) { results.push({ path: row.path, result: 'refused path' }); continue; }
    if (info.kind === 'private-skill') {
      const skill = row.path.split('/').slice(0, 3).join('/'), tracked = git('ls-files', '--', skill);
      if (tracked && tracked.trim()) { results.push({ path: row.path, result: 'refused: tracked skill' }); continue; }
    }
    const key = keyOf(row.scope, row.path), base = state[key], local = readLocal(row.path);
    if (!live(row)) {
      if (local !== null && base && sha(local) === base.sha256) { const saved = backup(row.path); fs.rmSync(path.join(ctx.fmHome, row.path)); results.push({ path: row.path, result: 'removed', backup: saved }); }
      else if (local !== null) results.push({ path: row.path, result: 'kept: local file differs from the removed version' });
      if (base) state[key] = { version: row.version, sha256: base.sha256, exists: false };
      continue;
    }
    if (local !== null && base && base.version === row.version && sha(local) === base.sha256) { results.push({ path: row.path, result: 'current', version: row.version }); continue; }
    const text = await content(row);
    if (local === text) { state[key] = { version: row.version, sha256: sha(text) }; results.push({ path: row.path, result: 'current', version: row.version }); continue; }
    if (local === null || (base && sha(local) === base.sha256)) {
      writeLocal(row.path, text); state[key] = { version: row.version, sha256: sha(text) };
      if (info.kind === 'private-skill') excludeSkill(row.path.split('/')[2]);
      results.push({ path: row.path, result: 'written', version: row.version }); continue;
    }
    if (!upload) { results.push({ path: row.path, result: 'kept: local edit waiting for put', version: row.version }); continue; }
    if (base && base.version === row.version) {
      try { results.push(await putOne({ path: row.path, kind: row.kind, scope: row.scope, text: local }, remote, state)); }
      catch (error) { if (error.code !== 3 && error.code !== 4) throw error; conflicts.push({ path: row.path, reason: error.message.split('\n')[0] }); results.push({ path: row.path, result: 'conflict' }); }
    } else { conflicts.push({ path: row.path, reason: base ? `5001 moved to version ${row.version} while this copy started from ${base.version}` : 'no pull record for a local file that differs from 5001' }); results.push({ path: row.path, result: 'conflict' }); }
  }
  if (upload) {
    for (const entry of discover().entries) {
      if (remote.has(entry.path)) continue;
      try { results.push(await putOne(entry, remote, state)); }
      catch (error) { if (error.code !== 4) throw error; conflicts.push({ path: entry.path, reason: error.message.split('\n')[0] }); }
    }
  }
  saveState(state);
  return { results, conflicts, state };
}
function excludeSkill(name) {
  const exclude = git('rev-parse', '--git-path', 'info/exclude');
  if (!exclude || git('check-ignore', '-q', '--', `${PORTABLE.skillRoot}/${name}/SKILL.md`) !== null) return;
  const file = path.resolve(ctx.fmHome, exclude.trim()), line = `/${PORTABLE.skillRoot}/${name}/`;
  fs.mkdirSync(path.dirname(file), { recursive: true });
  let text = ''; try { text = fs.readFileSync(file, 'utf8'); } catch {}
  if (!text.split('\n').includes(line)) fs.appendFileSync(file, (text && !text.endsWith('\n') ? '\n' : '') + line + '\n');
}
async function status() {
  const { entries, skipped } = discover(), remote = await remoteCurrent(), state = loadState(), lines = [];
  for (const entry of entries) {
    const row = remote.get(entry.path), base = state[keyOf(entry.scope, entry.path)];
    let result;
    if (!live(row)) result = 'not-seeded';
    else if ((await content(row)) === entry.text) result = 'current';
    else if (!base) result = 'conflict';
    else if (sha(entry.text) === base.sha256) result = 'behind';
    else result = base.version === row.version ? 'waiting-edit' : 'conflict';
    lines.push({ path: entry.path, kind: entry.kind, state: result, remote: row?.version ?? null });
  }
  const local = new Set(entries.map(e => e.path));
  for (const [rel, row] of remote) if (live(row) && !local.has(rel)) lines.push({ path: rel, kind: row.kind, state: '5001-only', remote: row.version });
  for (const item of skipped) lines.push({ path: item.path, state: 'not-portable', reason: item.reason });
  return lines;
}
async function put() {
  if (!ctx.flags.path) fail('--path is required', 2);
  const info = classify(ctx.flags.path); if (!info) fail(`${ctx.flags.path} is not a portable path`, 2);
  const text = readLocal(ctx.flags.path); if (text === null) fail(`${ctx.flags.path} does not exist`, 2);
  const remote = await remoteCurrent(), state = loadState();
  const result = await putOne({ path: ctx.flags.path, kind: info.kind, scope: scopeOf(ctx.flags.path), text }, remote, state, { rebase: !!ctx.flags.rebase });
  saveState(state); await publishRecord(state); return result;
}
async function remove() {
  if (!ctx.flags.path) fail('--path is required', 2);
  const info = classify(ctx.flags.path); if (!info) fail(`${ctx.flags.path} is not a portable path`, 2);
  const remote = await remoteCurrent(), row = remote.get(ctx.flags.path);
  if (!live(row)) fail(`${ctx.flags.path} is not on 5001`, 2);
  const saved = backup(ctx.flags.path);
  await insert(scopeOf(ctx.flags.path), ctx.flags.path, row.version + 1, info.kind, TOMBSTONE, '', ctx.by);
  fs.rmSync(path.join(ctx.fmHome, ctx.flags.path), { force: true });
  const state = loadState(); state[keyOf(scopeOf(ctx.flags.path), ctx.flags.path)] = { version: row.version + 1, sha256: '', exists: false }; saveState(state);
  await publishRecord(state);
  return { path: ctx.flags.path, result: 'removed', version: row.version + 1, backup: saved };
}

// ---- entry --------------------------------------------------------------------------------------------------------
export async function main(command, args) {
  if (command === '--help' || args.includes('--help')) { console.log(help); return; }
  const flags = {};
  while (args.length) {
    const key = args.shift();
    if (key === '--rebase' || key === '--record') { flags[key.slice(2)] = true; continue; }
    if (!['--home', '--path'].includes(key) || args[0] === undefined) fail(`bad argument ${key}; ${help}`, 2);
    flags[key.slice(2)] = args.shift();
  }
  ctx = context(command, flags);
  if (ctx.off) return;
  const print = (list) => { for (const item of Array.isArray(list) ? list : [list]) console.log(Object.entries(item).map(([k, v]) => `${k}=${JSON.stringify(v)}`).join(' ')); };
  if (command === 'sync') {
    timeoutMs = 5000;
    try {
      const { results, conflicts, state } = await pull({ upload: true });
      for (const c of conflicts) console.log(`material_conflict path=${JSON.stringify(c.path)} reason=${JSON.stringify(c.reason)}`);
      await publishRecord(state);
      const count = (name) => results.filter(r => r.result === name).length;
      console.log(`material_source=5001 home=${ctx.home} files=${results.filter(r => r.version).length} written=${count('written') + count('removed')} uploaded=${count('inserted')} waiting=${results.filter(r => r.result.startsWith('kept')).length} conflicts=${conflicts.length}`);
    } catch (error) {
      let age = 'absent'; try { age = fs.statSync(ctx.state).mtime.toISOString(); } catch {}
      console.log(`material_source=cache home=${ctx.home} cache_written=${age} reason=${JSON.stringify(error.message.split('\n')[0])}`);
    }
    return;
  }
  if (command === 'materialize') { const { results, state } = await pull({ upload: false }); if (flags.record) await publishRecord(state); print(results); }
  else if (command === 'seed') print(await seed());
  else if (command === 'status') print(await status());
  else if (command === 'put') print(await put());
  else if (command === 'remove') print(await remove());
  else fail(`unknown command; ${help}`, 2);
}
if (import.meta.url === `file://${process.argv[1]}`) {
  try { await main(process.argv[2] || '--help', process.argv.slice(3)); }
  catch (error) { console.error(`error: ${error.message}${error.code === 'offline' ? '; retry fm-doc.sh ' + process.argv[2] : ''}`); process.exitCode = typeof error.code === 'number' ? error.code : 1; }
}
