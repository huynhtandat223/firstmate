#!/usr/bin/env node
// Public machine registry and generation-lease CLI; credentials follow fm-task.sh.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const home = process.env.FM_HOME || root;
const config = process.env.FM_CONFIG_OVERRIDE || path.join(home, 'config');
const help = 'fm-host.sh register|heartbeat|show [--json] | lease take|release|show|check [--json] | worker claim|release <task>\nFM_HOST_ID: stable machine identity; FM_HOME_NAME: backlog home (default main).\nconfig/home-lease enables mandatory cross-machine ownership checks.';
const args = process.argv.slice(2);
const json = args.includes('--json');
const cmd = args.filter(a => a !== '--json');
function fail(message, code = 1) { const e = new Error(message); e.code = code; throw e; }
const now = () => new Date().toISOString();
const literal = s => `'${String(s).replaceAll("'", "''")}'`;
let token;
async function request(method, table, suffix = '', body) {
  if (!token) {
    const file = process.env.FM_TASK_TOKEN_FILE || path.join(os.homedir(), '.local/share/cfw-scripts-private/notify-firstmate.token');
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.uid !== process.getuid() || st.mode & 0o077) fail('token must be an owner-only regular file');
    token = fs.readFileSync(file, 'utf8').trim();
    if (!token || /[\r\n"\\]/.test(token)) fail('invalid token file');
  }
  const headers = { accept: 'application/json', 'content-type': 'application/json' };
  if (process.env.FM_TASK_AUTH === 'cookie') headers.cookie = `cfw.auth.session=${token}`;
  else headers.authorization = `Bearer ${token}`;
  const base = (process.env.FM_TASK_BASE_URL || 'http://127.0.0.1:5001').replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) fail('base URL must use http or https');
  const res = await fetch(`${base}/api/${table}${suffix}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  if (res.status === 409) fail('ownership race lost; inspect lease show before retrying');
  if (!res.ok) fail(`machine record refused ${method}: HTTP ${res.status}`);
  return res.status === 204 ? null : res.json();
}
async function list(table, filter, orderby) {
  const rows = [];
  for (let skip = 0; ; skip += 100) {
    const query = new URLSearchParams({ $top: '100', $skip: String(skip), ...(filter ? { $filter: filter } : {}), ...(orderby ? { $orderby: orderby } : {}) });
    const result = await request('GET', table, `?${query}`);
    if (!Array.isArray(result.value)) fail('machine record returned no collection');
    rows.push(...result.value);
    if (result.value.length < 100) return rows;
  }
}
function identity() {
  if (process.env.FM_HOST_ID) return process.env.FM_HOST_ID;
  const file = path.join(config, 'host-id');
  if (fs.existsSync(file)) return fs.readFileSync(file, 'utf8').trim();
  fs.mkdirSync(config, { recursive: true });
  // Hostnames repeat across machines; a random suffix makes the id one machine's own.
  const id = `${os.hostname().replace(/[^a-zA-Z0-9_.-]/g, '-').replace(/^[^a-zA-Z0-9]+/, '').slice(0, 100) || 'host'}-${crypto.randomBytes(4).toString('hex')}`;
  try { fs.writeFileSync(file, `${id}\n`, { flag: 'wx', mode: 0o600 }); }
  catch (e) { if (e.code !== 'EEXIST') throw e; }
  return fs.readFileSync(file, 'utf8').trim();
}
const homeName = process.env.FM_HOME_NAME || 'main';
async function latest() { return (await list('fm_home_lease', `home eq ${literal(homeName)}`, 'generation desc'))[0]; }
function fresh(row) { const at = Date.parse(row?.heartbeatAt); return Number.isFinite(at) && Date.now() - at < 180000; }
async function check(id) {
  const row = await latest();
  if (!row || row.hostId !== id || row.releasedAt || !fresh(row)) fail(`home ${homeName} is not owned by ${id}; holder=${row?.hostId || 'none'} generation=${row?.generation || 0}`);
  return row;
}
async function host(id) { return (await list('fm_host', `hostId eq ${literal(id)}`))[0]; }
async function patch(table, row, body) { return request('PATCH', table, `/${encodeURIComponent(row.id)}`, body); }
function output(value) {
  if (json) console.log(JSON.stringify(value));
  else if (Array.isArray(value)) {
    console.log(`hosts[${value.length}]{hostId,sshAlias,lastHeartbeatAt,fmVersion}:`);
    for (const r of value) console.log(`  ${[r.hostId,r.sshAlias,r.lastHeartbeatAt,r.fmVersion].map(v => JSON.stringify(v ?? '')).join(',')}`);
  } else {
    for (const [key, val] of Object.entries(value)) console.log(`${key}: ${JSON.stringify(val)}`);
  }
}
try {
  if (args.includes('--help')) { console.log(help); process.exit(0); }
  if (args.some(a => a.startsWith('--') && a !== '--json') || !['register','heartbeat','show','lease','worker'].includes(cmd[0]) || (cmd[0] === 'lease' ? cmd.length !== 2 || !['take','release','show','check'].includes(cmd[1]) : cmd[0] === 'worker' ? cmd.length !== 3 || !['claim','release'].includes(cmd[1]) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(cmd[2]) : cmd.length !== 1)) fail(help, 2);
  if (cmd[0] === 'show') output(await list('fm_host', null, 'hostId'));
  else if (cmd[0] === 'lease' && cmd[1] === 'show') output(await latest() || { home: homeName, holder: 'none' });
  else {
    const id = identity();
    if (!/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$/.test(id)) fail('invalid host id', 2);
    if (cmd[0] === 'register') {
      const existing = await host(id);
      let version = 'unknown';
      try { version = execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch { /* Non-git install. */ }
      const body = { hostId: id, sshAlias: process.env.FM_SSH_ALIAS || os.hostname(), fmVersion: version, toolsJson: JSON.stringify({ node: process.version }), lastHeartbeatAt: now(), ...(existing ? {} : { registeredAt: now(), wakeQueueLength: 0, liveWorkers: 0 }) };
      if (existing) await patch('fm_host', existing, body); else await request('POST', 'fm_host', '', body);
      output(body);
    } else if (cmd[0] === 'heartbeat') {
      const row = await check(id);
      const machine = await host(id);
      if (!machine) fail('host is not registered; run register');
      // Unknown worker state is conservative: the caller must supply its reconciled count.
      const count = Number(process.env.FM_HOST_LIVE_WORKERS);
      const queue = Number(process.env.FM_HOST_WAKE_QUEUE_LENGTH);
      if (!Number.isSafeInteger(count) || count < 0 || !Number.isSafeInteger(queue) || queue < 0) fail('heartbeat requires reconciled FM_HOST_LIVE_WORKERS and FM_HOST_WAKE_QUEUE_LENGTH', 2);
      const at = now();
      await patch('fm_host', machine, { lastHeartbeatAt: at, liveWorkers: count, wakeQueueLength: queue });
      await check(id);
      await patch('fm_home_lease', row, { heartbeatAt: at });
      output({ hostId: id, generation: row.generation, heartbeatAt: at });
    } else if (cmd[0] === 'worker') {
      const machine = await host(id);
      if (!machine) fail('host is not registered; run register');
      const current = Number(machine.liveWorkers) || 0;
      if (cmd[1] === 'claim') {
        // Claimed before the launch: the count is a conservative floor until the next heartbeat reconciles it.
        await check(id);
        await patch('fm_host', machine, { liveWorkers: current + 1 });
        output({ hostId: id, task: cmd[2], liveWorkers: current + 1 });
      } else {
        // A launch that never produced a worker gives its slot back; no lease is needed to lower our own count.
        await patch('fm_host', machine, { liveWorkers: Math.max(0, current - 1) });
        output({ hostId: id, task: cmd[2], liveWorkers: Math.max(0, current - 1) });
      }
    } else if (cmd[1] === 'check') output(await check(id));
    else if (cmd[1] === 'take') {
      const row = await latest();
      if (row && !row.releasedAt) {
        if (row.hostId === id && fresh(row)) { output(row); process.exit(0); }
        // A holder takes its own expired lease back even with workers still counted (a restart or a stopped renewal):
        // only heartbeat lowers that count, which needs a fresh lease. It takes generation+1 like any take, so a
        // competing take conflicts on that generation instead of both succeeding.
        if (row.hostId !== id) {
          const holder = await host(row.hostId);
          if (fresh(row) || !holder || holder.liveWorkers !== 0) fail(`home ${homeName} held by ${row.hostId} generation=${row.generation} liveWorkers=${holder ? holder.liveWorkers : 'unknown'}; release or wait for expiry with no live workers`);
        }
      }
      if (!await host(id)) fail('register host before lease take');
      const body = { home: homeName, generation: (row?.generation || 0) + 1, hostId: id, takenAt: now(), heartbeatAt: now(), releasedAt: null };
      await request('POST', 'fm_home_lease', '', body);
      output(await check(id));
    } else {
      const row = await latest();
      if (row?.hostId === id && row.releasedAt) { output(row); process.exit(0); }
      await check(id);
      const holder = await host(id);
      if (!holder || holder.liveWorkers !== 0 || process.env.FM_HOST_LIVE_WORKERS !== '0') fail('release requires no live workers in both current reconciliation and host record');
      await patch('fm_home_lease', row, { releasedAt: now() });
      output(await latest());
    }
  }
} catch (e) { console.log(`error: ${JSON.stringify(e.message)}\nhelp: fm-host.sh --help`); process.exit(e.code || 1); }
