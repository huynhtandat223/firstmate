// The stand-in for Dev 5001 that tests/fm-task.test.sh and tests/fm-task-shadow.test.sh run the real writer against.
// Usage: node server.mjs <port-file> <schema.json> <token>
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';

const [portFile, schemaFile, token] = process.argv.slice(2);
const SCHEMA = JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
const camel = (s) => s.split('_').map((p, i) => (i ? p[0].toUpperCase() + p.slice(1) : p)).join('');
const pascal = (s) => s[0].toUpperCase() + s.slice(1);
const db = {};
const NAVS = {};
for (const table of Object.keys(SCHEMA)) db[table] = [];
for (const [table, def] of Object.entries(SCHEMA)) {
  if (!def.parent) continue;
  const parent = Object.keys(SCHEMA).find((t) => camel(t) === def.parent[0]);
  (NAVS[parent] ||= {})[def.parent[1]] = table;
}
let log = [];
let rivals = 0;
let lose = { mode: '', n: 0 };
let delay = { table: '', ms: 0, n: 0, verb: 'patch' };

const reply = (res, status, body) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(body === undefined ? '' : JSON.stringify(body));
};
const refusal = (status, errorCode, message, details = null) => ({ status, body: { success: false, data: null, errorCode, message, details } });

function normalize(table, body, partial) {
  const errors = {};
  const row = {};
  for (const [name, f] of Object.entries(SCHEMA[table].f)) {
    const present = Object.prototype.hasOwnProperty.call(body, name);
    if (f.sv) {
      if (present) errors[pascal(name)] = 'INVALID_WRITE';
      continue;
    }
    if (!present) {
      if (partial) continue;
      if (f.t === 'i') row[name] = 0;
      else if (f.n) row[name] = null;
      else errors[pascal(name)] = `The ${pascal(name)} field is required.`;
      continue;
    }
    const v = body[name];
    if (v === null) {
      if (f.n) row[name] = null;
      else errors[pascal(name)] = `The ${pascal(name)} field is required.`;
      continue;
    }
    if (f.t === 's' && typeof v !== 'string') errors[pascal(name)] = `The ${pascal(name)} field must be a string.`;
    else if (f.t === 'i' && !Number.isInteger(v)) errors[pascal(name)] = `The ${pascal(name)} field must be an integer.`;
    else if (f.t === 'd' && Number.isNaN(Date.parse(v))) errors[pascal(name)] = `The ${pascal(name)} field must be a date.`;
    else if (f.m && typeof v === 'string' && v.length > f.m) errors[pascal(name)] = `The field ${pascal(name)} must be a string with a maximum length of ${f.m}.`;
    else row[name] = v;
  }
  return { errors, row };
}

function conflict(table, row, exceptId) {
  for (const group of SCHEMA[table].u) {
    const hit = db[table].find((r) => r.id !== exceptId && group.every((k) => r[k] === row[k]));
    if (hit) return refusal(409, 'UNIQUE_KEY_CONFLICT', `A ${table} row with the same (${group.join(', ')}) already exists.`, { key: group, existingId: hit.id });
  }
  return null;
}

function create(table, body) {
  const { errors, row } = normalize(table, body, false);
  const children = [];
  for (const [nav, childTable] of Object.entries(NAVS[table] || {})) {
    if (body[nav] === undefined) continue;
    if (!Array.isArray(body[nav])) {
      errors[pascal(nav)] = 'must be an array';
      continue;
    }
    body[nav].forEach((child, i) => {
      const n = normalize(childTable, child, false);
      for (const [k, v] of Object.entries(n.errors)) errors[`${pascal(nav)}[${i}].${k}`] = v;
      children.push([childTable, n.row]);
    });
  }
  if (Object.keys(errors).length) return refusal(400, 'VALIDATION_ERROR', 'One or more validation errors occurred.', errors);
  const clash = conflict(table, row, null);
  if (clash) return clash;
  const id = crypto.randomUUID();
  const stored = { id, ...row };
  for (const [name, f] of Object.entries(SCHEMA[table].f)) {
    if (f.sv === 'now') stored[name] = new Date().toISOString();
    if (f.sv === 'callerId') stored[name] = 'caller-1';
  }
  db[table].push(stored);
  for (const [childTable, childRow] of children) {
    const child = { id: crypto.randomUUID(), ...childRow, fmTaskEventId: id };
    for (const [name, f] of Object.entries(SCHEMA[childTable].f)) if (f.sv === 'now') child[name] = new Date().toISOString();
    db[childTable].push(child);
  }
  return { status: 201, body: { success: true, data: stored, errorCode: null, message: null, details: null } };
}

function patch(table, id, body) {
  const target = db[table].find((r) => r.id === id);
  if (!target) return refusal(404, 'NOT_FOUND', `${table} ${id} not found.`);
  const { errors, row } = normalize(table, body, true);
  if (Object.keys(errors).length) return refusal(400, 'VALIDATION_ERROR', 'One or more validation errors occurred.', errors);
  const next = { ...target, ...row };
  const clash = conflict(table, next, id);
  if (clash) return clash;
  Object.assign(target, row);
  return { status: 200, body: { success: true, data: target, errorCode: null, message: null, details: null } };
}

const literal = (text) => {
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(text)) return { guid: text };
  if (/^'.*'$/s.test(text)) return text.slice(1, -1).replaceAll("''", "'");
  if (text === 'true') return true;
  if (text === 'false') return false;
  if (text === 'null') return null;
  return Number(text);
};

function list(table, query) {
  let rows = db[table];
  const filter = query.get('$filter');
  if (filter) {
    for (const clause of filter.split(/ and /)) {
      const m = /^(\w+) (eq|ne|gt|ge|lt|le) (.+)$/s.exec(clause.trim());
      if (!m || !(m[1] in SCHEMA[table].f || m[1] === 'id' || m[1] === 'fmTaskEventId')) return refusal(400, 'INVALID_QUERY', `Could not find a property named '${m ? m[1] : clause}' on type ${table}.`);
      let want = literal(m[3]);
      const isGuid = m[1] === 'id' || m[1] === 'fmTaskEventId';
      // the real API types these two as Edm.Guid: a quoted string is refused, a bare guid is the only literal
      if (isGuid !== (typeof want === 'object' && want !== null)) return refusal(400, 'INVALID_QUERY', `A binary operator with incompatible types was detected on '${m[1]}'.`);
      if (isGuid) want = want.guid;
      const op = { eq: (a) => a === want, ne: (a) => a !== want, gt: (a) => a > want, ge: (a) => a >= want, lt: (a) => a < want, le: (a) => a <= want }[m[2]];
      rows = rows.filter((r) => op(r[m[1]]));
    }
  }
  const order = query.get('$orderby');
  if (order) {
    const [field, dir] = order.split(' ');
    rows = [...rows].sort((a, b) => (a[field] > b[field] ? 1 : a[field] < b[field] ? -1 : 0) * (dir === 'desc' ? -1 : 1));
  }
  const top = query.has('$top') ? Number(query.get('$top')) : 100;
  if (top > 100) return refusal(400, 'INVALID_QUERY', `The limit of '100' for Top query has been exceeded. The value from the incoming request is '${top}'.`);
  const skip = Number(query.get('$skip') || 0);
  const out = { value: rows.slice(skip, skip + top) };
  if (query.get('$count') === 'true') out['@odata.count'] = rows.length;
  return { status: 200, body: out };
}

const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://x');
    const raw = Buffer.concat(chunks).toString('utf8');
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts[0] === '__x') {
      if (parts[1] === 'rows') return reply(res, 200, db[parts[2]] || []);
      if (parts[1] === 'log') {
        if (req.method === 'POST') log = [];
        return reply(res, 200, log);
      }
      if (parts[1] === 'rival') {
        rivals = Number(url.searchParams.get('n') || 0);
        return reply(res, 200, { rivals });
      }
      if (parts[1] === 'lose') {
        lose = { mode: url.searchParams.get('mode') || '', n: Number(url.searchParams.get('n') || 1) };
        return reply(res, 200, lose);
      }
      if (parts[1] === 'delay') {
        delay = { table: parts[2], ms: Number(url.searchParams.get('ms') || 0), n: Number(url.searchParams.get('n') || 1), verb: url.searchParams.get('verb') || 'patch' };
        return reply(res, 200, delay);
      }
      if (parts[1] === 'drop') {
        db[parts[2]] = db[parts[2]].filter((r) => r.id !== parts[3]);
        return reply(res, 200, {});
      }
      if (parts[1] === 'reset') {
        for (const t of Object.keys(db)) db[t] = [];
        log = [];
        rivals = 0;
        lose = { mode: '', n: 0 };
        delay = { table: '', ms: 0, n: 0, verb: 'patch' };
        return reply(res, 200, {});
      }
      return reply(res, 404);
    }
    let body = {};
    try {
      body = raw ? JSON.parse(raw) : {};
    } catch {
      return reply(res, 400, { success: false, errorCode: 'INVALID_JSON' });
    }
    log.push({ method: req.method, path: url.pathname, body });
    const bearer = req.headers.authorization === `Bearer ${token}`;
    const cookie = /(?:^|;\s*)cfw\.auth\.session=([^;]*)/.exec(req.headers.cookie || '')?.[1] === token;
    if (!bearer && !cookie) return reply(res, 401, { success: false, data: null, errorCode: 'API_REQUIRES_SIGN_IN', message: 'requires a signed-in caller' });
    const [api, table, id] = parts;
    if (api !== 'api' || !SCHEMA[table]) return reply(res, 404);
    const verb = { GET: id ? 'get' : 'list', POST: 'create', PATCH: 'patch', DELETE: 'delete' }[req.method];
    if (!verb || !SCHEMA[table].ops.includes(verb)) return reply(res, 404);
    let out;
    if (verb === 'list' && delay.n > 0 && delay.verb === 'list' && delay.table === table) {
      // the read is held before it is answered, so a later call can finish first
      delay.n--;
      return setTimeout(() => {
        const late = list(table, url.searchParams);
        reply(res, late.status, late.body);
      }, delay.ms);
    }
    if (verb === 'list') out = list(table, url.searchParams);
    else if (verb === 'get') {
      const row = db[table].find((r) => r.id === id);
      out = row ? { status: 200, body: { success: true, data: row } } : refusal(404, 'NOT_FOUND', 'not found');
    } else if (verb === 'patch') {
      if (delay.n > 0 && delay.verb === 'patch' && delay.table === table) {
        // the patch is held before it is applied, so a later call can finish first
        delay.n--;
        return setTimeout(() => {
          const late = patch(table, id, body);
          reply(res, late.status, late.body);
        }, delay.ms);
      }
      out = patch(table, id, body);
    }
    else if (verb === 'delete') {
      db[table] = db[table].filter((r) => r.id !== id);
      return reply(res, 204);
    } else {
      if (table === 'fm_task_event' && lose.n > 0 && lose.mode === 'before') {
        lose.n--;
        return reply(res, 503, { success: false, errorCode: 'UNAVAILABLE' });
      }
      if (table === 'fm_task_event' && rivals > 0) {
        rivals--;
        const top = Math.max(0, ...db.fm_task_event.map((r) => r.seq));
        create('fm_task_event', { seq: top + 1, taskId: 'rival', kind: 'comment', actorRole: 'system', actor: 'rival', body: '{}', idempotencyKey: `rival-${crypto.randomUUID()}` });
      }
      out = create(table, body);
      if (table === 'fm_task_event' && lose.n > 0 && lose.mode === 'after') {
        lose.n--;
        return reply(res, 503, { success: false, errorCode: 'UNAVAILABLE' });
      }
    }
    return reply(res, out.status, out.body);
  });
});
server.listen(0, '127.0.0.1', () => fs.writeFileSync(portFile, String(server.address().port)));
const parent = process.ppid;
setInterval(() => {
  try {
    process.kill(parent, 0);
  } catch {
    process.exit(0);
  }
}, 1000).unref();
setTimeout(() => process.exit(0), 20 * 60 * 1000).unref();
