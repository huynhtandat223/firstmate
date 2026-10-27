// Read-only old-source mapping shared by the shadow backfill and reconciler.
// This module owns the proto_data.py hermes mapping; task writes use fm-task.sh.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
export async function table(name) {
  const file = process.env.FM_TASK_TOKEN_FILE || path.join(os.homedir(), '.local/share/cfw-scripts-private/notify-firstmate.token');
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.uid !== process.getuid() || (st.mode & 0o077)) throw new Error('unsafe token file');
  const token = fs.readFileSync(file, 'utf8').trim();
  if (!token || /[\r\n"\\\\]/.test(token)) throw new Error('invalid token file');
  const headers = process.env.FM_TASK_AUTH === 'cookie' ? {cookie: `cfw.auth.session=${token}`} : {authorization: `Bearer ${token}`};
  const rows = [];
  for (let skip = 0; ; skip += 100) {
    const url = `${(process.env.FM_TASK_BASE_URL || 'http://127.0.0.1:5001').replace(/\/$/, '')}/api/${name}?$top=100&$skip=${skip}&$orderby=id`;
    const response = await fetch(url, {headers, signal: AbortSignal.timeout(20000)});
    if (!response.ok) throw new Error(`${name}: HTTP ${response.status}`);
    const page = (await response.json()).value;
    if (!Array.isArray(page)) throw new Error(`${name}: missing rows`);
    rows.push(...page);
    if (page.length < 100) return rows;
  }
}
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
export const here = path.dirname(fileURLToPath(import.meta.url));
export const read = (file) => { try { return fs.readFileSync(file, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return ''; throw e; } };
export const hash = (s) => crypto.createHash('sha256').update(s).digest('hex');
const attr = (s, k) => s.match(new RegExp(`\\(${k}: ((?:[^()]|\\([^()]*\\))*)\\)`))?.[1] || '';
function holdText(s) {
  return s.startsWith('fm-hold-v1:') ? Buffer.from(s.slice(11), 'base64url').toString() : s;
}
export function hermes(t) {
  const hk = t.holdKind;
  if (t.section === 'Done') return {state: 'done', nextActor: 'firstmate', blockKind: null};
  if (t.hold.toLowerCase().includes('verification pending')) return {state: 'review', nextActor: 'tester', blockKind: null};
  if (hk === 'captain') return {state: 'blocked', nextActor: 'owner', blockKind: 'needs-decision'};
  if (t.section === 'In flight') return !hk ? {state: 'running', nextActor: 'worker', blockKind: null} : {state: 'blocked', nextActor: 'firstmate', blockKind: hk === 'external' ? 'external' : 'transient'};
  if (hk === 'parked') return {state: 'triage', nextActor: 'firstmate', blockKind: null};
  if (hk === 'future') return {state: 'todo', nextActor: 'firstmate', blockKind: null};
  if (hk === 'external') return {state: 'blocked', nextActor: 'firstmate', blockKind: 'external'};
  return {state: 'ready', nextActor: 'firstmate', blockKind: null};
}
function crewMapping(home, t) {
  const mapped = hermes(t);
  if (t.section !== 'In flight' || t.holdKind) return mapped;
  const result = spawnSync(process.env.FM_TASK_CREW_STATE || path.join(here, 'fm-crew-state.sh'), [t.id], {
    encoding: 'utf8', timeout: 30000,
    env: {...process.env, FM_HOME: home, FM_STATE_OVERRIDE: path.join(home, 'state'), FM_CREW_STATE_META_OVERRIDE: '', FM_CREW_STATE_STATUS_OVERRIDE: '', FM_CREW_STATE_NO_FORGE: '1'},
  });
  if (result.error || result.status !== 0) throw new Error(`crew-state could not read ${t.id}`);
  const state = result.stdout.match(/^state: ([a-z-]+)/)?.[1];
  if (state === 'done') return {...mapped, state: 'review', nextActor: 'firstmate'};
  if (['blocked', 'failed', 'paused'].includes(state)) {
    const terminal = read(path.join(home, 'state', `${t.id}.status`)).trim().split('\n').at(-1) || '';
    return {...mapped, state: 'blocked', nextActor: 'firstmate', blockKind: state === 'failed' ? 'failure' : terminal.startsWith('needs-decision') ? 'needs-decision' : 'transient'};
  }
  return mapped;
}
export function parseBacklog(home, now = Date.now()) {
  let section = '', cur;
  const rows = [];
  for (const line of read(path.join(home, 'data/backlog.md')).split('\n')) {
    if (line.startsWith('## ')) { section = line.slice(3).trim(); cur = null; continue; }
    const m = line.match(/^- \[[ x]\] ([A-Za-z0-9._-]+) - (.*)$/);
    if (m) {
      const head = m[2];
      cur = {id: m[1], section, title: head.split(/ https?:\/\/| \((?:repo|kind|since|hold|merged|done)\b/)[0].trim(), head, notes: [], repo: attr(head, 'repo'), kind: attr(head, 'kind'), hold: holdText(attr(head, 'hold')), holdKind: attr(head, 'hold-kind'), since: attr(head, 'since'), completed: attr(head, 'done') || attr(head, 'merged')};
      rows.push(cur);
    } else if (cur) cur.notes.push(line);
  }
  return rows.filter(t => t.section !== 'Done' || Date.parse(t.completed) >= now - 30 * 86400000).map(t => {
    const meta = read(path.join(home, 'state', `${t.id}.meta`));
    const assignee = meta.match(/^assignee=(.*)$/m)?.[1] || t.id;
    return {...t, ...crewMapping(home, t), assignee, kind: ['ship', 'scout', 'assistance', 'secondmate', 'plan'].includes(t.kind) ? t.kind : 'other'};
  });
}
export function writer(args, {json = false} = {}) {
  const result = spawnSync(process.env.FM_TASK_WRITER || path.join(here, 'fm-task.sh'), args, {encoding: 'utf8', timeout: 120000});
  if (result.error || result.status !== 0) throw new Error(result.error?.message || result.stderr || result.stdout || 'writer failed');
  return json ? JSON.parse(result.stdout) : result.stdout;
}
export function entries(dir) { try { return fs.readdirSync(dir).sort(); } catch (e) { if (e.code === 'ENOENT') return []; throw e; } }
export function history(home, t, sourceHomes = []) {
  const events = [];
  // Events hold source pointers and digests, never raw status, steer, or note text.
  const add = (source, content, kind = 'comment', url) => {
    if (!content.trim()) return;
    events.push({source, kind, url, digest: hash(content), note: JSON.stringify({source, sha256: hash(content)})});
  };
  add('backlog', t.head + '\n' + t.notes.join('\n'));
  if (t.hold) add('hold', t.hold);
  const status = path.join(home, 'state', `${t.id}.status`);
  read(status).split('\n').filter(Boolean).forEach((line, i) => add(`${status}:${i + 1}`, line));
  for (const dir of [path.join(home, 'state', `${t.id}.inbox`), path.join(home, 'state', `${t.id}.inbox/handled`)]) {
    for (const f of entries(dir).filter(f => f.endsWith('.msg'))) add(`inbox:${f}`, read(path.join(dir, f)), 'steer');
  }
  for (const url of new Set((t.head + '\n' + t.notes.join('\n')).match(/https:\/\/github\.com\/[^\s/]+\/[^\s/]+\/pull\/\d+/g) || [])) add(url, url, 'pr', url);
  const ledger = path.join(home, 'data/deploy-verify/ledger.jsonl');
  for (const line of read(ledger).split('\n').filter(Boolean)) {
    const row = JSON.parse(line);
    if ([row.task, row.taskId, row.id].includes(t.id)) add(ledger, line, 'deploy');
  }
  for (const root of [home, ...sourceHomes]) {
    for (const relative of [`data/${t.id}/notes.md`, `data/plans/${t.id}/decisions.jsonl`, `data/plans/${t.id}/decision.jsonl`, `data/firstmate-board/plans/${t.id}.jsonl`, `data/${t.id}/tester-record.md`, `data/${t.id}/record.md`, `data/${t.id}/verify.md`, `data/verify/${t.id}.md`]) {
      const file = path.join(root, relative);
      add(file, read(file));
    }
  }
  return events;
}
export function options(argv) {
  const opts = {home: process.env.FM_HOME || process.cwd(), now: Date.now(), sourceHomes: []};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--task') opts.task = argv[++i];
    else if (arg === '--home') opts.home = argv[++i];
    else if (arg === '--now') { opts.now = Date.parse(argv[++i]); if (!Number.isFinite(opts.now)) throw new Error('invalid --now'); }
    else if (arg === '--source-home') opts.sourceHomes.push(argv[++i]);
    else if (arg === '--dry-run') opts.dry = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  return opts;
}
