#!/usr/bin/env node
// fm-project.sh list [--json], refresh, seed [--file PATH], add NAME, set NAME,
// remove NAME. add/set accept --mode, --yolo on|off, --forge, --branch-prefix,
// --origin, --default-branch, --description. remove soft-removes; never deletes git.
// 5001 is authoritative. refresh writes projects.md atomically; on unavailable
// API it retains the cache and reports its age. All mutations require the API.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const data = process.env.FM_DATA_OVERRIDE || path.join(home, 'data');
const cache = path.join(data, 'projects.md');
const help = 'fm-project.sh list [--json] | refresh | seed [--file PATH] | add NAME | set NAME | remove NAME\nadd/set: --mode M --yolo on|off --forge F --branch-prefix P --origin URL --default-branch B --description TEXT';
const commands = { list: ['json'], refresh: [], seed: ['file'], add: ['mode','yolo','forge','branch-prefix','origin','default-branch','description'], set: ['mode','yolo','forge','branch-prefix','origin','default-branch','description'], remove: [] };
const args = process.argv.slice(2);
const command = args.shift();
const flags = {}, positional = [];
function fail(message) { throw new Error(message); }
function parse() {
  if (args.includes('--help') || command === '--help' || !command) { console.log(help); process.exit(0); }
  if (!commands[command]) fail(`unknown command ${command}; ${help}`);
  while (args.length) {
    const token = args.shift();
    if (!token.startsWith('--')) { positional.push(token); continue; }
    const key = token.slice(2);
    if (!commands[command].includes(key)) fail(`unknown flag ${token}; ${help}`);
    if (Object.hasOwn(flags, key)) fail(`duplicate flag ${token}`);
    flags[key] = key === 'json' ? true : args.shift();
    if (flags[key] === undefined) fail(`missing value for ${token}`);
  }
  const needsName = ['add','set','remove'].includes(command);
  if (positional.length !== (needsName ? 1 : 0)) fail(help);
}
let token;
async function http(method, suffix = '', body) {
  if (!token) {
    const file = process.env.FM_TASK_TOKEN_FILE || path.join(os.homedir(), '.local/share/cfw-scripts-private/notify-firstmate.token');
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.uid !== process.getuid() || stat.mode & 0o077) fail('token must be an owner-only regular file');
    token = fs.readFileSync(file, 'utf8').trim();
    if (!token || /[\r\n"\\]/.test(token)) fail('invalid token file');
  }
  const base = (process.env.FM_TASK_BASE_URL || 'http://127.0.0.1:5001').replace(/\/+$/, '');
  if (!/^https?:\/\//.test(base)) fail('FM_TASK_BASE_URL must use http or https');
  const headers = { accept: 'application/json', 'content-type': 'application/json' };
  if (process.env.FM_TASK_AUTH === 'cookie') headers.cookie = `cfw.auth.session=${token}`;
  else headers.authorization = `Bearer ${token}`;
  const res = await fetch(`${base}/api/fm_project${suffix}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(10000) });
  if (!res.ok) fail(`project API refused ${method}: HTTP ${res.status}`);
  if (res.status === 204) return null;
  return res.json();
}
async function rows() {
  const result = [];
  for (let skip = 0; ; skip += 100) {
    const response = await http('GET', `?$top=100&$skip=${skip}&$orderby=name`);
    const page = response.value;
    if (!Array.isArray(page)) fail('project API returned no collection');
    result.push(...page);
    if (page.length < 100) return result;
  }
}
function active(rows) { return rows.filter(row => !row.removedAt); }
function render(rows) {
  return '# Projects\n\n' + active(rows).map(row => `- ${row.name} [${row.mode || 'no-mistakes'}${row.yolo === 'on' ? ' +yolo' : ''}${row.forge && row.forge !== 'none' ? ` forge=${row.forge}` : ''}${row.branchPrefix !== null && row.branchPrefix !== undefined && row.branchPrefix !== 'fm/' ? ` branch=${row.branchPrefix}` : ''}] - ${row.description || ''} (added ${(row.addedAt || '').slice(0,10)})`).join('\n') + '\n';
}
function writeCache(records) {
  fs.mkdirSync(data, { recursive: true });
  const tmp = `${cache}.${process.pid}.tmp`;
  try { fs.writeFileSync(tmp, render(records), { mode: 0o600 }); fs.renameSync(tmp, cache); }
  finally { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); }
}
function validate(row) {
  if (!row.name || /[\r\n\[\]]| - /.test(row.name)) fail('invalid project name');
  if (!['no-mistakes','no-mistakes-prod-only','direct-PR','local-only'].includes(row.mode)) fail('invalid mode');
  if (!['on','off'].includes(row.yolo)) fail('yolo must be on or off');
  if (!['none','gerrit','forgejo','external'].includes(row.forge)) fail('invalid forge');
  if (row.mode === 'local-only' && row.forge !== 'none') fail('local-only cannot bind a forge');
  if (/\s/.test(row.branchPrefix)) fail('branch prefix cannot contain whitespace');
  if (/[\r\n]/.test(row.description || '')) fail('description must be one line');
}
function seedRows(file) {
  return fs.readFileSync(file, 'utf8').split('\n').filter(line => line.startsWith('- ')).map(line => {
    const match = line.match(/^- (.+?)(?: \[([^\]]*)\])? - (.*?)(?: \(added ([^)]+)\))?$/);
    if (!match) fail(`cannot parse project seed line: ${line}`);
    const [, name, annotation = '', sourceDescription, added] = match;
    // Preserve ownership notes that share the historical added annotation.
    const trailingNote = added?.slice(10) || '';
    const description = trailingNote ? `${sourceDescription} (added-note${trailingNote})` : sourceDescription;
    let mode = 'no-mistakes', yolo = 'off', forge = 'none', branchPrefix = 'fm/';
    for (const word of annotation.split(/\s+/).filter(Boolean)) {
      if (word === '+yolo') yolo = 'on';
      else if (word.startsWith('forge=')) forge = word.slice(6);
      else if (word.startsWith('branch=')) branchPrefix = word.slice(7);
      else mode = word;
    }
    const clone = path.join(process.env.FM_PROJECTS_OVERRIDE || path.join(home, 'projects'), name);
    function git(...args) { try { return execFileSync('git', ['-C', clone, ...args], { encoding: 'utf8', stdio: ['ignore','pipe','ignore'] }).trim(); } catch { return null; } }
    const row = { name, mode, yolo, forge, branchPrefix, description, origin: git('remote','get-url','origin'), defaultBranch: git('symbolic-ref','--short','refs/remotes/origin/HEAD')?.replace(/^origin\//, '') || null, addedAt: added ? new Date(added.slice(0, 10)).toISOString() : null, removedAt: null };
    validate(row);
    return row;
  });
}
try {
  parse();
  if (command === 'refresh') {
    try { writeCache(await rows()); }
    catch (error) {
      const age = fs.existsSync(cache) ? `${Math.floor((Date.now() - fs.statSync(cache).mtimeMs) / 1000)}s` : 'absent';
      console.error(`warn: project registry unavailable; cache age=${age}; ${error.message}`);
      process.exitCode = 1;
    }
  } else {
    const records = await rows();
    if (command === 'list') {
      const current = active(records);
      if (flags.json) console.log(JSON.stringify(current));
      else { console.log(`projects[${current.length}]{name,mode,yolo}:`); for (const row of current) console.log(`  ${JSON.stringify(row.name)},${row.mode},${row.yolo}`); }
    } else if (command === 'seed') {
      const seed = seedRows(flags.file || cache);
      for (const row of seed) {
        const existing = records.find(item => item.name === row.name);
        if (!existing) await http('POST', '', row);
        else await http('PATCH', `/${encodeURIComponent(existing.id)}`, row);
      }
      const result = await rows();
      for (const row of seed) {
        const stored = result.find(item => item.name === row.name);
        for (const key of Object.keys(row)) {
          const expected = row[key] ?? null, actual = stored?.[key] ?? null;
          const same = key.endsWith('At') && expected && actual ? Date.parse(expected) === Date.parse(actual) : expected === actual;
          if (!same) fail(`seed parity mismatch: ${row.name}.${key}`);
        }
      }
      writeCache(result);
      console.log(`seeded: ${seed.length}`);
    } else {
      const name = positional[0], existing = records.find(row => row.name === name);
      if (command !== 'add' && !existing) fail(`project not found: ${name}`);
      if (command === 'add' && existing && !existing.removedAt) fail(`project already exists: ${name}; use set`);
      const row = existing ? { ...existing } : { name, mode: 'no-mistakes', yolo: 'off', forge: 'none', branchPrefix: 'fm/', origin: null, defaultBranch: null, description: '', addedAt: new Date().toISOString(), removedAt: null };
      const mapping = { 'branch-prefix': 'branchPrefix', 'default-branch': 'defaultBranch' };
      for (const [key, value] of Object.entries(flags)) row[mapping[key] || key] = value;
      row.removedAt = command === 'remove' ? existing.removedAt || new Date().toISOString() : null;
      validate(row);
      const { id, ...body } = row;
      await http(existing ? 'PATCH' : 'POST', existing ? `/${encodeURIComponent(id)}` : '', body);
      writeCache(await rows());
      console.log(`project: ${name}\nresult: ${command}`);
    }
  }
} catch (error) {
  console.log(`error: ${error.message}\nhelp: fm-project.sh --help`);
  process.exitCode = 2;
}
