#!/usr/bin/env node
// fm_doc's shared git publication client. Git remains authoritative.
// Configuration: FM_TASK_BASE_URL, FM_TASK_TOKEN_FILE and FM_TASK_AUTH match fm-task.sh.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
const tombstone = 'application/x-fm-deleted';
const metadata = 'id,scope,path,version,kind,source,gitSha,mediaType,by,at';
const help = `fm-doc.sh publish|diff --repo firstmate|pi-harness --root CLONE [--json]
fm-doc.sh list [--repo firstmate|pi-harness] [--json]
fm-doc.sh get --path REPO/PATH [--full] [--json]
fm-doc.sh materialize --repo firstmate|pi-harness --output NEW_DIRECTORY [--json]
Publishes committed tracked files only. list shows current shared git documents.
get previews 1200 characters; --full returns the complete text.
materialize requires a new export directory and never overwrites a git clone.
Examples: fm-doc.sh publish --repo firstmate --root .
          fm-doc.sh diff --repo firstmate --root .
          fm-doc.sh get --path firstmate/AGENTS.md --full`;
const specs = { publish: ['repo','root','json'], diff: ['repo','root','json'], list: ['repo','json'], get: ['path','full','json'], materialize: ['repo','output','json'] };
let command, flags = {}, token;
function fail(message, code = 1) { const error = new Error(message); error.code = code; throw error; }
function parse() {
  const args = process.argv.slice(2); command = args.shift() || 'list';
  if (command === '--help' || args.includes('--help')) { console.log(help); process.exit(0); }
  if (!specs[command]) fail(`unknown command; ${help}`, 2);
  while (args.length) {
    const key = args.shift();
    if (!key.startsWith('--') || !specs[command].includes(key.slice(2))) fail(`unknown argument ${key}; ${help}`, 2);
    const name = key.slice(2);
    if (Object.hasOwn(flags, name)) fail(`duplicate ${key}`, 2);
    flags[name] = ['json','full'].includes(name) ? true : args.shift();
    if (flags[name] === undefined || (typeof flags[name] === 'string' && flags[name].startsWith('--'))) fail(`missing ${key}`, 2);
  }
  if (flags.repo && !['firstmate','pi-harness'].includes(flags.repo)) fail('repo must be firstmate or pi-harness', 2);
  for (const required of ({publish:['repo','root'],diff:['repo','root'],get:['path'],materialize:['repo','output']}[command] || [])) if (!flags[required]) fail(`--${required} is required; ${help}`, 2);
  if (flags.path) safePath(flags.path);
  if (command === 'materialize' && fs.existsSync(path.resolve(flags.output))) fail('export directory must not exist', 2);
}
function safePath(value) {
  if (typeof value !== 'string' || !/^(firstmate|pi-harness)\//.test(value) || value.includes('\\') || /[\x00-\x1f\x7f]/.test(value) || value.split('/').some(s => !s || s === '.' || s === '..')) fail('invalid repository document path', 2);
  return value;
}
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
  const headers = {accept:'application/json','content-type':'application/json'};
  if (process.env.FM_TASK_AUTH === 'cookie') headers.cookie = `cfw.auth.session=${token}`;
  else headers.authorization = `Bearer ${token}`;
  let response;
  try { response = await fetch(`${base}/api/fm_doc${suffix}`, {method,headers,body: body === undefined ? undefined : JSON.stringify(body),signal:AbortSignal.timeout(15000)}); }
  catch { fail('document service unavailable; retry fm-doc.sh ' + command); }
  if (!response.ok) fail(`document service refused ${method}: HTTP ${response.status}`, response.status === 409 ? 409 : 1);
  if (response.status === 204) return null;
  try { return await response.json(); } catch { fail('document service returned invalid JSON'); }
}
async function current() {
  const latest = new Map();
  for (let skip = 0; ; skip += 100) {
    const query = new URLSearchParams({'$top':'100','$skip':String(skip),'$orderby':'id','$select':metadata,'$filter':"scope eq 'shared' and source eq 'git'"});
    const data = await http('GET', `?${query}`);
    if (!Array.isArray(data.value)) fail('document service returned no collection');
    for (const row of data.value) {
      safePath(row.path);
      if (flags.repo && !row.path.startsWith(flags.repo + '/')) continue;
      if (!Number.isSafeInteger(Number(row.version)) || Number(row.version) < 1) fail('document version is invalid');
      if (!latest.has(row.path) || Number(latest.get(row.path).version) < Number(row.version)) latest.set(row.path,row);
    }
    if (data.value.length < 100) return latest;
  }
}
function git(...args) {
  try { return execFileSync('git',['-C',flags.root,...args],{maxBuffer:32*1024*1024,stdio:['ignore','pipe','ignore']}); }
  catch { fail('cannot read committed git objects from --root'); }
}
function snapshot() {
  const sha = git('rev-parse','HEAD').toString().trim();
  const prefixes = flags.repo === 'firstmate' ? ['AGENTS.md','.agents/skills/','custom-skills/','docs/'] : ['.agents/skills/','.pi/agent/skills/','.claude/skills/','.gemini/config/skills/','ext-packages/'];
  const files = new Map();
  for (const entry of git('ls-tree','-rz','--full-tree','HEAD').toString().split('\0').filter(Boolean)) {
    const [header, name] = entry.split('\t');
    const [mode,type,object] = header.split(' ');
    if (type !== 'blob' || !['100644','100755'].includes(mode) || !prefixes.some(prefix => prefix.endsWith('/') ? name.startsWith(prefix) : name === prefix)) continue;
    if (/(^|\/)(?:secrets?|credentials?)(?:\/|\.)|(?:^|\/)\.env(?:\.|$)|\.(?:pem|key|p12|pfx)$/i.test(name)) continue;
    if (flags.repo === 'pi-harness' && name.startsWith('ext-packages/') && !name.includes('/skills/')) continue;
    const bytes = git('cat-file','blob',object);
    if (bytes.includes(0) || !Buffer.from(bytes.toString('utf8')).equals(bytes)) fail(`non-text tracked document: ${name}`);
    const docPath = safePath(`${flags.repo}/${name}`);
    files.set(docPath,{content:bytes.toString('utf8'),kind:name === 'AGENTS.md' ? 'agents' : name.includes('skills/') ? 'skill' : 'doc',mediaType:name.endsWith('.md') ? 'text/markdown' : name.endsWith('.json') ? 'application/json' : 'text/plain'});
  }
  return {sha,files};
}
async function detail(row) {
  if (!row || !row.id) fail('document not found');
  const body = await http('GET',`/${encodeURIComponent(row.id)}`);
  const doc = body?.data ?? body;
  if (typeof doc?.content !== 'string') fail('document service returned no content');
  return doc;
}
function output(value, key = 'result') {
  if (flags.json) { console.log(JSON.stringify(value,null,2)); return; }
  if (Array.isArray(value)) {
    const fields = key === 'differences' ? ['path','localSha','publishedSha','change'] : ['path','gitSha','version'];
    console.log(`${key}[${value.length}]{${fields.join(',')}}:`);
    for (const row of value) console.log('  ' + fields.map(field => JSON.stringify(row[field] ?? null)).join(','));
  } else for (const [key,item] of Object.entries(value)) console.log(`${key}: ${JSON.stringify(item)}`);
}
try {
  parse();
  const rows = await current();
  if (command === 'list') output([...rows.values()].filter(r => r.mediaType !== tombstone).sort((a,b) => a.path.localeCompare(b.path)),'documents');
  if (command === 'get') {
    const row = rows.get(flags.path);
    if (!row || row.mediaType === tombstone) fail('document not found');
    const doc = await detail(row);
    output({path:row.path,gitSha:row.gitSha,version:row.version,content:flags.full ? doc.content : doc.content.slice(0,1200),characters:doc.content.length,...(!flags.full && doc.content.length > 1200 ? {help:`fm-doc.sh get --path ${row.path} --full`} : {})});
  }
  if (['publish','diff'].includes(command)) {
    const {sha,files} = snapshot(); const differences = []; let inserted = 0;
    for (const name of [...new Set([...files.keys(),...rows.keys()])].sort()) {
      const local = files.get(name), row = rows.get(name);
      if (!local && row?.mediaType === tombstone) continue;
      const published = row && row.mediaType !== tombstone ? await detail(row) : null;
      if (local && published && local.content === published.content && local.mediaType === published.mediaType) continue;
      differences.push({path:name,localSha:sha,publishedSha:row?.gitSha || null,change:!local ? 'deleted' : !published ? 'added' : 'changed'});
      if (command !== 'publish') continue;
      const body = {scope:'shared',path:name,version:Number(row?.version || 0)+1,kind:local?.kind || row.kind,source:'git',gitSha:sha,content:local?.content || '',mediaType:local?.mediaType || tombstone,by:process.env.FM_TASK_ACTOR || os.userInfo().username,at:new Date().toISOString()};
      try { await http('POST','',body); inserted++; }
      catch (error) {
        if (error.code !== 409) throw error;
        const winner = (await current()).get(name);
        const readback = await detail(winner);
        if (winner.gitSha !== sha || readback.content !== body.content || winner.mediaType !== body.mediaType) fail(`publication raced at ${name}; retry publish`);
      }
    }
    if (command === 'diff') { output(differences,'differences'); if (differences.length) process.exitCode = 1; }
    else output({repository:flags.repo,gitSha:sha,inserted,unchanged:files.size-differences.filter(r => r.change !== 'deleted').length,help:`fm-doc.sh list --repo ${flags.repo}`});
  }
  if (command === 'materialize') {
    const destination = path.resolve(flags.output);
    fs.mkdirSync(destination,{mode:0o700}); let count = 0;
    for (const row of rows.values()) {
      if (row.mediaType === tombstone) continue;
      const target = path.join(destination,safePath(row.path));
      fs.mkdirSync(path.dirname(target),{recursive:true,mode:0o700});
      fs.writeFileSync(target,(await detail(row)).content,{flag:'wx',mode:0o600}); count++;
    }
    output({directory:destination,files:count});
  }
} catch (error) { console.log(`error: ${JSON.stringify(error.message)}`); process.exitCode = error.code === 2 ? 2 : 1; }
