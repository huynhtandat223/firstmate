#!/usr/bin/env node
// The one writer and reader of the task contract (spec huynhtandat223/cfw-modules#1675).
// bin/fm-task.sh runs this file. The record is ten API Builder tables on Dev 5001
// (docs/fm-task-contract/definitions.json in cfw-modules): fm_task, fm_task_event, the event
// children fm_event_done / fm_event_question / fm_event_block / fm_event_image, fm_task_check,
// fm_owner_check, fm_task_link and fm_task_delivery. This file adds no table and no grant.
//
// Usage: fm-task.sh <command> [<positional>...] [--flag value ...]
//   A <task> comes from the first positional (the second for `block`), --task, or FM_TASK_ID.
//   create   <task> --title T --kind ship|scout|assistance|secondmate|plan|other [--repo R] [--issue URL]
//            [--surface user-visible|internal] [--after PARENT]...
//   import   <task> --title T --kind K --state S --assignee A --next-actor N [--repo R] [--issue U] [--pr-url U] [--surface S]
//            [--block-kind K --block-reason R] [--until ISO] [--since ISO]   the backfill: a task at the state an old source holds, once
//   assign   <task> --to ASSIGNEE            triage|todo|ready -> ready (todo while a parent is open)
//   reassign <task> --to ASSIGNEE --reason WHY  changes only assignee; refused from done and archived
//   start    <task>                          ready -> running
//   heartbeat <task> [--note N]              running (today's `working:`)
//   done     <task> --summary --changed-files --verification --residual-risk [--rows JSON]
//            [--pr-url U] [--head H] [--next-actor tester|firstmate]       running -> review
//            [--document FILE] [--document-title TITLE] attaches one documents child in the same request.
//            Document: UTF-8 .md/.markdown or .html/.htm, 1 byte to 2 MiB; one-line title 1..200
//            characters (default file name). Invalid files/options exit 2 before any API write.
//   ask      <task> --question Q --option O (2 to 6 times) --recommendation R --why W
//            [--document D] [--next-actor firstmate|owner]                  running -> blocked (needs-decision)
//   block    <kind> <task> --reason R --next-actor A [--until ISO] [--on PARENT]
//            kind: transient|dependency|external|credential|failure; running -> blocked,
//            a dependency waits in todo on --on PARENT; a third block of one kind goes to triage.
//            A transient block is refused while the task's PR still runs checks on its current head,
//            naming the wait below: a blocked record only firstmate clears, so a CI wait is declared instead.
//            An unreadable forge never refuses, because blocking is what a worker needs then.
//   unblock  <task>                          blocked|triage -> ready
//   approve  <task>                          review -> done (refused while a check row is pending or failed, and
//            on a task with a deploy event until its user-visible rows pass on a deployed head)
//   changes  <task> --note WHY               review -> ready
//   reopen   <task> --reason WHY             done -> ready, next actor firstmate; archived stays final
//   archive  <task>                          triage|todo|ready|blocked|review|done -> archived
//   describe <task> --document FILE.md [--document-title T]              any state; default title Description
//   thread   <task> [--since SEQ]                                       full comments, oldest first
//   comment  <task> --note T [--image PATH --image-label L]... [--ask why|how|wait-what] [--reply-to SEQ]
//            any state; reply-to must name a comment of this task
//   event    <task> <kind> [--note N] [--pr-url U] [--head H]   kinds: steer comment pr deploy ci protocol_violation
//            divergence; --head on deploy (the deployed head, which user-visible passes count on from then) or on ci
//            (the head the CI result read); no other kind takes it
//   event    <task> wait --next-actor tester|owner|merge|ci --clears-on rows|answer|merge|ci --note WHY [--rows ID@W,...]
//            a declared wait (G1); `ask --next-actor owner` (answer) and `done --pr-url` (rows on the Tester, else merge)
//            write one too. Its status line is `paused [at=E] [key=wait-<seq>]: waiting on <actor>: WHY (clears on X)`; the
//            clearing event (the asked rows each with a newer result that is not pending, an unblocked event, a pr event whose
//            note says merged, a ci event, or an approved or archived event) adds `resolved` with that key, in the home
//            holding the line. `wait --next-actor ci --clears-on ci` is how a worker waits for its PR's checks: the
//            pr-review source writes the ci event for the current head, green or failed, and delivers a failure to the inbox.
//            deploy --touched none|all|ID,...: the scenarios the deployed PRs name (`Scenarios touched:`); a user-visible pass
//            on an earlier deployed head carries to later deployed heads while no later deploy names its id (all, or no
//            flag, names every id). approve, routing and gate accept a carried pass; gate prints each with its head.
//   checks   <task> [--as-deployed HEAD [--touched IDS]]   read only: JSON of the open rows with their newest values,
//            `carried`, and `due` (the Tester checks it on the head); --as-deployed reads as if HEAD were deployed next
//   link     <parent> <child>                the child waits in todo while the parent is open
//   rows     <task> [task:<id>|issue-url] [--surface all|user-visible]   defaults to the task Description; one check row per scenario x width from
//            fm-acceptance.mjs; user-visible adds, resets and retires the Tester's rows only
//   check    <task> <id>@<width> pass|fail|pending [--evidence E] [--head H] [--next-actor A]
//            (--status S is the same as the result word); next actor firstmate on a pass, worker on a fail;
//            with --role owner a pass or fail also sets the row's owner item (status, decidedAt, note = --evidence)
//   owner-check <task> <id>@<width> --page-title --url --steps --data --expected   (sets next actor owner;
//            a row that has an item needs --url and --steps again; a re-sent --key never writes the item twice)
//   gate     <task> [--issue task:<id>|URL] --head SHA [--evidence-root DIR]   defaults to the task Description; read only: prints each reason the task is not
//            complete (exit 5): a user-visible row of the issue not pass on the deployed head with its current
//            digest and evidence, or no approved event newer than the last row event (bin/fm-verify-gate-lib.sh)
//   turn-end <task> --turn TOKEN             check a durable turn generation; heartbeat is not terminal
//   deliver  <task> --consumer NAME           claim each event in fm_task_delivery, then append a wake
//            FM_HOME is required; delivery is scoped to this task, never a whole foreign fleet.
//            A crash between claim and queue append requires operator reconciliation (no duplicate claim).
//            a row that has an item needs all five template fields again; a re-sent --key never writes the item twice)
//   row      <task> --section S --row-file F --notes-file F [--file BACKLOG] | --gone   one backlog row, verbatim: the
//            header after the checkbox (one line, starting "<task> - "), the lines under it (each ending in a newline)
//            and its section, in the view of BACKLOG (default as for backlog below), which is then synced with that
//            row taken from the record; --gone takes it out of that view. Text over one event body goes in a documents child.
//   backlog  sync|render [--file BACKLOG] [--out F] [--absorb-only]   the backlog view (T7): sync writes every row the
//            file holds differently to the record (a task the record lacks is imported first), then renders the file
//            from the record (--absorb-only leaves the file); render prints or writes (--out) the view only. BACKLOG defaults to FM_DATA_OVERRIDE, else
//            $FM_HOME/data, /backlog.md. Line 1 names the record; the checkbox is [x] in Done; in a section the rows
//            follow the event that put them there, In flight and Done newest first, other sections oldest first. A
//            line outside a row other than a blank one refuses the sync (exit 5) after the import, file unchanged.
//            The record is shared by every home: a view holds and changes only the rows its own file wrote. A sync and
//            a row call of one file each hold an exclusive lock on <file>.view-lock (perl's flock) while they run.
//   show     <task> [--json]   list [--state S] [--actor A] [--json]   resume <task>   reproject <task> | --all
//            reproject --all folds every task row again (the board card's step fields too) and prints each repair.
// Every write takes --key K (the idempotency key; a re-send returns the first event), --actor NAME
// (default FM_TASK_ACTOR, FM_TASK_ID, then the login name) and --role (default FM_TASK_ROLE, then the
// command's own: worker for start/heartbeat/done/ask/block, tester for check, firstmate for the rest).
//
// Writes print `seq=<n> task=<id> event=<kind> state=<state> next=<actor>`. A terminal call (done, ask,
// block) and its template child go in one deep-insert request, so the API refuses a missing or over-long
// field (400) and stores nothing; the refusal prints the API's field. The writer checks what the API
// cannot: the value lists (states, kinds, actors, roles), an empty value, 2 to 6 options, and the
// transitions below.
//
// Every new event body carries stage from the existing fold after that event; old events are not backfilled.
// Event log and projection. `seq` is global: the writer reads the highest, creates seq + 1 under the unique
// key and retries on 409 (reading the task's events again each time, so a transition is checked against the
// events that are really before it). Each event body is JSON {"v":1,"note":...,"set":{...}} and `set` holds
// the task fields the event changes. fm_task is the projection: the fold of every `set` in seq order. After
// each event the writer folds again and patches the row; `reproject` does the same on demand and creates a
// missing row. Tasks start in triage (todo while a parent is open); the state of each command is the table
// below.
//
// Exit codes: 0 done; 2 usage or configuration; 3 the API did not answer (an event whose answer was lost is
// looked up by its key first, so nothing is stored twice; a re-run with the same --key is safe); 4 the API
// refused the request; 5 a writer rule refused it (transition, value list, open rows, pairing).
//
// Environment: FM_TASK_BASE_URL (default http://127.0.0.1:5001); FM_TASK_TOKEN_FILE (default
// ~/.local/share/cfw-scripts-private/notify-firstmate.token: a private file you own, as agent-ask reads it);
// FM_TASK_AUTH=bearer|cookie (cookie sends the token as the cfw.auth.session cookie, for a SysAdmin session
// until the notify-firstmate grant lands); FM_TASK_ACCEPTANCE (the acceptance parser, default fm-acceptance.mjs
// beside this file). The token is read from the file and sent as a header, never printed.
// FM_HOME (and optional FM_STATE_OVERRIDE, FM_DATA_OVERRIDE) selects the views and the durable turn cursor. Terminal
// calls, heartbeat and unblock append their line to state/<task>.status (a file the writer creates starts with a line
// that names the record); a deploy event with a head and an approved event add `deployed: <head>` and `approved:
// firstmate <epoch>` to a data/<task>/verify.md that holds `record: rows`. A --key replay adds no second line.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { attr, hermes, holdText } from './fm-task-sources-lib.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));

// ---- the value lists the API cannot check ---------------------------------------------------------------
const STATES = ['triage', 'todo', 'ready', 'running', 'blocked', 'review', 'done', 'archived'];
const TASK_KINDS = ['ship', 'scout', 'assistance', 'secondmate', 'plan', 'other'];
const SURFACES = ['user-visible', 'internal'];
const ACTORS = ['worker', 'tester', 'firstmate', 'owner'];
const ROLES = ['worker', 'firstmate', 'tester', 'planner', 'owner', 'assistance', 'system'];
const BLOCK_KINDS = ['transient', 'dependency', 'external', 'credential', 'failure'];
const CHECK_STATUSES = ['pending', 'pass', 'fail'];
const FREE_KINDS = ['steer', 'comment', 'pr', 'deploy', 'ci', 'protocol_violation', 'divergence'];
const WAIT_ACTORS = ['tester', 'owner', 'merge', 'ci'];
const WAIT_CLEARS = ['rows', 'answer', 'merge', 'ci'];
const CLOSED = ['done', 'archived'];

// command -> the states it may run from (the Hermes transitions)
const TRANSITIONS = {
  assign: ['triage', 'todo', 'ready'],
  reassign: ['triage', 'todo', 'ready', 'running', 'blocked', 'review'],
  start: ['ready'],
  heartbeat: ['running'],
  done: ['running'],
  ask: ['running'],
  block: ['running'],
  unblock: ['triage', 'blocked'],
  approve: ['review'],
  changes: ['review'],
  reopen: ['done'],
  archive: ['triage', 'todo', 'ready', 'blocked', 'review', 'done'],
  comment: STATES,
};

// the fm_task columns the projection holds, with the lengths the API enforces on them
const LIMITS = { title: 300, repo: 200, kind: 32, state: 32, assignee: 64, nextActor: 32, blockKind: 32, blockReason: 2000, issueUrl: 2048, prUrl: 2048, surface: 32, section: 32 };
const PROJECTED = ['acceptanceDigest', 'title', 'repo', 'kind', 'state', 'assignee', 'nextActor', 'blockKind', 'blockReason', 'blockRepeats', 'issueUrl', 'prUrl', 'surface', 'holdUntil', 'row', 'notes', 'section', 'lastSeq',
  'stage', 'stageSince', 'lastEventAt', 'lastNote', 'reviewer'];
// The board card's step (cfw-modules#1678 change 199): the writer owns the rule and the page only reads it.
const STEP_OF_STATE = { triage: 'queued', todo: 'queued', ready: 'queued', done: 'passed' };
const REVIEWER_KINDS = ['check', 'owner-check', 'approved', 'changes'];
const DATE_FIELDS = ['holdUntil', 'stageSince', 'lastEventAt'];
// the backlog row's text: kept in the record verbatim, too long and multi-line for `show`'s field=value lines
const ROW_TEXT = ['row', 'notes'];
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
const MAX_ATTEMPTS = 300;
const IMAGE_TYPES = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' };
const MAX_IMAGE = 2 * 1024 * 1024;

class Fail extends Error {
  constructor(code, message, extra = {}) {
    super(message);
    this.code = code;
    Object.assign(this, extra);
  }
}
const usage = (m) => new Fail(2, m);
const rule = (m) => new Fail(5, m);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---- the API ----------------------------------------------------------------------------------------------
function readToken() {
  const file = process.env.FM_TASK_TOKEN_FILE || path.join(os.homedir(), '.local', 'share', 'cfw-scripts-private', 'notify-firstmate.token');
  let info;
  try {
    info = fs.lstatSync(file);
  } catch {
    throw usage(`the token file is missing: ${file}`);
  }
  if (!info.isFile() || info.uid !== process.getuid() || info.mode & 0o077) throw usage('the token must be a regular file you own, with no group or other permissions');
  const token = fs.readFileSync(file, 'utf8').trim();
  if (!token || /[\r\n"\\]/.test(token)) throw usage('the token file does not hold a token');
  return token;
}

let TOKEN;
async function http(method, pathname, body) {
  const base = (process.env.FM_TASK_BASE_URL || 'http://127.0.0.1:5001').replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) throw usage('FM_TASK_BASE_URL must use http or https');
  TOKEN ??= readToken();
  const headers = { accept: 'application/json' };
  if ((process.env.FM_TASK_AUTH || 'bearer') === 'cookie') headers.cookie = `cfw.auth.session=${TOKEN}`;
  else headers.authorization = `Bearer ${TOKEN}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  let res;
  try {
    res = await fetch(base + pathname, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(20000) });
  } catch (error) {
    const why = error?.cause?.code || error?.cause?.message || error?.message || 'no answer';
    throw new Fail(3, `${method} ${pathname}: no answer from ${base} (${why})`, { network: true });
  }
  const text = await res.text();
  let json = null;
  try {
    json = text.trim() ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (res.status >= 500) throw new Fail(3, `${method} ${pathname}: ${base} answered HTTP ${res.status}`, { network: true });
  return { status: res.status, json };
}

function refused(res, what) {
  const j = res.json || {};
  const lines = [`${what} refused by the API (HTTP ${res.status}${j.errorCode ? ` ${j.errorCode}` : ''})${j.message ? `: ${j.message}` : ''}`];
  if (j.details && typeof j.details === 'object') {
    for (const [key, value] of Object.entries(j.details)) lines.push(`  field ${key}: ${typeof value === 'string' ? value : JSON.stringify(value)}`);
  }
  return new Fail(4, lines.join('\n'));
}
const ok = (res, what) => {
  if (res.status < 200 || res.status > 299) throw refused(res, what);
  return res.json;
};
const unwrap = (json) => (json && typeof json === 'object' && 'data' in json && 'success' in json ? json.data : json);
const lit = (value) => `'${String(value).replaceAll("'", "''")}'`;

async function listAll(table, { filter, orderby = 'id', limit = Infinity } = {}) {
  const out = [];
  for (let skip = 0; out.length < limit; skip += 100) {
    const query = [`$top=100`, `$skip=${skip}`, `$orderby=${encodeURIComponent(orderby)}`];
    if (filter) query.push(`$filter=${encodeURIComponent(filter)}`);
    const page = ok(await http('GET', `/api/${table}?${query.join('&')}`), `list ${table}`).value || [];
    out.push(...page);
    if (page.length < 100) break;
  }
  return out;
}
async function firstRow(table, filter, orderby = 'id') {
  const query = [`$top=1`, `$orderby=${encodeURIComponent(orderby)}`, `$filter=${encodeURIComponent(filter)}`];
  return (ok(await http('GET', `/api/${table}?${query.join('&')}`), `list ${table}`).value || [])[0] || null;
}
const highestSeq = async () => (await firstRow('fm_task_event', 'seq ge 0', 'seq desc'))?.seq ?? 0;
async function taskEvents(taskId) {
  const events = await listAll('fm_task_event', { filter: `taskId eq ${lit(taskId)}`, orderby: 'seq' });
  for (const event of events) {
    const body = bodyOf(event);
    if (!body.noteDocument) continue;
    const doc = await firstRow('fm_event_document', `fmTaskEventId eq ${event.id} and title eq 'Event note'`);
    if (!doc) throw new Fail(3, `the note document of event ${event.seq} is missing`);
    event.body = JSON.stringify({ ...body, note: doc.content });
  }
  return events;
}
const eventByKey = (key) => firstRow('fm_task_event', `idempotencyKey eq ${lit(key)}`);
const taskRow = (taskId) => firstRow('fm_task', `taskId eq ${lit(taskId)}`);
const checkRows = (taskId) => listAll('fm_task_check', { filter: `taskId eq ${lit(taskId)}`, orderby: 'scenarioId' });

// ---- the projection ---------------------------------------------------------------------------------------
function bodyOf(event) {
  try {
    const parsed = JSON.parse(event.body);
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

// The fold of every event's `set`; null while the task has no `created` event.
// The step follows the state: done is passed; review is dev once a deploy follows the newest done, else pr; running is
// pr once a pr event follows the newest started or changes, else working; triage, todo and ready are queued; blocked
// (and archived) keep the step they had. stageSince is the time of the event that set the step. lastEventAt and
// lastNote come from the newest real event: a backlog view `row` event is not one. A machine record is not a note
// either, so it leaves lastNote as it was: an import's source stamp (`{"source","sha256"}` under a `backfill:<task>:`
// key, fm-task-backfill-lib.mjs) and a reconcile divergence (`{"field","oldSource","record"}` under a `reconcile:<task>:`
// key, fm-task-reconcile-lib.mjs). The same JSON in a real comment is a note.
const MACHINE_RECORDS = { backfill: 'sha256,source', reconcile: 'field,oldSource,record' };
const isMachineRecord = (event, note) => {
  const [prefix, taskId] = String(event.idempotencyKey ?? '').split(':');
  if (!Object.hasOwn(MACHINE_RECORDS, prefix) || taskId !== event.taskId) return false;
  try {
    const value = JSON.parse(note);
    return value !== null && typeof value === 'object' && Object.keys(value).sort().join() === MACHINE_RECORDS[prefix];
  } catch {
    return false;
  }
};
function fold(events) {
  let task = null;
  let deployed = false;
  let pullRequest = false;
  for (const event of [...events].sort((a, b) => a.seq - b.seq)) {
    const set = { ...(bodyOf(event).set || {}), ...(event.rowText || {}) };
    if (event.kind === 'created' && !task) task = { taskId: event.taskId };
    if (!task) continue;
    if (event.kind === 'done') deployed = false;
    if (event.kind === 'deploy') deployed = true;
    if (event.kind === 'started' || event.kind === 'changes') pullRequest = false;
    if (event.kind === 'pr') pullRequest = true;
    task = { ...task, ...set, lastSeq: event.seq };
    const stage = STEP_OF_STATE[task.state] ?? (task.state === 'review' ? (deployed ? 'dev' : 'pr')
      : task.state === 'running' ? (pullRequest ? 'pr' : 'working') : task.stage ?? 'queued');
    if (stage !== task.stage) Object.assign(task, { stage, stageSince: event.createdAt ?? null });
    if (event.kind !== 'row') {
      const note = String(bodyOf(event).note ?? '');
      task.lastEventAt = event.createdAt ?? null;
      if (!isMachineRecord(event, note)) task.lastNote = note.slice(0, 300) || null;
    }
    if (REVIEWER_KINDS.includes(event.kind)) task.reviewer = event.actor ?? null;
  }
  if (!task) return null;
  const full = { taskId: task.taskId };
  for (const field of PROJECTED) full[field] = task[field] ?? (field === 'blockRepeats' || field === 'lastSeq' ? 0 : null);
  return full;
}

// A backlog row too long for one event body travels in the event's documents child: `set` then holds rowDocument and
// the document is `<row>\n<notes>`. Only the newest event that carries row text decides the row, so only its document
// is read.
async function withRowText(events) {
  const carrier = [...events].sort((a, b) => b.seq - a.seq).find((e) => e.kind === 'row' && (bodyOf(e).set?.rowDocument || bodyOf(e).set?.row !== undefined));
  if (!carrier || !bodyOf(carrier).set?.rowDocument) return events;
  const doc = await firstRow('fm_event_document', `fmTaskEventId eq ${carrier.id}`);
  if (!doc) throw new Fail(3, `the row document of event ${carrier.seq} is missing`);
  const cut = doc.content.indexOf('\n');
  const rowText = { row: doc.content.slice(0, cut), notes: doc.content.slice(cut + 1) };
  return events.map((e) => (e === carrier ? { ...e, rowText } : e));
}

const sameValue = (field, a, b) => (DATE_FIELDS.includes(field) ? (a ? Date.parse(a) : null) === (b ? Date.parse(b) : null) : a === b);

// Make fm_task equal the fold of the task's events; returns the fields it changed.
async function project(taskId) {
  for (let round = 0; round < 60; round++) {
    if (round) await sleep(5 + Math.random() * 20);
    const want = fold(await withRowText(await taskEvents(taskId)));
    if (!want) return null;
    const row = await taskRow(taskId);
    let changed = [];
    if (!row) {
      ok(await http('POST', '/api/fm_task', want), 'create the task row');
      changed = ['(row created)'];
    } else {
      const diff = PROJECTED.filter((field) => !sameValue(field, row[field] ?? null, want[field]));
      if (diff.length) {
        const patch = {};
        for (const field of diff) patch[field] = want[field];
        ok(await http('PATCH', `/api/fm_task/${row.id}`, patch), 'patch the task row');
        changed = diff;
      }
    }
    const top = await firstRow('fm_task_event', `taskId eq ${lit(taskId)}`, 'seq desc');
    if ((top?.seq ?? 0) <= want.lastSeq) return { task: want, changed };
  }
  throw new Fail(3, `the task row of ${taskId} kept moving while it was projected; run reproject`);
}

// ---- arguments --------------------------------------------------------------------------------------------
const COMMON = { actor: 's', role: 's', key: 's', note: 's', task: 's', json: 'b' };
const SPECS = {
  create: { pos: ['task'], flags: { title: 's', kind: 's', repo: 's', issue: 's', surface: 's', after: 'm' } },
  import: { pos: ['task'], flags: { title: 's', kind: 's', repo: 's', state: 's', assignee: 's', 'next-actor': 's', 'block-kind': 's', 'block-reason': 's', issue: 's', 'pr-url': 's', surface: 's', until: 's', since: 's' } },
  assign: { pos: ['task'], flags: { to: 's' } },
  start: { pos: ['task'], flags: {} },
  heartbeat: { pos: ['task'], flags: {} },
  done: { pos: ['task'], flags: { document: 's', 'document-title': 's', summary: 's', 'changed-files': 's', verification: 's', 'residual-risk': 's', rows: 's', 'pr-url': 's', head: 's', 'next-actor': 's', image: 'm', 'image-label': 'm' } },
  ask: { pos: ['task'], flags: { question: 's', option: 'm', recommendation: 's', why: 's', document: 's', 'next-actor': 's', image: 'm', 'image-label': 'm' } },
  block: { pos: ['kind', 'task'], flags: { reason: 's', 'next-actor': 's', until: 's', on: 's', image: 'm', 'image-label': 'm' } },
  unblock: { pos: ['task'], flags: {} },
  approve: { pos: ['task'], flags: {} },
  changes: { pos: ['task'], flags: {} },
  reopen: { pos: ['task'], flags: { reason: 's' } },
  reassign: { pos: ['task'], flags: { to: 's', reason: 's' } },
  archive: { pos: ['task'], flags: {} },
  describe: { pos: ['task'], flags: { document: 's', 'document-title': 's' } },
  thread: { pos: ['task'], flags: { since: 's' } },
  comment: { pos: ['task'], flags: { image: 'm', 'image-label': 'm', ask: 's', 'reply-to': 's' } },
  event: { pos: ['task', 'kind'], flags: { 'pr-url': 's', head: 's', touched: 's', 'next-actor': 's', 'clears-on': 's', rows: 's' } },
  checks: { pos: ['task'], flags: { 'as-deployed': 's', touched: 's' } },
  link: { pos: ['parent', 'child'], flags: {} },
  rows: { pos: ['task', 'issue'], flags: { surface: 's' } },
  check: { pos: ['task', 'target', 'status'], flags: { status: 's', evidence: 's', head: 's', 'next-actor': 's' } },
  'owner-check': { pos: ['task', 'target'], flags: { 'page-title': 's', url: 's', steps: 's', data: 's', expected: 's' } },
  show: { pos: ['task'], flags: {} },
  list: { pos: [], flags: { state: 's', actor: 's' } },
  resume: { pos: ['task'], flags: {} },
  reproject: { pos: ['task'], flags: { all: 'b' } },
  'turn-end': { pos: ['task'], flags: { turn: 's' } },
  deliver: { pos: ['task'], flags: { consumer: 's' } },
  document: { pos: ['task'], flags: {} },
  gate: { pos: ['task'], flags: { issue: 's', head: 's', 'evidence-root': 's' } },
  row: { pos: ['task'], flags: { section: 's', 'row-file': 's', 'notes-file': 's', gone: 'b', file: 's' } },
  backlog: { pos: ['action'], flags: { file: 's', out: 's', 'absorb-only': 'b' } },
};

function parseArgs(command, argv) {
  const spec = SPECS[command];
  const flags = { ...COMMON, ...spec.flags };
  const pos = {};
  const given = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) {
      positional.push(arg);
      continue;
    }
    let [name, value] = arg.slice(2).split(/=(.*)/s, 2);
    const type = flags[name];
    if (!type) throw usage(`unknown flag --${name} for ${command}`);
    if (type === 'b') {
      given[name] = true;
      continue;
    }
    if (value === undefined) {
      if (i + 1 >= argv.length) throw usage(`--${name} needs a value`);
      value = argv[++i];
    }
    if (value === '') throw usage(`--${name} is empty`);
    if (name === 'document' && given[name] !== undefined) throw usage('only one --document is allowed');
    if (type === 'm') (given[name] ||= []).push(value);
    else given[name] = value;
  }
  if (positional.length > spec.pos.length) throw usage(`unexpected argument ${positional[spec.pos.length]} for ${command}`);
  spec.pos.forEach((name, i) => {
    if (positional[i] !== undefined) pos[name] = positional[i];
  });
  return { pos, flags: given };
}

function taskIdOf(args) {
  const id = args.pos.task ?? args.flags.task ?? process.env.FM_TASK_ID;
  if (!id) throw usage('no task: give <task>, --task or FM_TASK_ID');
  if (!TASK_ID.test(id)) throw usage(`${id} is not a task id (letters, digits, '.', '_' and '-', up to 128)`);
  return id;
}
const oneOf = (list, value, what) => {
  if (!list.includes(value)) throw rule(`${what} ${JSON.stringify(value)} is not one of: ${list.join(', ')}`);
  return value;
};
const isoOf = (value, what) => {
  const time = Date.parse(value);
  if (Number.isNaN(time)) throw rule(`${what} ${JSON.stringify(value)} is not a date`);
  return new Date(time).toISOString();
};

// ---- appending an event -----------------------------------------------------------------------------------
function identity(args, defaultRole) {
  const actor = args.flags.actor || process.env.FM_TASK_ACTOR || process.env.FM_TASK_ID || os.userInfo().username;
  const role = oneOf(ROLES, args.flags.role || process.env.FM_TASK_ROLE || defaultRole, 'role');
  const key = args.flags.key || `${actor}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  if (key.length > 200) throw usage('--key is longer than 200 characters');
  if (actor.length > 64) throw usage('the actor name is longer than 64 characters');
  return { actor, role, key };
}

function checkSet(set) {
  for (const [field, value] of Object.entries(set)) {
    if (typeof value === 'string' && LIMITS[field] && value.length > LIMITS[field]) throw rule(`${field} is ${value.length} characters; the task row holds ${LIMITS[field]}`);
  }
}

const wireBody = (spec) => {
  const text = JSON.stringify({ v: 1, note: spec.note ?? '', set: spec.set || {}, ...(spec.extra || {}) });
  if (text.length > 8000) throw rule(`the event body is ${text.length} characters; the table holds 8000`);
  return text;
};

// Append one event under the global seq. build({task, events}) returns {kind, note, set, extra, children} or
// throws a rule refusal; it runs again after every 409, so it sees the events that are really before this one.
async function append(taskId, who, build) {
  const prior = await eventByKey(who.key);
  if (prior) {
    if (prior.taskId !== taskId) throw rule(`the key ${who.key} was used by task ${prior.taskId}`);
    return { event: prior, replayed: true };
  }
  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    const high = await highestSeq();
    const events = await taskEvents(taskId);
    const spec = await build({ task: fold(events), events });
    checkSet(spec.set || {});
    if (spec.note && JSON.stringify({ v: 1, note: spec.note, set: spec.set || {}, ...spec.extra }).length > 8000 - EVENT_STAGE_BUDGET) {
      spec.children = { ...spec.children, documents: [...(spec.children?.documents || []), { title: 'Event note', mediaType: 'text/plain', content: spec.note }] };
      spec.note = '';
      spec.extra = { ...spec.extra, noteDocument: true };
    }
    const body = { seq: high + 1, taskId, kind: spec.kind, actorRole: who.role, actor: who.actor, body: wireBody(spec), idempotencyKey: who.key };
    const stage = fold([...events, body])?.stage;
    body.body = wireBody({ ...spec, extra: { ...spec.extra, stage } });
    Object.assign(body, spec.children || {});
    let res;
    try {
      res = await http('POST', '/api/fm_task_event', body);
    } catch (error) {
      if (!error.network) throw error;
      // the answer may be lost after the event was stored: look it up by its key before giving up
      let found;
      try {
        found = await eventByKey(who.key);
      } catch {
        throw new Fail(3, `${error.message}; whether the event was stored is unknown; re-run with --key ${who.key}`);
      }
      if (found) return { event: found, replayed: false };
      throw new Fail(3, `${error.message}; nothing was stored`);
    }
    if (res.status === 201) return { event: unwrap(res.json), replayed: false };
    if (res.status === 409) {
      const found = await eventByKey(who.key);
      if (found) return { event: found, replayed: true };
      await sleep(Math.min(5 + attempt * 3, 40) + Math.random() * 25);
      continue;
    }
    throw refused(res, 'the event');
  }
  throw new Fail(3, `gave up after ${MAX_ATTEMPTS} tries to take the next seq`);
}

function guard(command, task) {
  if (!task) throw rule('no such task');
  if (!TRANSITIONS[command].includes(task.state)) {
    const allowed = Object.keys(TRANSITIONS).filter((c) => TRANSITIONS[c].includes(task.state));
    throw rule(`${command} is not allowed from state ${task.state}; allowed from ${task.state}: ${allowed.join(', ')}`);
  }
}

async function openParents(taskId) {
  const links = await listAll('fm_task_link', { filter: `childTaskId eq ${lit(taskId)}`, orderby: 'parentTaskId' });
  const open = [];
  for (const link of links) {
    const parent = fold(await taskEvents(link.parentTaskId));
    if (parent && !CLOSED.includes(parent.state)) open.push(link.parentTaskId);
  }
  return open;
}

async function ensureLink(parent, child) {
  const res = await http('POST', '/api/fm_task_link', { parentTaskId: parent, childTaskId: child });
  if (res.status === 409) return false;
  ok(res, 'the link');
  return true;
}

async function wouldCycle(parent, child) {
  const seen = new Set();
  const queue = [parent];
  while (queue.length) {
    const id = queue.shift();
    if (id === child) return true;
    if (seen.has(id)) continue;
    seen.add(id);
    for (const link of await listAll('fm_task_link', { filter: `childTaskId eq ${lit(id)}`, orderby: 'parentTaskId' })) queue.push(link.parentTaskId);
  }
  return false;
}

// A parent that closes releases the children that waited only on it.
async function release(parentId, who) {
  const links = await listAll('fm_task_link', { filter: `parentTaskId eq ${lit(parentId)}`, orderby: 'childTaskId' });
  const released = [];
  for (const link of links) {
    const child = fold(await taskEvents(link.childTaskId));
    if (!child || child.state !== 'todo' || (await openParents(link.childTaskId)).length) continue;
    await append(link.childTaskId, { ...who, key: `${who.key}:release:${link.childTaskId}` }, async ({ task }) => {
      if (task.state !== 'todo') throw rule('already released');
      return { kind: 'promoted', note: `parent ${parentId} is closed`, set: { state: 'ready', nextActor: task.assignee && task.assignee !== '-' ? 'worker' : 'firstmate' } };
    }).catch((error) => {
      if (!(error instanceof Fail && error.code === 5)) throw error;
    });
    await project(link.childTaskId);
    released.push(link.childTaskId);
  }
  return released;
}

// ---- images and rows --------------------------------------------------------------------------------------
function imagesOf(args) {
  const paths = args.flags.image || [];
  const labels = args.flags['image-label'] || [];
  if (paths.length !== labels.length) throw usage('give one --image-label for each --image');
  return paths.map((file, i) => {
    const mediaType = IMAGE_TYPES[path.extname(file).toLowerCase()];
    if (!mediaType) throw rule(`${file}: an image is a png, jpg, gif or webp file`);
    let data;
    try {
      data = fs.readFileSync(file);
    } catch {
      throw rule(`${file}: cannot read the image`);
    }
    if (data.length > MAX_IMAGE) throw rule(`${file}: an image is at most 2 MiB`);
    return { label: labels[i], mediaType, content: data.toString('base64'), position: i + 1 };
  });
}
const withImages = (children, images) => (images.length ? { ...children, images } : children);

const surfaceActor = (surface) => (surface === 'user-visible' ? 'tester' : 'worker');
const rowKey = (row) => `${row.scenarioId}@${row.width}`;
const openRows = (rows) => rows.filter((row) => row.status === 'pending' || row.status === 'fail');
function rowsJson(rows) {
  return JSON.stringify(rows.filter((r) => r.status !== 'retired').map((r) => ({ id: r.scenarioId, width: r.width, status: r.status, evidence: r.evidence ?? '-' })));
}
function targetOf(text) {
  const m = /^([A-Za-z0-9_.-]+)@(\S+)$/.exec(text || '');
  if (!m) throw usage('give the row as <id>@<width>, for example A1@1440, or A1@- for a scenario with no width');
  return { scenarioId: m[1], width: m[2] };
}
async function checkRow(taskId, target) {
  const row = await firstRow('fm_task_check', `taskId eq ${lit(taskId)} and scenarioId eq ${lit(target.scenarioId)} and width eq ${lit(target.width)}`);
  if (!row) throw rule(`task ${taskId} has no check row ${target.scenarioId}@${target.width}; run rows first`);
  if (row.status === 'retired') throw rule(`check row ${rowKey(row)} is retired: its scenario left the issue`);
  return row;
}
// A row set back to pending reopens the owner item that belongs to it.
async function reopenItem(taskId, target) {
  const item = await ownerItem(taskId, target);
  if (item && item.status !== 'pending') ok(await http('PATCH', `/api/fm_owner_check/${item.id}`, { status: 'pending', decidedAt: null }), 'reopen the owner item');
}
const ownerItem = (taskId, target) => firstRow('fm_owner_check', `taskId eq ${lit(taskId)} and scenarioId eq ${lit(target.scenarioId)} and width eq ${lit(target.width)}`);

// ---- output -----------------------------------------------------------------------------------------------
const out = (line) => process.stdout.write(`${line}\n`);
function reportWrite(result, task) {
  const e = result.event;
  out(`seq=${e.seq} task=${e.taskId} event=${e.kind} state=${task?.state ?? '?'} next=${task?.nextActor ?? '?'}${result.replayed ? ' (already recorded)' : ''}`);
}

// Append an event, then project; both are safe to repeat with the same --key. `wait` appends a declared wait after the
// event's own status line, so the paused line is the newest one.
async function write(taskId, who, build, after, wait) {
  const result = await append(taskId, who, build);
  let projected;
  try {
    projected = await project(taskId);
    if (after) {
      await after(result);
      projected = await project(taskId);
    }
  } catch (error) {
    if (error instanceof Fail) {
      out(`seq=${result.event.seq} task=${taskId} event=${result.event.kind} (stored; the follow-up write failed)`);
      throw new Fail(error.code === 4 ? 4 : 3, `${error.message}\nthe event is stored; re-run the same command with --key ${who.key} to finish`);
    }
    throw error;
  }
  await statusView(result.event);
  await verifyView(result.event);
  if (wait) await wait(result);
  await waitView(taskId);
  reportWrite(result, projected?.task);
  return { result, task: projected?.task };
}

// The status view: one line per terminal call, heartbeat and unblock, marked [event=N] so a replay appends no second
// line. A file the writer creates starts with a line that names the record; it holds no colon, so the status readers
// never take it for a status prefix. The other writers of the file are unchanged.
async function statusView(event) {
  if (/^(shadow|backfill):/.test(event.idempotencyKey || '')) return;
  if (!process.env.FM_HOME || !['done', 'needs-decision', 'blocked', 'heartbeat', 'unblocked', 'wait'].includes(event.kind)) return;
  const file = statusFile(event.taskId);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const marker = `[event=${event.seq}]`;
  const prior = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
  if ((prior ?? '').split('\n').some((line) => line.includes(marker))) return;
  const body = bodyOf(event);
  const head = prior === null ? `# A view of the task record for ${event.taskId}, written by bin/fm-task.sh; read the record with bin/fm-task.sh resume ${event.taskId}\n` : '';
  if (event.kind === 'wait') {
    const w = body.wait || {};
    fs.appendFileSync(file, `${head}paused [at=${Math.floor(Date.now() / 1000)}] [key=wait-${event.seq}]: waiting on ${w.actor}: ${String(body.note ?? '').replace(/[\r\n]/g, ' ')} (clears on ${w.clearsOn}) ${marker}\n`);
    return;
  }
  const paused = event.kind === 'blocked' && body.set?.blockKind === 'transient' && body.set?.holdUntil;
  const verb = event.kind === 'unblocked' ? 'resolved' : paused ? 'paused' : event.kind === 'heartbeat' ? 'working' : event.kind;
  const child = event.kind === 'done' ? await firstRow('fm_event_done', `fmTaskEventId eq ${event.id}`) : null;
  const summary = body.note || child?.summary || body.set?.blockReason || `${event.kind} recorded`;
  const note = event.kind === 'done' && body.set?.prUrl ? `PR ${body.set.prUrl} ${summary}` : summary;
  fs.appendFileSync(file, `${head}${verb} [at=${Math.floor(Date.now() / 1000)}]: ${String(note).replace(/[\r\n]/g, ' ')}${paused ? ` until ${body.set.holdUntil}` : ''} ${marker}\n`);
}

const statusFile = (taskId) => path.join(process.env.FM_STATE_OVERRIDE || path.join(process.env.FM_HOME, 'state'), `${taskId}.status`);

// A declared wait (G1): `event <task> wait`, which the Tester ask builder, `ask --next-actor owner` and `done --pr-url`
// also write. The status view writes it as a paused line keyed wait-<seq>; the record event that clears it is the asked
// rows each holding a newer result that is not pending (rows), an unblocked event (answer), a `pr` event whose note says
// merged (merge), or for any of them an approved or archived event.
function clearingEvent(wait, events) {
  const { clearsOn, rows = [] } = bodyOf(wait).wait || {};
  const later = events.filter((e) => e.seq > wait.seq);
  const closing = later.find((e) => e.kind === 'approved' || e.kind === 'archived');
  if (clearsOn === 'answer') return later.find((e) => e.kind === 'unblocked') ?? closing;
  if (clearsOn === 'merge') return later.find((e) => e.kind === 'pr' && /\bmerged\b/i.test(bodyOf(e).note ?? '')) ?? closing;
  // The pr-review source writes one ci event for the PR's current head once its checks finish, green or failed,
  // so the delivered CI result is that event whatever head the worker was waiting on.
  if (clearsOn === 'ci') {
    const newer = later.find((e) => e.kind === 'ci');
    if (newer) return newer;
    const results = events.filter((e) => e.kind === 'ci' && bodyOf(e).head);
    const prUrl = fold(events)?.prUrl;
    if (results.length && prUrl) {
      const read = spawnSync(process.env.FM_TASK_GH || 'gh', ['pr', 'view', prUrl, '--json', 'headRefOid'], { encoding: 'utf8', timeout: 20000 });
      try {
        const head = JSON.parse(read.stdout).headRefOid;
        if (!read.error && read.status === 0 && head) {
          const matching = results.findLast((e) => bodyOf(e).head === head);
          if (matching) return matching;
        }
      } catch { /* An unreadable current head cannot clear an earlier result. */ }
    }
    return closing;
  }
  const rowEvents = later.filter((e) => (e.kind === 'check' || e.kind === 'owner-check') && bodyOf(e).row && bodyOf(e).values);
  const newest = (key) => rowEvents.filter((e) => bodyOf(e).row === key).at(-1);
  const asked = rows.length ? rows : [...new Set(rowEvents.map((e) => bodyOf(e).row))];
  if (asked.length && asked.every((key) => newest(key) && bodyOf(newest(key)).values.status !== 'pending')) return asked.map(newest).sort((a, b) => a.seq - b.seq).at(-1);
  return closing;
}

// Each wait's paused line in this home's status file gets one resolved line with the same key once the record holds its
// clearing event. Only the home whose file holds the paused line writes it: the writer runs this after every write, and
// the watcher's deliver call runs it in firstmate's home for an event another home wrote (the Tester's check rows).
async function waitView(taskId, known) {
  if (!process.env.FM_HOME) return;
  const file = statusFile(taskId);
  let lines;
  try {
    lines = fs.readFileSync(file, 'utf8').split('\n');
  } catch {
    return;
  }
  const keyed = (verb) => new Set(lines.map((l) => new RegExp(`^${verb} \\[at=\\d+\\] \\[key=wait-(\\d+)\\]:`).exec(l)?.[1]).filter(Boolean));
  const resolved = keyed('resolved');
  const open = [...keyed('paused')].filter((n) => !resolved.has(n));
  if (!open.length) return;
  const events = known ?? (await taskEvents(taskId));
  for (const n of open) {
    const wait = events.find((e) => e.seq === Number(n) && e.kind === 'wait');
    const by = wait && clearingEvent(wait, events);
    if (!by) continue;
    fs.appendFileSync(file, `resolved [at=${Math.floor(Date.now() / 1000)}] [key=wait-${n}]: the wait on ${bodyOf(wait).wait?.actor} cleared: ${by.kind} event ${by.seq}\n`);
  }
}

// Append a wait for a task, keyed on the call that asks for it, and write its paused line.
async function waitOn(taskId, who, { actor, clearsOn, note, rows = [] }) {
  const result = await append(taskId, { ...who, key: `${who.key}:wait` }, async ({ task }) => {
    if (!task) throw rule('no such task');
    if (CLOSED.includes(task.state)) throw rule(`wait is refused: ${taskId} is ${task.state}`);
    return { kind: 'wait', note, extra: { wait: { actor, clearsOn, rows } } };
  });
  await statusView(result.event);
  return result;
}

// The verify view of a task begun after T5 (its data/<task>/verify.md holds `record: rows`): a deploy event with a head
// adds `deployed: <head>` and an approved event adds `approved: firstmate <epoch>`, each once. The prose stays as written.
async function verifyView(event) {
  if (!process.env.FM_HOME) return;
  const head = event.kind === 'deploy' ? bodyOf(event).head : null;
  if (!head && event.kind !== 'approved') return;
  const file = path.join(process.env.FM_DATA_OVERRIDE || path.join(process.env.FM_HOME, 'data'), event.taskId, 'verify.md');
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return;
  }
  if (!/^record: rows$/m.test(text)) return;
  const lines = text.split('\n');
  let line;
  if (head) {
    line = `deployed: ${head}`;
    if (lines.filter((l) => l.startsWith('deployed: ')).at(-1) === line) return;
    // a replay of an older deploy writes nothing once a newer deploy named its head
    const newer = await listAll('fm_task_event', { filter: `taskId eq ${lit(event.taskId)} and kind eq 'deploy' and seq gt ${event.seq}`, orderby: 'seq' });
    if (newer.some((e) => bodyOf(e).head)) return;
  } else {
    line = `approved: firstmate ${Math.floor((Date.parse(event.createdAt) || Date.now()) / 1000)}`;
    if (lines.includes(line)) return;
  }
  fs.appendFileSync(file, `${text === '' || text.endsWith('\n') ? '' : '\n'}${line}\n`);
}

// ---- commands ---------------------------------------------------------------------------------------------
const noteOf = (args) => args.flags.note ?? '';

async function cmdCreate(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'firstmate');
  const f = args.flags;
  if (!f.title) throw usage('create needs --title');
  const kind = oneOf(TASK_KINDS, f.kind, 'kind');
  const surface = f.surface === undefined ? null : oneOf(SURFACES, f.surface, 'surface');
  const parents = f.after || [];
  // Task identity check (config/enforce-task-identity): a reused done id, an fm/<id> branch in the clone, or a second live task
  // for one ticket key. The post-dispatch shadow create (bin/fm-task-shadow.sh sets FM_TASK_IDENTITY_SKIP) skips it: the spawn has
  // already made the pool worktree, so the branch is visible in the clone and the intake check has already run.
  const identity_check = process.env.FM_TASK_IDENTITY_SKIP === '1'
    ? { status: 0 }
    : spawnSync('bash', [path.join(HERE, 'fm-task-identity-check.sh'), 'add', taskId, f.title, f.repo ?? ''], { encoding: 'utf8', env: process.env });
  if (identity_check.status === 1) throw rule(String(identity_check.stderr).replace(/^error: /, '').trim());
  const { task } = await write(
    taskId,
    who,
    async ({ task: existing }) => {
      if (existing) throw rule(`task ${taskId} already exists`);
      let waiting = false;
      for (const parent of parents) {
        const p = fold(await taskEvents(parent));
        if (!p) throw rule(`parent ${parent} does not exist`);
        if (!CLOSED.includes(p.state)) waiting = true;
      }
      return {
        kind: 'created',
        note: noteOf(args),
        set: { title: f.title, repo: f.repo ?? null, kind, state: waiting ? 'todo' : 'triage', assignee: '-', nextActor: 'firstmate', blockKind: null, blockReason: null, blockRepeats: 0, issueUrl: f.issue ?? null, prUrl: null, surface, holdUntil: null },
      };
    },
    async () => {
      for (const parent of parents) await ensureLink(parent, taskId);
    },
  );
  return task;
}

// Write a task at the state an old source holds (the backfill of the task contract in shadow). A task that is already
// in the record stays as it is, so a second run adds nothing.
async function cmdImport(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'system');
  const f = args.flags;
  if (!f.title) throw usage('import needs --title');
  const kind = oneOf(TASK_KINDS, f.kind, 'kind');
  const state = oneOf(STATES, f.state, 'state');
  const nextActor = oneOf(ACTORS, f['next-actor'], 'next actor');
  const surface = f.surface === undefined ? null : oneOf(SURFACES, f.surface, 'surface');
  const blockKind = f['block-kind'] === undefined ? null : oneOf([...BLOCK_KINDS, 'needs-decision'], f['block-kind'], 'block kind');
  const until = f.until === undefined ? null : isoOf(f.until, '--until');
  const key = args.flags.key ? who.key : `import:${taskId}`;
  const { result } = await write(taskId, { ...who, key }, async ({ task: existing }) => {
    if (existing) throw rule(`task ${taskId} already present`);
    return {
      kind: 'created',
      note: `imported${f.since ? ` (open since ${f.since})` : ''}`,
      set: { title: f.title, repo: f.repo ?? null, kind, state, assignee: f.assignee ?? '-', nextActor, blockKind, blockReason: f['block-reason'] ?? null, blockRepeats: 0, issueUrl: f.issue ?? null, prUrl: f['pr-url'] ?? null, surface, holdUntil: until },
    };
  }).catch((error) => {
    if (error instanceof Fail && error.code === 5 && /already present/.test(error.message)) {
      out(`import ${taskId}: already present`);
      return {};
    }
    throw error;
  });
  return result;
}

function simple(command, kind, setFor, { needNote = false } = {}) {
  return async (args) => {
    const taskId = taskIdOf(args);
    const who = identity(args, ['start', 'heartbeat'].includes(command) ? 'worker' : 'firstmate');
    if (needNote && !args.flags.note) throw usage(`${command} needs --note`);
    return write(
      taskId,
      who,
      async ({ task }) => {
        guard(command, task);
        return { kind, note: noteOf(args), set: await setFor(task, args, taskId) };
      },
      ['approve', 'archive'].includes(command) ? () => release(taskId, who) : undefined,
    );
  };
}

const cmdAssign = simple('assign', 'assigned', async (task, args, taskId) => {
  if (!args.flags.to) throw usage('assign needs --to ASSIGNEE');
  const waiting = (await openParents(taskId)).length > 0;
  return { assignee: args.flags.to, nextActor: 'worker', state: waiting ? 'todo' : 'ready' };
});
const cmdReassign = async (args) => {
  if (!args.flags.to?.trim() || !args.flags.reason?.trim()) throw usage('reassign needs --to and --reason');
  args.flags.note = args.flags.reason;
  return simple('reassign', 'reassigned', async () => ({assignee: args.flags.to}))(args);
};
const cmdStart = simple('start', 'started', async (task, args, taskId) => {
  const parents = await openParents(taskId);
  if (parents.length) throw rule(`start is refused while the task waits on open parents: ${parents.join(', ')}`);
  return { state: 'running', nextActor: 'worker', holdUntil: null };
});
const cmdHeartbeat = simple('heartbeat', 'heartbeat', async () => ({}));
const cmdUnblock = simple('unblock', 'unblocked', async (task, args, taskId) => {
  const waiting = (await openParents(taskId)).length > 0;
  const set = { state: waiting ? 'todo' : 'ready', nextActor: 'worker', holdUntil: null, blockReason: null };
  if (task.state === 'triage') Object.assign(set, { blockKind: null, blockRepeats: 0 });
  return set;
});
const cmdChanges = simple('changes', 'changes', async () => ({ state: 'ready', nextActor: 'worker' }), { needNote: true });
const cmdReopen = async (args) => {
  if (!args.flags.reason?.trim()) throw usage('reopen needs --reason');
  args.flags.note = args.flags.reason;
  return simple('reopen', 'reopened', async () => ({state: 'ready', nextActor: 'firstmate', blockKind: null, blockReason: null, blockRepeats: 0, holdUntil: null}))(args);
};
const cmdArchive = simple('archive', 'archived', async () => ({ state: 'archived', nextActor: 'firstmate' }));
// A user-visible pass counts for the head that was built or deployed last: the head of the newest done call, or of a
// newer deploy event that names one (the Tester checks the deployed head, which a merge makes differ from the worker's).
const lastHeadEvent = (events) => [...events].reverse().find((e) => e.kind === 'done' || (e.kind === 'deploy' && bodyOf(e).head));
async function builtHead(taskId) {
  const last = lastHeadEvent(await taskEvents(taskId));
  if (last?.kind === 'deploy') return bodyOf(last).head;
  return last ? ((await firstRow('fm_event_done', `fmTaskEventId eq ${last.id}`))?.head ?? null) : null;
}
// A pass on an earlier deployed head carries to the later deployed heads (G2) when every deploy event after the newest
// deploy of the pass's head records the scenarios its PRs touched (`Scenarios touched:`, deploy --touched) and none names
// the row's id. The count starts at that deploy, not at the check event, so a late check on an older head cannot skip a
// deploy that touched the row before the check. A deploy event that records none (an older deploy, or a PR without the
// line) touches every row.
function carried(row, events) {
  if (row.surface !== 'user-visible' || row.status !== 'pass' || !row.head) return false;
  const deploys = events.filter((e) => e.kind === 'deploy' && bodyOf(e).head);
  const own = [...deploys].reverse().find((e) => bodyOf(e).head === row.head);
  if (!own) return false;
  const later = deploys.filter((e) => e.seq > own.seq);
  if (!later.length) return false;
  return later.every((e) => Array.isArray(bodyOf(e).touched) && !bodyOf(e).touched.includes(row.scenarioId));
}
const passedOnOtherHead = (row, head, events) => row.surface === 'user-visible' && row.status === 'pass' && (row.head ?? null) !== head && !carried(row, events);

// The task's open rows, each holding its newest check event, also while that event's patch is still on its way.
const newestRows = (rows, events) =>
  rows.filter((r) => r.status !== 'retired').map((r) => {
    const newest = rowEvent(events, r);
    const v = newest && bodyOf(newest).values;
    return v ? { ...r, status: v.status, nextActor: v.nextActor, evidence: v.evidence ?? null, head: v.head ?? null } : r;
  });

const cmdApprove = simple('approve', 'approved', async (task, args, taskId) => {
  const events = await taskEvents(taskId);
  const rows = newestRows(await checkRows(taskId), events);
  const open = openRows(rows);
  if (open.length) throw rule(`approve is refused while check rows are open: ${open.map((r) => `${rowKey(r)} (${r.status})`).join(', ')}`);
  const visible = rows.filter((r) => r.surface === 'user-visible');
  if (task.surface === 'user-visible' && !visible.length) throw rule(`approve is refused: ${taskId} is user-visible and has no check rows; run rows first`);
  // once a task is deployed, its user-visible rows count only on a deployed head: a draft round's deploy event names none
  if (visible.length && events.some((e) => e.kind === 'deploy') && lastHeadEvent(events)?.kind !== 'deploy') {
    throw rule(`approve is refused: ${taskId} has no deployed head after its last done; its user-visible rows count only on a deployed head`);
  }
  if (visible.length) {
    const head = await builtHead(taskId);
    const stale = visible.filter((r) => (r.head ?? null) !== head && !carried(r, events));
    if (stale.length) throw rule(`approve is refused: these user-visible rows passed on another head than the latest built or deployed head (${head ?? 'none'}): ${stale.map((r) => `${rowKey(r)} (${r.head ?? 'none'})`).join(', ')}`);
  }
  return { state: 'done', nextActor: 'firstmate', blockKind: null, blockReason: null, blockRepeats: 0, holdUntil: null };
});

// ---- the backlog view (T7) ------------------------------------------------------------------------------
// data/backlog.md is a view of the record: each row is fm_task's row (the header after the checkbox), notes (the lines
// under it, each ending in a newline) and section, verbatim. The checkbox is [x] in Done. In a section the rows follow
// the event that put them there: In flight and Done newest first, every other section oldest first, as tasks-axi places
// a moved row. Line 1 is the view's own and names the record.
const BACKLOG_LINE1 = '# Backlog - a view of the task record (fm_task row, notes and section); change it through bin/fm-tasks-axi.sh';
const BACKLOG_SECTIONS = ['In flight', 'Queued', 'Done'];
const NEWEST_FIRST = ['In flight', 'Done'];
const ROW_LINE = /^- \[[ x]\] ([A-Za-z0-9._-]+) - /;
const SECTION_LINE = /^## (.*)$/;

function readText(file, what) {
  let bytes;
  try {
    bytes = fs.readFileSync(file);
  } catch {
    throw usage(`${what} is missing or unreadable: ${file}`);
  }
  try {
    return new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    throw rule(`${what} is not UTF-8: ${file}`);
  }
}

// The values a row event sets, checked so that rendering them gives back the same row.
function rowValues(taskId, section, row, notes) {
  if (!section || section.length > LIMITS.section || /[\r\n]/.test(section) || section !== section.trim()) throw rule(`the section must be one line of 1 to ${LIMITS.section} characters`);
  if (/[\r\n]/.test(row)) throw rule('the row is one line: the header after the checkbox');
  if (ROW_LINE.exec(`- [ ] ${row}`)?.[1] !== taskId) throw rule(`the row must start with "${taskId} - "`);
  if (notes !== '' && !notes.endsWith('\n')) throw rule('the notes end with a newline');
  for (const line of notes.split('\n').slice(0, -1)) {
    if (ROW_LINE.test(line) || SECTION_LINE.test(line)) throw rule(`a notes line reads as a row or a section: ${JSON.stringify(line.slice(0, 60))}`);
  }
  return { section, row, notes };
}

// A row event, naming the backlog file whose view holds the row; text over one event body goes in a documents child
// as `<row>\n<notes>`.
// Reserve 64 characters for the stage metadata append adds, without duplicating its fold rules.
const EVENT_STAGE_BUDGET = 64;
function rowSpec(taskId, set, note, file) {
  const extra = { file };
  if (set.row === undefined || JSON.stringify({ v: 1, note, set, ...extra }).length <= 8000 - EVENT_STAGE_BUDGET) return { kind: 'row', note, set, extra };
  const doc = { title: `backlog row ${taskId}`, mediaType: 'text/markdown', content: `${set.row}\n${set.notes}` };
  return { kind: 'row', note, set: { section: set.section, rowDocument: true }, extra, children: { documents: [doc] } };
}
// Every sync and row call of one backlog file holds an exclusive lock on <file>.view-lock for its reads, writes and
// render, so an older one never writes its rows after a newer one. Node has no flock, so a perl child takes the lock
// and holds it until this process closes its stdin (or ends).
const LOCK_PERL = 'use Fcntl qw(:flock); open(my $f, ">>", shift) or die "cannot open the lock: $!\\n"; flock($f, LOCK_EX) or die "cannot lock: $!\\n"; $| = 1; print "locked\\n"; <STDIN>;';
async function withBacklogLock(file, fn) {
  const holder = spawn('perl', ['-e', LOCK_PERL, `${file}.view-lock`], { stdio: ['pipe', 'pipe', 'pipe'] });
  await new Promise((resolve, reject) => {
    const failed = (why) => reject(new Fail(3, `the backlog lock ${file}.view-lock was not taken: ${why}`));
    holder.once('error', (error) => failed(error.message));
    holder.once('exit', (code) => failed(`exit ${code}`));
    holder.stdout.once('data', () => {
      holder.removeAllListeners('exit');
      resolve();
    });
  });
  try {
    return await fn();
  } finally {
    holder.stdin.end();
  }
}

// A backlog file's identity: its real path, so a link to the file names the same view (and a write lands in the file).
// The backlog a command names: --file, else FM_DATA_OVERRIDE, else $FM_HOME/data, then backlog.md.
const backlogFile = (file) => backlogPath(file || path.join(process.env.FM_DATA_OVERRIDE || path.join(process.env.FM_HOME || '.', 'data'), 'backlog.md'));
const backlogPath = (file) => {
  try {
    return fs.realpathSync(file);
  } catch {
    return path.resolve(file);
  }
};

async function cmdRow(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'firstmate');
  const f = args.flags;
  let set;
  if (f.gone) {
    if (f.section !== undefined || f['row-file'] !== undefined || f['notes-file'] !== undefined) throw usage('--gone takes no --section, --row-file or --notes-file');
    set = { section: null };
  } else {
    if (f.section === undefined || f['row-file'] === undefined || f['notes-file'] === undefined) throw usage('row needs --section, --row-file and --notes-file, or --gone');
    set = rowValues(taskId, f.section, readText(f['row-file'], 'the row file'), readText(f['notes-file'], 'the notes file'));
  }
  const file = backlogFile(f.file);
  const store = () =>
    write(taskId, who, async ({ task }) => {
      if (!task) throw rule('no such task');
      return rowSpec(taskId, set, noteOf(args), file);
    });
  if (!fs.existsSync(file)) return store();
  // the view shows the row at once, so the next sync does not take the file's older copy back
  return withBacklogLock(file, async () => {
    const result = await store();
    try {
      out(await syncBacklog(file, who, { skip: taskId }));
    } catch (error) {
      if (error instanceof Fail) throw new Fail(error.code, `the row is stored; ${file} was not generated: ${error.message}`);
      throw error;
    }
    return result;
  });
}

// The rows of a backlog file in file order, and the first line the record cannot hold (null when there is none).
// Line 1 is the file's title when it starts with "# ". A blank line that belongs to no row (tasks-axi leaves one in an
// empty section) holds nothing and is dropped; any other line outside a row cannot be held.
function parseBacklogFile(text, file) {
  if (text !== '' && !text.endsWith('\n')) throw rule(`${file} does not end with a newline`);
  const lines = text === '' ? [] : text.slice(0, -1).split('\n');
  const titled = /^# /.test(lines[0] ?? '');
  const rows = [];
  const seen = new Set();
  let problem = null;
  let section = null;
  let current = null;
  lines.forEach((line, i) => {
    if (i === 0 && titled) return;
    const sec = SECTION_LINE.exec(line);
    if (sec) {
      section = sec[1];
      current = null;
      return;
    }
    const id = ROW_LINE.exec(line)?.[1];
    if (id && section !== null) {
      if (seen.has(id)) throw rule(`${file} holds ${id} twice`);
      seen.add(id);
      current = { id, section, row: line.slice(6), notes: '' };
      rows.push(current);
      return;
    }
    if (current) current.notes += `${line}\n`;
    else if (line.trim() !== '') problem ??= `${file} line ${i + 1} is not part of a row, so the record cannot hold it: ${JSON.stringify(line.slice(0, 80))}; the file is left as it is`;
  });
  for (const r of rows) rowValues(r.id, r.section, r.row, r.notes);
  return { rows, problem };
}

function renderBacklog(rows) {
  const names = [...BACKLOG_SECTIONS, ...[...new Set(rows.map((r) => r.section))].filter((s) => !BACKLOG_SECTIONS.includes(s)).sort()];
  let text = `${BACKLOG_LINE1}\n\n`;
  for (const name of names) {
    text += `## ${name}\n`;
    for (const r of rows) if (r.section === name) text += `- [${name === 'Done' ? 'x' : ' '}] ${r.row}\n${r.notes}`;
  }
  return text;
}

// The record's side: every task row; for each task the backlog file its newest row event names, the seq of the event
// that put it in its section of that file, and the seq of its newest row event. The record is shared by every home, so
// a view holds only the rows its own file put there.
async function backlogRecord(file) {
  const tasks = new Map((await listAll('fm_task', { orderby: 'taskId' })).map((t) => [t.taskId, t]));
  const entry = new Map();
  const last = new Map();
  const place = new Map();
  const owner = new Map();
  for (const e of await listAll('fm_task_event', { filter: "kind eq 'row'", orderby: 'seq' })) {
    const body = bodyOf(e);
    if (!('section' in (body.set || {}))) continue;
    const where = JSON.stringify([body.file ?? null, body.set.section]);
    if (place.get(e.taskId) !== where) entry.set(e.taskId, e.seq);
    place.set(e.taskId, where);
    owner.set(e.taskId, body.file ?? null);
    last.set(e.taskId, e.seq);
  }
  return { tasks, entry, last, mine: (taskId) => owner.get(taskId) === file };
}

function recordRows(record) {
  const rows = [...record.tasks.values()]
    .filter((t) => t.section && t.row && record.mine(t.taskId))
    .map((t) => ({ id: t.taskId, section: t.section, row: t.row, notes: t.notes ?? '', entry: record.entry.get(t.taskId) ?? 0 }));
  const sections = [...new Set(rows.map((r) => r.section))];
  return sections.flatMap((name) => rows.filter((r) => r.section === name).sort((a, b) => (NEWEST_FIRST.includes(name) ? b.entry - a.entry : a.entry - b.entry)));
}

// The order to write changed rows in so that section entry gives the file's order back: newest-first sections bottom up.
function writeOrder(rows) {
  const out = [];
  for (const name of [...new Set(rows.map((r) => r.section))]) {
    const own = rows.filter((r) => r.section === name);
    out.push(...(NEWEST_FIRST.includes(name) ? own.reverse() : own));
  }
  return out;
}

// A task the record does not hold yet: import it at the state the old-source mapping gives its row.
async function importRow(r, who) {
  const head = r.row.slice(r.id.length + 3);
  const hold = holdText(attr(head, 'hold'));
  const map = hermes({ section: r.section, hold, holdKind: attr(head, 'hold-kind') });
  const kind = attr(head, 'kind');
  const title = head.split(/ https?:\/\/| \((?:repo|kind|since|hold|merged|done)\b/)[0].trim().slice(0, LIMITS.title) || r.id;
  await write(r.id, { ...who, key: `import:${r.id}` }, async ({ task }) => {
    if (task) throw rule(`task ${r.id} already present`);
    return {
      kind: 'created',
      note: 'imported from the backlog view',
      set: { title, repo: attr(head, 'repo').slice(0, LIMITS.repo) || null, kind: TASK_KINDS.includes(kind) ? kind : 'other', state: map.state, assignee: r.id.slice(0, LIMITS.assignee), nextActor: map.nextActor, blockKind: map.blockKind, blockReason: map.blockKind ? (hold || 'backlog hold').slice(0, LIMITS.blockReason) : null, blockRepeats: 0, issueUrl: null, prUrl: null, surface: null, holdUntil: null },
    };
  });
}

async function rowWrite(taskId, set, who, last, file) {
  const key = `row:${taskId}:${last}:${crypto.createHash('sha256').update(JSON.stringify([file, set])).digest('hex').slice(0, 16)}`;
  await write(taskId, { ...who, key }, async ({ task }) => {
    if (!task) throw rule('no such task');
    return rowSpec(taskId, set, 'backlog view', file);
  });
}

async function cmdBacklog(args) {
  const action = args.pos.action;
  if (!['sync', 'render'].includes(action)) throw usage('backlog needs sync or render');
  const file = backlogFile(args.flags.file);
  if (action === 'render') {
    const text = renderBacklog(recordRows(await backlogRecord(file)));
    if (!args.flags.out || args.flags.out === '-') return process.stdout.write(text);
    fs.writeFileSync(args.flags.out, text);
    return out(`rendered ${args.flags.out}`);
  }
  if (args.flags.out) throw usage('--out is for render');
  const who = identity(args, 'firstmate');
  out(await withBacklogLock(file, () => syncBacklog(file, who, { absorbOnly: args.flags['absorb-only'] })));
}

// Absorb a backlog file into the record, then render it from the record. `skip` names a task whose record row was just
// written by `row`: the file's copy of that row is not absorbed, so the render carries the record's.
async function syncBacklog(file, who, { absorbOnly = false, skip = null } = {}) {
  const text = readText(file, 'the backlog file');
  const { rows, problem } = parseBacklogFile(text, file);
  let record = await backlogRecord(file);
  let written = 0;
  for (const r of rows) {
    if (record.tasks.has(r.id)) continue;
    await importRow(r, who);
    written++;
  }
  // a file the record cannot hold still has its new tasks imported, so their other record writes land
  if (problem) throw rule(problem);
  if (written) record = await backlogRecord(file);
  for (const r of writeOrder(rows)) {
    const t = record.tasks.get(r.id);
    if (r.id === skip) continue;
    if (record.mine(r.id) && t.section === r.section && t.row === r.row && (t.notes ?? '') === r.notes) continue;
    await rowWrite(r.id, { section: r.section, row: r.row, notes: r.notes }, who, record.last.get(r.id) ?? 0, file);
    written++;
  }
  const inFile = new Set(rows.map((r) => r.id));
  for (const t of record.tasks.values()) {
    if (!t.section || inFile.has(t.taskId) || !record.mine(t.taskId) || t.taskId === skip) continue;
    await rowWrite(t.taskId, { section: null }, who, record.last.get(t.taskId) ?? 0, file);
    written++;
  }
  if (absorbOnly) return `backlog: ${rows.length} rows, ${written} written, file left as it is (--absorb-only)`;
  if (written) record = await backlogRecord(file);
  const view = recordRows(record);
  const ids = (list) => list.filter((id) => id !== skip).sort().join('\n');
  if (ids(view.map((r) => r.id)) !== ids([...inFile])) {
    throw new Fail(3, `the record does not hold the rows ${file} holds (another writer moved meanwhile); the file is left as it is; run backlog sync again`);
  }
  const next = renderBacklog(view);
  let state = 'unchanged';
  if (next !== text) {
    if (fs.readFileSync(file, 'utf8') !== text) {
      state = 'changed meanwhile, left for the next sync';
    } else {
      const tmp = `${file}.${process.pid}.tmp`;
      fs.writeFileSync(tmp, next);
      fs.renameSync(tmp, file);
      state = 'generated';
    }
  }
  return `backlog: ${rows.length} rows, ${written} written, file ${state}`;
}

async function cmdDescribe(args) {
  const f = args.flags;
  if (!f.document || !['.md', '.markdown'].includes(path.extname(f.document).toLowerCase())) throw usage('describe needs --document FILE.md');
  const document = documentOf({ ...f, 'document-title': f['document-title'] ?? 'Description' });
  return write(taskIdOf(args), identity(args, 'firstmate'), async ({ task }) => {
    if (!task) throw rule('no such task');
    return { kind: 'description', children: { documents: [document] } };
  });
}

async function cmdDocument(args) {
  const events = await taskEvents(taskIdOf(args));
  const event = events.filter((e) => e.kind === 'description').at(-1);
  if (!event) throw rule('task has no Description event');
  const doc = await firstRow('fm_event_document', `fmTaskEventId eq ${event.id}`);
  if (!doc || !doc.content) throw rule('task Description document is missing');
  out(doc.content);
}

async function cmdThread(args) {
  const since = args.flags.since ?? '0';
  if (!/^\d+$/.test(since) || !Number.isSafeInteger(Number(since))) throw usage('--since must be a nonnegative integer');
  for (const event of await taskEvents(taskIdOf(args))) {
    if (event.kind === 'comment' && event.seq > Number(since)) out(`#${event.seq} ${event.createdAt} ${event.actor} ${event.actorRole}\n${bodyOf(event).note ?? ''}`);
  }
}

async function cmdComment(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'worker');
  const images = imagesOf(args);
  if (!args.flags.note && !images.length) throw usage('comment needs --note or --image');
  const ask = args.flags.ask;
  if (ask !== undefined && !['why', 'how', 'wait-what'].includes(ask)) throw usage('--ask must be why, how or wait-what');
  const reply = args.flags['reply-to'];
  if (reply !== undefined && (!/^[1-9][0-9]*$/.test(reply) || !Number.isSafeInteger(Number(reply)))) throw usage('--reply-to must be a positive integer sequence');
  return write(taskId, who, async ({ task, events }) => {
    guard('comment', task);
    if (reply !== undefined && !events.some((event) => event.seq === Number(reply) && event.kind === 'comment')) throw rule('--reply-to must name an existing comment of this task');
    const spec = { kind: 'comment', note: noteOf(args), extra: { ...(ask ? { ask } : {}), ...(reply !== undefined ? { replyTo: Number(reply) } : {}) }, children: withImages({}, images) };
    return spec;
  });
}

async function cmdEvent(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'worker');
  const kind = oneOf([...FREE_KINDS, 'wait'], args.pos.kind, 'event kind');
  const prUrl = args.flags['pr-url'];
  const head = args.flags.head;
  const headKind = kind === 'deploy' || kind === 'ci';
  if (head !== undefined && !headKind) throw usage('--head names a head a deploy or a ci event reports: give it only on one of those');
  if (args.flags.touched !== undefined && !(kind === 'deploy' && head)) throw usage('--touched names the scenarios a deploy touched: give it only on a deploy event with --head');
  const touched = touchedOf(args.flags.touched);
  if (kind === 'wait') {
    const f = args.flags;
    if (!f.note) throw usage('a wait needs --note WHY');
    const actor = oneOf(WAIT_ACTORS, f['next-actor'], 'wait next actor');
    const clearsOn = oneOf(WAIT_CLEARS, f['clears-on'], 'wait --clears-on');
    const rows = f.rows ? f.rows.split(',').map((t) => rowKey(targetOf(t.trim()))) : [];
    return write(taskId, who, async ({ task }) => {
      if (!task) throw rule('no such task');
      if (CLOSED.includes(task.state)) throw rule(`wait is refused: ${taskId} is ${task.state}`);
      return { kind: 'wait', note: f.note, extra: { wait: { actor, clearsOn, rows } } };
    });
  } else if (['next-actor', 'clears-on', 'rows'].some((n) => args.flags[n] !== undefined)) throw usage('--next-actor, --clears-on and --rows go only on a wait event');
  return write(taskId, who, async ({ task }) => {
    if (!task) throw rule('no such task');
    return { kind, note: noteOf(args), set: kind === 'pr' && prUrl ? { prUrl } : {}, ...(head ? { extra: { head, ...(touched ? { touched } : {}) } } : {}) };
  }, kind === 'deploy' && head ? () => routeReview(taskId, who) : undefined);
}

function documentOf(f) {
  if (!f.document) {
    if (f['document-title'] !== undefined) throw usage('--document-title requires --document');
    return null;
  }
  const ext = path.extname(f.document).toLowerCase();
  const types = { '.md': 'text/markdown', '.markdown': 'text/markdown', '.html': 'text/html', '.htm': 'text/html' };
  if (!types[ext]) throw usage('document extension must be .md, .markdown, .html or .htm');
  let bytes;
  try { bytes = fs.readFileSync(f.document); } catch { throw usage('document file is missing or unreadable'); }
  if (!bytes.length || bytes.length > 2 * 1024 * 1024) throw usage('document must contain 1 byte to 2 MiB');
  let content;
  try { content = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes); } catch { throw usage('document must be UTF-8'); }
  const title = f['document-title'] ?? path.basename(f.document);
  if (!title.trim() || title.length > 200 || /[\r\n]/.test(title)) throw usage('document title must be one line of 1 to 200 characters');
  return { title, mediaType: types[ext], content };
}

async function cmdDone(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'worker');
  const f = args.flags;
  const images = imagesOf(args);
  const documents = documentOf(f);
  const nextActor = f['next-actor'] === undefined ? null : oneOf(['tester', 'firstmate'], f['next-actor'], 'next actor');
  return write(taskId, who, async ({ task }) => {
    guard('done', task);
    const rows = await checkRows(taskId);
    const waitingOnTester = rows.some((r) => r.surface === 'user-visible' && r.status !== 'retired' && !(r.status === 'pass' && (r.head ?? null) === (f.head ?? null)));
    const child = { summary: f.summary, changedFiles: f['changed-files'], verification: f.verification, residualRisk: f['residual-risk'], rows: f.rows ?? rowsJson(rows), prUrl: f['pr-url'], head: f.head };
    for (const key of Object.keys(child)) if (child[key] === undefined) delete child[key];
    const set = { state: 'review', nextActor: nextActor ?? (waitingOnTester ? 'tester' : 'firstmate'), blockKind: null, blockReason: null, blockRepeats: 0, holdUntil: null };
    if (f['pr-url']) set.prUrl = f['pr-url'];
    return { kind: 'done', note: noteOf(args), set, children: withImages({ done: [child], ...(documents ? { documents: [documents] } : {}) }, images) };
  }, undefined, f['pr-url'] ? async () => {
    // a PR-ready done waits on the Tester for its open user-visible rows, else on the merge
    const task = fold(await taskEvents(taskId));
    const rows = (await checkRows(taskId)).filter((r) => r.surface === 'user-visible' && r.status !== 'retired' && !(r.status === 'pass' && (r.head ?? null) === (f.head ?? null))).map(rowKey);
    const tester = task?.nextActor === 'tester';
    await waitOn(taskId, who, tester ? { actor: 'tester', clearsOn: 'rows', note: `rows ${rows.join(' ') || 'of the task'} on ${f.head ?? 'the PR head'}`, rows } : { actor: 'merge', clearsOn: 'merge', note: `PR ${f['pr-url']}` });
  } : undefined);
}

// The wait a worker declares instead of blocking for its PR's checks. bin/fm-brief.sh gives the worker the same
// command, and bin/fm-procevent-pr-review.sh writes the ci event that clears it.
const ciWaitCommand = (taskId) => `bin/fm-task.sh event ${taskId} wait --next-actor ci --clears-on ci --note '<why you wait>'`;
// The check states that mean the run has not finished yet (`gh pr checks --json state`).
const RUNNING_CHECK_STATES = ['pending', 'queued', 'in_progress', 'waiting', 'requested', 'expected'];
const GH = process.env.FM_TASK_GH || 'gh';
// Whether the pull request still runs checks on its current head. Anything unreadable, including a missing gh or a
// URL that is not a GitHub pull request, is not proof of a running check, so it never refuses the block.
function prChecksRunning(prUrl) {
  if (!/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+/.test(prUrl)) return false;
  const run = spawnSync(GH, ['pr', 'checks', prUrl, '--json', 'name,state'], { encoding: 'utf8', timeout: 20000 });
  if (run.error || typeof run.stdout !== 'string' || !run.stdout.trim()) return false;
  let rows;
  try {
    rows = JSON.parse(run.stdout);
  } catch {
    return false;
  }
  if (!Array.isArray(rows)) return false;
  return rows.some((row) => RUNNING_CHECK_STATES.includes(String(row?.state ?? '').toLowerCase()));
}

// Count a block of `kind` against the task: the third in a row of one kind goes to triage.
function blockSet(task, kind, reason, nextActor, until) {
  const repeats = task.blockKind === kind ? task.blockRepeats + 1 : 1;
  const triage = kind !== 'dependency' && repeats >= 3;
  return { state: triage ? 'triage' : 'blocked', nextActor: triage ? 'firstmate' : nextActor, blockKind: kind, blockReason: String(reason ?? '').slice(0, LIMITS.blockReason), blockRepeats: repeats, holdUntil: until };
}

async function cmdAsk(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'worker');
  const f = args.flags;
  const options = f.option || [];
  if (options.length < 2 || options.length > 6) throw rule(`a question has 2 to 6 options, not ${options.length}`);
  const nextActor = f['next-actor'] === undefined ? 'firstmate' : oneOf(['firstmate', 'owner'], f['next-actor'], 'next actor');
  const images = imagesOf(args);
  return write(taskId, who, async ({ task }) => {
    guard('ask', task);
    const child = { question: f.question, options: JSON.stringify(options), recommendation: f.recommendation, why: f.why, document: f.document };
    for (const key of Object.keys(child)) if (child[key] === undefined) delete child[key];
    return { kind: 'needs-decision', note: noteOf(args), set: blockSet(task, 'needs-decision', f.question, nextActor, null), children: withImages({ question: [child] }, images) };
  }, undefined, nextActor === 'owner' ? () => waitOn(taskId, who, { actor: 'owner', clearsOn: 'answer', note: String(f.question).replace(/\s+/g, ' ').slice(0, 300) }) : undefined);
}

async function cmdBlock(args) {
  const taskId = taskIdOf({ ...args, pos: { task: args.pos.task } });
  const who = identity(args, 'worker');
  const f = args.flags;
  const kind = oneOf(BLOCK_KINDS, args.pos.kind, 'block kind');
  if (f['next-actor'] !== undefined) oneOf(ACTORS, f['next-actor'], 'next actor');
  const until = f.until === undefined ? null : isoOf(f.until, '--until');
  const images = imagesOf(args);
  if (kind === 'dependency' && !f.on) throw rule('a dependency block needs --on PARENT');
  if (kind === 'transient') {
    const known = fold(await taskEvents(taskId));
    const prUrl = known?.state === 'running' ? known.prUrl : null;
    if (prUrl && prChecksRunning(prUrl)) {
      throw rule(
        `a transient block is refused: ${prUrl} still runs checks on its current head, and a blocked task is cleared only by firstmate - declare the wait with \`${ciWaitCommand(taskId)}\`, and the delivered CI result clears it`,
      );
    }
  }
  return write(
    taskId,
    who,
    async ({ task }) => {
      guard('block', task);
      let set;
      if (kind === 'dependency') {
        if (f.on === taskId) throw rule('a task cannot wait on itself');
        const parent = fold(await taskEvents(f.on));
        if (!parent) throw rule(`parent ${f.on} does not exist`);
        if (CLOSED.includes(parent.state)) throw rule(`parent ${f.on} is ${parent.state}; a dependency waits on an open parent`);
        if (await wouldCycle(f.on, taskId)) throw rule(`${f.on} already waits on ${taskId}`);
        set = { ...blockSet(task, kind, f.reason, f['next-actor'] ?? 'worker', null), state: 'todo', nextActor: 'worker' };
      } else {
        set = blockSet(task, kind, f.reason, f['next-actor'] ?? 'firstmate', until);
      }
      const child = { blockKind: kind, reason: f.reason, nextActor: f['next-actor'], until };
      for (const key of Object.keys(child)) if (child[key] === undefined) delete child[key];
      return { kind: 'blocked', note: noteOf(args), set, children: withImages({ block: [child] }, images) };
    },
    async () => {
      if (kind === 'dependency') await ensureLink(f.on, taskId);
    },
  );
}

async function cmdLink(args) {
  const { parent, child } = args.pos;
  if (!parent || !child) throw usage('link needs <parent> <child>');
  for (const id of [parent, child]) if (!TASK_ID.test(id)) throw usage(`${id} is not a task id`);
  const who = identity(args, 'firstmate');
  if (parent === child) throw rule('a task cannot wait on itself');
  const p = fold(await taskEvents(parent));
  const c = fold(await taskEvents(child));
  if (!p) throw rule(`parent ${parent} does not exist`);
  if (!c) throw rule(`child ${child} does not exist`);
  if (!['triage', 'todo', 'ready'].includes(c.state)) throw rule(`a task in state ${c.state} cannot take a new parent`);
  const existing = await firstRow('fm_task_link', `parentTaskId eq ${lit(parent)} and childTaskId eq ${lit(child)}`);
  if (!existing && (await wouldCycle(parent, child))) throw rule(`${parent} already waits on ${child}`);
  const needsMove = !CLOSED.includes(p.state) && c.state === 'ready';
  if (existing && !needsMove) {
    out(`link ${parent} -> ${child} (already linked)`);
    return;
  }
  await ensureLink(parent, child);
  if (!needsMove) {
    out(`link ${parent} -> ${child}`);
    return;
  }
  await write(child, who, async ({ task }) => {
    guard('assign', task);
    return { kind: 'linked', note: `waits on ${parent}`, set: { state: 'todo' } };
  });
}

// The check rows an issue asks for now, keyed <id>@<width>, each with the digest of its scenario as the issue reads it.
async function wantedRows(issue) {
  const parser = process.env.FM_TASK_ACCEPTANCE || path.join(HERE, 'fm-acceptance.mjs');
  const run = spawnSync('node', [parser, 'parse', issue, '--strict'], { encoding: 'utf8', timeout: 60000, maxBuffer: 16 * 1024 * 1024 });
  if (run.error || !run.stdout) throw new Fail(3, `could not read ${issue}: ${run.error?.message || run.stderr.trim() || `parser exited ${run.status}`}`);
  const parsed = JSON.parse(run.stdout);
  if (parsed.problems.length) throw rule(`${issue} is refused by the acceptance parser: ${parsed.problems.join('; ')}`);
  const { rows: acceptanceRows } = await import(pathToFileURL(parser).href);
  const byId = new Map(parsed.scenarios.map((s) => [s.id, s]));
  const fit = (value, max) => (value.length > max ? `${value.slice(0, max - 1)}…` : value);
  const wanted = new Map();
  for (const line of acceptanceRows(parsed, { surface: 'all' })) {
    const m = /^- (\S+)@(\S+) \| (.*) \| pending \| evidence: -$/s.exec(line);
    if (!m) throw rule(`the acceptance parser printed a row this writer cannot read: ${line}`);
    const s = byId.get(m[1]);
    const { done, ...rest } = s;
    wanted.set(`${m[1]}@${m[2]}`, {
      scenarioId: m[1],
      width: m[2],
      line: fit(m[3], 4000),
      surface: s.surface,
      page: fit(s.page, 200),
      controls: fit(s.controls.length ? s.controls.join('; ') : '-', 2000),
      data: fit(s.data, 2000),
      env: fit(s.env, 2000),
      mock: fit(s.mock, 2000),
      proof: fit(s.proof, 4000),
      acceptanceDigest: crypto.createHash('sha256').update(JSON.stringify(rest)).digest('hex'),
    });
  }
  return wanted;
}

async function cmdRows(args) {
  const taskId = taskIdOf(args);
  const issue = args.pos.issue || taskId;
  const who = identity(args, 'firstmate');
  const task = fold(await taskEvents(taskId));
  if (!task) throw rule(`no such task ${taskId}`);
  if (CLOSED.includes(task.state)) throw rule(`rows is refused: ${taskId} is ${task.state}, and new rows or resets would sit under a closed task`);
  const surface = oneOf(['all', 'user-visible'], args.flags.surface ?? 'all', 'surface');
  const wanted = new Map([...(await wantedRows(issue))].filter(([, want]) => surface === 'all' || want.surface === surface));
  const have = new Map((await checkRows(taskId)).map((row) => [rowKey(row), row]));
  const counts = { added: 0, reset: 0, retired: 0, updated: 0, unchanged: 0 };
  const fresh = { status: 'pending', evidence: null, head: null, checkedAt: null };
  const actorFor = (surface) => (surface === 'user-visible' ? 'tester' : 'worker');
  // a row set back to pending gets its own check event, so an older call of that row cannot restore its old result
  const resetEvent = (key, nextActor) =>
    append(taskId, { ...who, key: `${who.key}:r:${crypto.createHash('sha1').update(key).digest('hex').slice(0, 10)}` }, async () => ({
      kind: 'check',
      note: `${key} reset to pending`,
      extra: { row: key, values: { status: 'pending', nextActor, evidence: null, head: null, checkedAt: null } },
    }));
  for (const [key, want] of wanted) {
    const row = have.get(key);
    if (!row) {
      ok(await http('POST', '/api/fm_task_check', { taskId, ...want, ...fresh, nextActor: actorFor(want.surface) }), `create the check row ${key}`);
      counts.added++;
      continue;
    }
    const changed = row.line !== want.line || row.acceptanceDigest !== want.acceptanceDigest;
    const text = { line: want.line, surface: want.surface, page: want.page, controls: want.controls, data: want.data, env: want.env, mock: want.mock, proof: want.proof, acceptanceDigest: want.acceptanceDigest };
    if (row.status === 'retired') {
      await resetEvent(key, actorFor(want.surface));
      ok(await http('PATCH', `/api/fm_task_check/${row.id}`, { ...text, ...fresh, nextActor: actorFor(want.surface) }), `reopen the check row ${key}`);
      await reopenItem(taskId, row);
      counts.added++;
    } else if (changed && row.status === 'pass') {
      await resetEvent(key, actorFor(want.surface));
      ok(await http('PATCH', `/api/fm_task_check/${row.id}`, { ...text, ...fresh, nextActor: actorFor(want.surface) }), `reset the check row ${key}`);
      await reopenItem(taskId, row);
      counts.reset++;
    } else if (changed) {
      ok(await http('PATCH', `/api/fm_task_check/${row.id}`, text), `update the check row ${key}`);
      counts.updated++;
    } else {
      counts.unchanged++;
    }
  }
  for (const [key, row] of have) {
    if (wanted.has(key) || row.status === 'retired' || (surface !== 'all' && row.surface !== surface)) continue;
    ok(await http('PATCH', `/api/fm_task_check/${row.id}`, { status: 'retired' }), `retire the check row ${key}`);
    counts.retired++;
  }
  const summary = `rows added=${counts.added} reset=${counts.reset} retired=${counts.retired} updated=${counts.updated} unchanged=${counts.unchanged} total=${wanted.size}`;
  const parser = process.env.FM_TASK_ACCEPTANCE || path.join(HERE, 'fm-acceptance.mjs');
  const digestRun = spawnSync('node', [parser, 'digest', issue, '--strict'], { encoding: 'utf8', timeout: 60000 });
  const taskNative = !args.pos.issue || issue.startsWith('task:') || /^https?:\/\/[^\s]+[?&]task=/.test(issue);
  if (taskNative && (digestRun.status !== 0 || !/^[a-f0-9]{64}\s*$/.test(digestRun.stdout))) throw rule('acceptance digest could not be read');
  const sets = { ...(taskNative && task.acceptanceDigest !== digestRun.stdout.trim() ? { acceptanceDigest: digestRun.stdout.trim() } : {}), ...(taskNative ? (task.issueUrl !== issue ? { issueUrl: issue } : {}) : (args.pos.issue && !task.issueUrl ? { issueUrl: issue } : {})) };
  if (counts.added + counts.reset + counts.retired + counts.updated === 0 && !Object.keys(sets).length) {
    out(summary);
    return;
  }
  await write(taskId, who, async () => ({ kind: 'check', note: summary, set: sets }), () => routeReview(taskId, who));
  out(summary);
}

// check rows of a closed task stay as they were closed.
async function requireOpenTask(taskId, command) {
  const task = fold(await taskEvents(taskId));
  if (!task) throw rule(`no such task ${taskId}`);
  if (CLOSED.includes(task.state)) throw rule(`${command} is refused: ${taskId} is ${task.state}`);
  return task;
}

// The newest event that sets the values of a check row: a check call, a reset by rows or an owner-check.
const rowEvent = (events, row) => [...events].reverse().find((e) => (e.kind === 'check' || e.kind === 'owner-check') && bodyOf(e).row === rowKey(row) && bodyOf(e).values);

async function cmdCheck(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'tester');
  const f = args.flags;
  const target = targetOf(args.pos.target);
  if (args.pos.status !== undefined && f.status !== undefined && args.pos.status !== f.status) throw usage(`give the result once: ${args.pos.status} or --status ${f.status}`);
  const status = oneOf(CHECK_STATUSES, args.pos.status ?? f.status, 'status');
  await requireOpenTask(taskId, 'check');
  const row = await checkRow(taskId, target);
  const nextActor = oneOf(ACTORS, f['next-actor'] ?? (status === 'pass' ? 'firstmate' : status === 'fail' ? 'worker' : row.nextActor === 'firstmate' ? surfaceActor(row.surface) : row.nextActor), 'next actor');
  if (nextActor === 'owner' && !(await ownerItem(taskId, target))) throw rule(`${rowKey(row)} cannot read next actor owner without its owner item; run owner-check first`);
  const values = { status, nextActor, evidence: f.evidence ?? null, head: f.head ?? null, checkedAt: status === 'pending' ? null : new Date().toISOString() };
  // a re-sent key means the call it already recorded: other values are another call and need another key
  const prior = await eventByKey(who.key);
  if (prior) {
    const stored = bodyOf(prior).values || {};
    if (prior.taskId !== taskId || prior.kind !== 'check' || bodyOf(prior).row !== rowKey(row)) throw rule(`the key ${who.key} already recorded another call`);
    const differs = ['status', 'evidence', 'head'].filter((k) => (stored[k] ?? null) !== values[k]);
    if (f['next-actor'] !== undefined && stored.nextActor !== f['next-actor']) differs.push('nextActor');
    if (differs.length) throw rule(`the key ${who.key} already recorded this check with other ${differs.join(', ')}; use a new --key for a new result`);
  }
  await write(taskId, who, async ({ task }) => {
    if (!task) throw rule('no such task');
    if (CLOSED.includes(task.state)) throw rule(`check is refused: ${taskId} is ${task.state}`);
    return { kind: 'check', note: `${rowKey(row)} ${status}${f.evidence ? `: ${f.evidence}` : ''}`, extra: { row: rowKey(row), values } };
  }, async () => {
    await applyNewestCheck(taskId, row);
    if (who.role === 'owner' && status !== 'pending') await ownerVerdict(taskId, target, status, f.evidence);
    await routeReview(taskId, who);
  });
}

// The owner's own pass or fail of a row that has an owner item is that item's verdict too: its status, decidedAt and
// note follow the check (the board's writer operation, bin/fm-task-owner.sh). A re-sent verdict changes nothing.
async function ownerVerdict(taskId, target, status, note) {
  const item = await ownerItem(taskId, target);
  if (!item || (item.status === status && (item.note ?? null) === (note ?? null))) return;
  ok(await http('PATCH', `/api/fm_owner_check/${item.id}`, { status, decidedAt: new Date().toISOString(), note: note ?? null }), 'the owner verdict');
}

// The row holds the values stored in the newest check event for it, whichever call patches last: after each
// patch the newest event is read again, and a newer one is patched in turn.
async function applyNewestCheck(taskId, row) {
  let applied = 0;
  for (let round = 0; round < 30; round++) {
    const newest = rowEvent(await taskEvents(taskId), row);
    const v = newest && bodyOf(newest).values;
    if (!v || newest.seq === applied) return;
    const patch = { status: v.status, nextActor: v.nextActor, checkedAt: v.checkedAt, evidence: v.evidence ?? null, head: v.head ?? null };
    ok(await http('PATCH', `/api/fm_task_check/${row.id}`, patch), `patch the check row ${rowKey(row)}`);
    if (v.status === 'pending') await reopenItem(taskId, { scenarioId: row.scenarioId, width: row.width });
    applied = newest.seq;
  }
  throw new Fail(3, `the check row ${rowKey(row)} kept changing; run the check again`);
}

// A task in review waits on the actor of its open check rows (worker first, then tester, then owner), and on
// firstmate when none is open. Called after every change of a row.
// A user-visible pass on another head than the built head is open for the tester.
const reviewActor = (rows, head, events) => {
  const waiting = rows.filter((r) => openRows([r]).length || passedOnOtherHead(r, head, events)).map((r) => (passedOnOtherHead(r, head, events) ? 'tester' : r.nextActor));
  return ['worker', 'tester', 'owner'].find((a) => waiting.includes(a)) ?? 'firstmate';
};
async function routeReview(taskId, who) {
  const needed = async () => {
    const task = fold(await taskEvents(taskId));
    const actor = reviewActor(await checkRows(taskId), await builtHead(taskId), await taskEvents(taskId));
    return task?.state === 'review' && task.nextActor !== actor ? actor : null;
  };
  if (!(await needed())) return;
  await append(taskId, { ...who, key: `${who.key}:route:${crypto.randomBytes(3).toString('hex')}` }, async ({ task }) => {
    const actor = reviewActor(await checkRows(taskId), await builtHead(taskId), await taskEvents(taskId));
    if (task?.state !== 'review' || task.nextActor === actor) throw rule('already routed');
    return { kind: 'routed', note: `check rows are open for ${actor}`, set: { nextActor: actor } };
  }).catch((error) => {
    if (!(error instanceof Fail && error.code === 5)) throw error;
  });
}

// --touched: `none`, or the scenario ids the deployed PRs name, comma-separated; `all` (or no flag) records none.
function touchedOf(text) {
  if (text === undefined || text === 'all') return null;
  if (text === 'none') return [];
  const ids = text.split(',').map((t) => t.trim()).filter(Boolean);
  for (const id of ids) if (!/^[A-Za-z0-9_.-]+$/.test(id)) throw usage(`--touched ${JSON.stringify(id)} is not a scenario id`);
  return ids;
}

// The read the Tester ask builder takes (bin/fm-procevent-deploy-verify.sh): the task's open rows with their newest
// values, the head they count on, and `due` for each user-visible row the Tester checks on that head (pending for the
// Tester, or a pass on another head that does not carry). --as-deployed HEAD [--touched IDS] reads the rows as if a
// deploy event of HEAD were recorded next, and writes nothing (the deploy round's --dry-run).
async function cmdChecks(args) {
  const taskId = taskIdOf(args);
  const events = await taskEvents(taskId);
  const task = fold(events);
  if (!task) throw rule(`no such task ${taskId}`);
  const as = args.flags['as-deployed'];
  if (args.flags.touched !== undefined && !as) throw usage('--touched goes with --as-deployed');
  const top = events.at(-1)?.seq ?? 0;
  const view = as ? [...events, { seq: top + 1, kind: 'deploy', taskId, body: JSON.stringify({ v: 1, note: '', set: {}, head: as, ...(touchedOf(args.flags.touched) ? { touched: touchedOf(args.flags.touched) } : {}) }) }] : events;
  const head = as ?? (await builtHead(taskId));
  const rows = newestRows(await checkRows(taskId), view).map((r) => {
    const carry = r.status === 'pass' && (r.head ?? null) !== head && carried(r, view);
    const due = r.surface === 'user-visible' && ((r.status === 'pending' && r.nextActor === 'tester') || passedOnOtherHead(r, head, view));
    return { key: rowKey(r), scenarioId: r.scenarioId, width: r.width, surface: r.surface, status: r.status, nextActor: r.nextActor, head: r.head ?? null, carried: carry, due };
  });
  out(JSON.stringify({ task: taskId, state: task.state, nextActor: task.nextActor, issueUrl: task.issueUrl ?? null, head, rows }));
}

// The verify gate's read of the record (bin/fm-verify-gate-lib.sh calls it for a task begun after T5). It writes nothing,
// prints one problem per line and exits 5 when there is any. The task passes when every user-visible row the issue asks
// for now is `pass` with evidence on the deployed --head and with its scenario's current digest, and an approved event is
// newer than the last row event. A relative evidence path resolves against --evidence-root (the Tester home).
async function cmdGate(args) {
  const taskId = taskIdOf(args);
  const f = args.flags;
  if (!f.head) throw usage('gate needs --head SHA');
  f.issue ||= taskId;
  const events = await taskEvents(taskId);
  if (!fold(events)) {
    out(`the task record has no task ${taskId}`);
    throw new Fail(5, `gate: ${taskId} is not complete`);
  }
  const problems = [];
  const wanted = [...(await wantedRows(f.issue))].filter(([, want]) => want.surface === 'user-visible');
  if (!wanted.length) problems.push(`issue ${f.issue} has no user-visible scenario row`);
  const have = new Map(newestRows(await checkRows(taskId), events).map((r) => [rowKey(r), r]));
  // a carried pass counts only for the latest recorded deployed head
  const lastDeploy = [...events].reverse().find((e) => e.kind === 'deploy' && bodyOf(e).head);
  const deployedHead = lastDeploy ? bodyOf(lastDeploy).head : null;
  for (const [key, want] of wanted) {
    const row = have.get(key);
    if (!row) {
      problems.push(`${key} has no check row in the record; run rows`);
      continue;
    }
    if (row.line !== want.line || row.acceptanceDigest !== want.acceptanceDigest) problems.push(`${key} was checked against another version of the scenario; run rows, then check it again`);
    if (row.status !== 'pass') {
      problems.push(`${key} is '${row.status}', not pass`);
      continue;
    }
    const ev = row.evidence ?? '';
    if (!ev || ev === '-') problems.push(`${key} is pass without evidence`);
    else if (!/^https?:\/\/./.test(ev) && !fs.existsSync(path.resolve(f['evidence-root'] || '.', ev))) problems.push(`${key} evidence path does not exist: ${ev}`);
    if ((row.head ?? null) !== f.head && f.head === deployedHead && carried(row, events)) out(`${key} carried: pass on head ${row.head}, and no later deployed PR names ${row.scenarioId}`);
    else if ((row.head ?? null) !== f.head) problems.push(`${key} passed on head ${row.head ?? 'none'}, not the deployed head ${f.head}`);
  }
  const wantedKeys = new Set(wanted.map(([key]) => key));
  for (const [key, row] of have) if (row.surface === 'user-visible' && !wantedKeys.has(key)) problems.push(`${key} is not a row of ${f.issue}; run rows`);
  const lastRow = [...events].reverse().find((e) => (e.kind === 'check' || e.kind === 'owner-check') && bodyOf(e).row);
  const approved = [...events].reverse().find((e) => e.kind === 'approved');
  if (!approved) problems.push(`no approved event for ${taskId}: firstmate approves with bin/fm-task.sh approve after the rows pass`);
  else if (lastRow && approved.seq < lastRow.seq) problems.push(`the approved event (seq ${approved.seq}) is not newer than the last row event (seq ${lastRow.seq})`);
  for (const problem of problems) out(problem);
  if (problems.length) throw new Fail(5, `gate: ${taskId} is not complete`);
}

async function cmdOwnerCheck(args) {
  const taskId = taskIdOf(args);
  const who = identity(args, 'firstmate');
  const f = args.flags;
  const target = targetOf(args.pos.target);
  await requireOpenTask(taskId, 'owner-check');
  const row = await checkRow(taskId, target);
  const item = { taskId, ...target, pageTitle: f['page-title'], url: f.url, steps: f.steps, data: f.data, expected: f.expected, status: 'pending' };
  for (const key of Object.keys(item)) if (item[key] === undefined) delete item[key];
  const note = `${rowKey(row)}: ${f['page-title']} at ${f.url}`;
  // a re-sent key means the call it already recorded: its item is written, and a newer verdict stays
  const prior = await eventByKey(who.key);
  if (prior && (prior.taskId !== taskId || prior.kind !== 'owner-check' || bodyOf(prior).row !== rowKey(row) || bodyOf(prior).note !== note)) {
    throw rule(`the key ${who.key} already recorded another call; use a new --key for a new owner-check`);
  }
  // the item first: a refusal here leaves the check row as it was
  const existing = prior ? null : await ownerItem(taskId, target);
  if (existing) {
    // An update must supply the complete checklist rather than retain omitted fields.
    const missing = ['page-title', 'url', 'steps', 'data', 'expected'].filter((name) => !f[name]?.trim());
    if (missing.length) throw rule(`owner-check on a row that has an owner item needs ${missing.map((name) => `--${name}`).join(' and ')}`);
    const diff = Object.fromEntries(Object.entries(item).filter(([k, v]) => !['taskId', 'scenarioId', 'width', 'status'].includes(k) && existing[k] !== v));
    // the same item on a row that already waits on the owner: nothing to change
    if (!Object.keys(diff).length && existing.status === 'pending' && row.nextActor === 'owner' && row.status === 'pending') {
      out(`owner item for ${rowKey(row)} unchanged`);
      return;
    }
    if (Object.keys(diff).length || existing.status !== 'pending') ok(await http('PATCH', `/api/fm_owner_check/${existing.id}`, { ...diff, status: 'pending', decidedAt: null }), 'update the owner item');
  } else if (!prior) {
    ok(await http('POST', '/api/fm_owner_check', item), 'the owner item');
  }
  await write(taskId, who, async ({ task }) => {
    if (!task) throw rule('no such task');
    if (CLOSED.includes(task.state)) throw rule(`owner-check is refused: ${taskId} is ${task.state}`);
    return { kind: 'owner-check', note, extra: { row: rowKey(row), values: { status: 'pending', nextActor: 'owner', evidence: row.evidence ?? null, head: row.head ?? null, checkedAt: null } } };
  }, async () => {
    await applyNewestCheck(taskId, row);
    await routeReview(taskId, who);
  });
}

async function cmdShow(args) {
  const taskId = taskIdOf(args);
  const row = await taskRow(taskId);
  if (!row) throw rule(`no task row for ${taskId}${fold(await taskEvents(taskId)) ? '; its events exist, run reproject' : ''}`);
  if (args.flags.json) return out(JSON.stringify(row));
  for (const field of ['taskId', ...PROJECTED]) out(`${field}=${ROW_TEXT.includes(field) && row[field] != null ? `(${row[field].length} characters; --json)` : row[field] ?? '-'}`);
}

async function cmdList(args) {
  const clauses = [];
  if (args.flags.state) clauses.push(`state eq ${lit(oneOf(STATES, args.flags.state, 'state'))}`);
  if (args.flags.actor) clauses.push(`nextActor eq ${lit(oneOf(ACTORS, args.flags.actor, 'actor'))}`);
  const rows = await listAll('fm_task', { filter: clauses.join(' and ') || undefined, orderby: 'taskId' });
  if (args.flags.json) return out(JSON.stringify(rows));
  for (const r of rows) out(`${r.taskId} state=${r.state} next=${r.nextActor} assignee=${r.assignee} ${r.title}`);
}

async function cmdReproject(args) {
  if (args.flags.all) {
    const tasks = await listAll('fm_task', { orderby: 'taskId' });
    let repaired = 0;
    for (const { taskId } of tasks) {
      const result = await project(taskId);
      if (!result?.changed.length) continue;
      repaired++;
      out(`reprojected ${taskId}: repaired ${result.changed.join(', ')} (last seq ${result.task.lastSeq})`);
    }
    out(`reproject --all: ${tasks.length} tasks, ${repaired} repaired`);
    return;
  }
  const taskId = taskIdOf(args);
  const result = await project(taskId);
  if (!result) throw rule(`no events for ${taskId}`);
  out(result.changed.length ? `reprojected ${taskId}: repaired ${result.changed.join(', ')} (last seq ${result.task.lastSeq})` : `${taskId}: the row already matches its events (last seq ${result.task.lastSeq})`);
}

const cut = (text, max) => {
  const flat = String(text ?? '-').replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max - 1)}… (+${flat.length - max + 1})` : flat;
};
const TERMINAL = { done: 'fm_event_done', 'needs-decision': 'fm_event_question', blocked: 'fm_event_block' };
const TEMPLATE_FIELDS = {
  done: ['summary', 'changedFiles', 'verification', 'residualRisk', 'rows', 'prUrl', 'head'],
  'needs-decision': ['question', 'options', 'recommendation', 'why', 'document'],
  blocked: ['blockKind', 'reason', 'nextActor', 'until'],
};

function openCalls(events) {
  let open = [];
  for (const e of events) {
    if (e.kind === 'blocked' || e.kind === 'needs-decision') open.push(e);
    else if (e.kind === 'unblocked' || e.kind === 'started') open = [];
  }
  return open;
}

async function cmdResume(args) {
  const taskId = taskIdOf(args);
  const events = await taskEvents(taskId);
  const task = fold(events);
  if (!task) throw rule(`no such task ${taskId}`);
  const rows = (await checkRows(taskId)).filter((r) => r.status !== 'retired');
  const lines = [];
  lines.push(`TASK ${taskId} (${task.kind}${task.repo ? `, ${task.repo}` : ''}): ${cut(task.title, 100)}`);
  lines.push(`state=${task.state} assignee=${task.assignee} next=${task.nextActor} last seq=${task.lastSeq}${task.holdUntil ? ` hold until ${task.holdUntil}` : ''}`);
  lines.push(`issue: ${task.issueUrl ?? '-'}  pr: ${task.prUrl ?? '-'}  surface: ${task.surface ?? '-'}${task.blockKind ? `  block: ${task.blockKind} x${task.blockRepeats}` : ''}`);
  const last = [...events].reverse().find((e) => TERMINAL[e.kind]);
  lines.push('LAST TERMINAL CALL');
  if (!last) lines.push('  none yet');
  else {
    const child = await firstRow(TERMINAL[last.kind], `fmTaskEventId eq ${last.id}`);
    lines.push(`  #${last.seq} ${last.kind} by ${last.actorRole}/${last.actor} at ${String(last.createdAt).slice(0, 19)}Z`);
    for (const field of TEMPLATE_FIELDS[last.kind]) {
      let value = child?.[field];
      if (field === 'rows' && value) {
        try {
          const list = JSON.parse(value);
          const tally = {};
          for (const r of list) tally[r.status] = (tally[r.status] || 0) + 1;
          value = `${list.length} rows (${Object.entries(tally).map(([k, v]) => `${v} ${k}`).join(', ') || 'none'})`;
        } catch {
          // shown as stored
        }
      }
      lines.push(`  ${field}: ${cut(value, 150)}`);
    }
  }
  const open = openRows(rows);
  lines.push(`OPEN CHECK ROWS (${open.length})`);
  for (const r of open.slice(0, 12)) lines.push(`  ${rowKey(r)} [${r.nextActor}] ${r.status}: ${cut(r.line, 90)}`);
  if (open.length > 12) lines.push(`  ... ${open.length - 12} more`);
  const calls = openCalls(events);
  const questions = calls.filter((e) => e.kind === 'needs-decision');
  const blocks = calls.filter((e) => e.kind === 'blocked');
  lines.push(`OPEN QUESTIONS (${questions.length})`);
  for (const e of questions.slice(-3)) lines.push(`  #${e.seq} ${cut(bodyOf(e).set?.blockReason, 130)} -> ${bodyOf(e).set?.nextActor ?? '-'}`);
  lines.push(`OPEN BLOCKS (${blocks.length})`);
  for (const e of blocks.slice(-3)) lines.push(`  #${e.seq} ${bodyOf(e).set?.blockKind ?? '-'}: ${cut(bodyOf(e).set?.blockReason, 110)} -> ${bodyOf(e).set?.nextActor ?? '-'}`);
  lines.push('LAST 10 EVENTS');
  for (const e of events.slice(-10)) lines.push(`  #${e.seq} ${e.kind} ${e.actorRole}/${e.actor}: ${cut(bodyOf(e).note, 90)}`);
  for (const line of lines) out(line);
}

// A turn token is the durable hook generation, not a status-file byte offset.
async function cmdTurnEnd(args) {
  const taskId = taskIdOf(args);
  const turn = args.flags.turn;
  if (!turn) throw usage('turn-end needs --turn');
  const events = await taskEvents(taskId);
  const task = fold(events);
  if (!task) throw rule(`no such task ${taskId}`);
  const state = process.env.FM_STATE_OVERRIDE || (process.env.FM_HOME && path.join(process.env.FM_HOME, 'state'));
  if (!state) throw usage('turn-end requires FM_HOME');
  fs.mkdirSync(state, { recursive: true });
  const cursor = path.join(state, `.task-turn-${taskId}.json`);
  let prior = { seq: 0, count: 0 };
  if (fs.existsSync(cursor)) prior = JSON.parse(fs.readFileSync(cursor, 'utf8'));
  if (task.state !== 'running' && !(task.state === 'ready' && task.nextActor === 'worker')) {
    fs.writeFileSync(cursor, JSON.stringify({...prior, turn, verdict: 'idle'}));
    return out('idle');
  }
  if (prior.turn === turn) return out(prior.verdict);
  const started = [...events].reverse().find((e) => e.kind === 'started');
  const ready = task.state === 'ready' ? [...events].reverse().find(e => ['assigned', 'changes', 'unblocked', 'reopened', 'promoted'].includes(e.kind) && bodyOf(e).set?.state === 'ready') : null;
  const anchor = Math.max(prior.seq, started?.seq ?? 0, ready?.seq ?? 0);
  const terminal = events.some((e) => e.seq > anchor && TERMINAL[e.kind]);
  let count = terminal ? 0 : prior.count + 1;
  let verdict = terminal ? 'wake-verb' : count > 3 ? 'ping-escalated' : `ping-${count}`;
  if (!terminal) {
    await cmdEvent({ pos: { task: taskId, kind: 'protocol_violation' }, flags: { key: `turn:${taskId}:${turn}`, note: 'Turn ended without a terminal call', actor: 'turn-end-checker', role: 'system' } });
    if (count === 3) {
      await write(taskId, { key: `turn-block:${taskId}:${turn}`, actor: 'turn-end-checker', role: 'system' }, async () => ({ kind: 'blocked', note: 'Three turns without a terminal call', set: { state: 'blocked', nextActor: 'firstmate', blockKind: 'capability', blockReason: 'Three turns without a terminal call', blockRepeats: count }, children: { block: [{ blockKind: 'capability', reason: 'Three turns without a terminal call', nextActor: 'firstmate' }] } }));
      verdict = 'ping-exhausted';
    }
  }
  fs.writeFileSync(cursor, JSON.stringify({ turn, seq: (await taskEvents(taskId)).at(-1).seq, count, verdict }));
  out(verdict);
}

async function cmdDeliver(args) {
  const consumer = args.flags.consumer;
  if (!consumer || consumer.length > 64) throw usage('deliver needs --consumer (up to 64 characters)');
  if (!process.env.FM_HOME) throw usage('deliver requires FM_HOME');
  const taskStream = await taskEvents(taskIdOf(args));
  await waitView(taskIdOf(args), taskStream);
  const firstSeq = taskStream[0]?.seq ?? 0;
  const lastSeq = taskStream.at(-1)?.seq ?? 0;
  const delivered = await listAll('fm_task_delivery', { filter: `consumer eq ${lit(consumer)} and seq ge ${firstSeq} and seq le ${lastSeq}`, orderby: 'seq' });
  const seen = new Set(delivered.map((r) => r.seq));
  const state = process.env.FM_STATE_OVERRIDE || path.join(process.env.FM_HOME, 'state');
  const spool = path.join(state, '.task-delivery-outbox', crypto.createHash('sha256').update(consumer).digest('hex'));
  fs.mkdirSync(spool, { recursive: true });
  const activation = path.join(spool, `${taskIdOf(args)}.activated`);
  if (!fs.existsSync(activation)) {
    // First activation establishes a baseline, not a replay of historical work.
    fs.writeFileSync(activation, String(lastSeq));
    out(`activated ${consumer} task=${taskIdOf(args)} after=${lastSeq}`);
    return;
  }
  const baseline = Number(fs.readFileSync(activation, 'utf8'));
  const events = taskStream.filter((e) => e.seq > baseline);
  for (const event of events) {
    if (event.kind === 'comment' && event.actorRole === 'owner' && event.idempotencyKey?.startsWith('owner-comment:')) continue;
    const receipt = path.join(spool, `${event.seq}.json`);
    if (seen.has(event.seq) && !fs.existsSync(receipt)) continue;
    // Persist recovery intent before claiming. A replay owns only this consumer's spool.
    if (!fs.existsSync(receipt)) fs.writeFileSync(receipt, JSON.stringify(event), { flag: 'wx' });
    const res = await http('POST', '/api/fm_task_delivery', { consumer, seq: event.seq });
    if (res.status !== 409) ok(res, 'claim event delivery');
    const queued = spawnSync('bash', ['-c', 'source "$1/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"; trap \'fm_lock_release "$FM_WAKE_QUEUE_LOCK"\' EXIT; if ! test -f "$4.sent"; then if ! test -f "$STATE/.wake-queue" || ! grep -Fq "$(printf "\\t%s\\t" "$2")" "$STATE/.wake-queue"; then fm_wake_append_locked check "$2" "$3" || exit; fi; : > "$4.sent"; fi', 'task-delivery', HERE, `task-event-${event.seq}`, `task event ${event.seq}: ${event.taskId} ${event.kind}`, receipt], { encoding: 'utf8', env: process.env });
    if (queued.status !== 0) throw new Fail(3, `delivery ${event.seq} claimed but wake append failed: ${queued.stderr}`);
    fs.unlinkSync(receipt);
    out(`delivered ${consumer} seq=${event.seq}`);
  }
}

const COMMANDS = {
  'turn-end': cmdTurnEnd, deliver: cmdDeliver, describe: cmdDescribe, thread: cmdThread,
  create: cmdCreate, import: cmdImport, assign: cmdAssign, start: cmdStart, heartbeat: cmdHeartbeat, done: cmdDone, ask: cmdAsk, block: cmdBlock,
  unblock: cmdUnblock, approve: cmdApprove, changes: cmdChanges, reopen: cmdReopen, reassign: cmdReassign, archive: cmdArchive, comment: cmdComment, event: cmdEvent,
  document: cmdDocument, link: cmdLink, rows: cmdRows, check: cmdCheck, 'owner-check': cmdOwnerCheck, gate: cmdGate, show: cmdShow, list: cmdList, resume: cmdResume, reproject: cmdReproject,
  row: cmdRow, backlog: cmdBacklog, checks: cmdChecks,
};

async function main(argv) {
  const [command, ...rest] = argv;
  if (!command || ['-h', '--help', 'help'].includes(command)) {
    const header = [];
    for (const line of fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1)) {
      if (!line.startsWith('//')) break;
      header.push(line.replace(/^\/\/ ?/, ''));
    }
    process.stdout.write(`${header.join('\n')}\n`);
    return 0;
  }
  if (!COMMANDS[command]) throw usage(`unknown command ${command}; run fm-task.sh --help`);
  await COMMANDS[command](parseArgs(command, rest));
  return 0;
}

main(process.argv.slice(2)).then(
  (code) => {
    process.exitCode = code;
  },
  (error) => {
    process.stderr.write(`fm-task: ${error.message}\n`);
    process.exitCode = error instanceof Fail ? error.code : 1;
  },
);
