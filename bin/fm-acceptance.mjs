#!/usr/bin/env node
// The one reader of an issue's acceptance lines. Deploy-verify and briefs read
// issues only through this module; the gate and the board import it.
//
// Usage:
//   fm-acceptance.mjs parse <task-id|board-url|issue-url|-> [--strict]
//   fm-acceptance.mjs rows <task-id|board-url|issue-url|-> [--surface user-visible|all] [--draft] [--strict]
//   fm-acceptance.mjs digest <task-id|board-url|issue-url|-> [--strict]
//
// An <issue-url> is read with `gh issue view <url> --json body` (20 s bound,
// FM_ACCEPTANCE_GH names another gh command); `-` reads the issue body from
// stdin. A read failure is exit 2 with the error on stderr.
//
// parse     Prints {schema: "fm-acceptance.v1", template, sections, scenarios,
//           problems}. Exit 1 when problems is non-empty; the JSON is printed anyway.
// rows      Prints one record row per scenario x width:
//             - <id>@<width> | <line> | pending | evidence: -
//           (<id>@- when widths is `-`). Default surface user-visible; --draft keeps
//           only the scenarios whose page is a draft row, of any surface.
//           It prints nothing and exits 1 when the issue has problems.
//
// digest    Prints one sha256 (hex) of every parsed scenario with all its fields except the
//           checkbox, so the same scenarios give the same digest on every run and an edit to
//           any scenario field moves it; the other sections of the issue do not. It prints
//           nothing and exits 1 when the issue has problems.
//
// Template v1 (heading `## Scenarios`): seven `## ` sections in order, every
// scenario a checklist item with eight fields. Legacy (heading `## Acceptance` or
// `## Acceptance criteria`, field `env/page`): parsed for the issues not yet
// rewritten, read as the old matcher did (an issue with no acceptance section has no
// scenarios; a surface value is read by its word; a checklist item with no id is
// not a scenario); --strict refuses it. Headings and checklist lines inside fenced code
// blocks are ignored, and only `## ` at the start of a line is a section.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

export const SCHEMA = 'fm-acceptance.v1';
export const TEMPLATE_SECTIONS = ['Context', 'Requirements', 'Definition of done', 'Scenarios', 'Mockup', 'Links', 'Decisions'];
const LEGACY_HEADINGS = ['Acceptance', 'Acceptance criteria'];
const TEMPLATE_FIELDS = ['page', 'widths', 'controls', 'env', 'proof', 'data', 'mock', 'surface'];
const LEGACY_FIELDS = ['env/page', 'proof', 'data', 'mock', 'surface'];
const LEGACY_WIDTHS = [1440, 390];
const GH_TIMEOUT_MS = 20000;

const CHECKBOX = /^- \[( |x|X)\] ?(.*)$/;
const ID = /^([A-Z]+[0-9]+)(?=\s|$)\s*(.*)$/;
const FIELD = /^[ \t]+- ([A-Za-z][A-Za-z/]*):[ \t]*(.*)$/;

// Every line as {n, text, fenced}, n counted from 1; a fence line and the lines
// inside a fenced code block are fenced and never a heading or a checklist item.
function bodyLines(body) {
  let fence = null;
  return body.replace(/\r\n?/g, '\n').split('\n').map((text, i) => {
    const m = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(text);
    if (fence) {
      if (m && m[1][0] === fence.char && m[1].length >= fence.length && m[2].trim() === '') fence = null;
      return { n: i + 1, text, fenced: true };
    }
    if (m && !(m[1][0] === '`' && m[2].includes('`'))) {
      fence = { char: m[1][0], length: m[1].length };
      return { n: i + 1, text, fenced: true };
    }
    return { n: i + 1, text, fenced: false };
  });
}

function splitSections(lines) {
  const sections = [];
  for (const line of lines) {
    const m = line.fenced ? null : /^## (.*?)[ \t]*$/.exec(line.text);
    if (m) sections.push({ name: m[1], line: line.n, lines: [] });
    else if (sections.length) sections.at(-1).lines.push(line);
  }
  return sections;
}

// Checklist items of one section: [{n, done, text, fields: [{name, value, n}]}].
function checklist(section) {
  const items = [];
  for (const { n, text, fenced } of section.lines) {
    if (fenced) continue;
    const box = CHECKBOX.exec(text);
    if (box) {
      items.push({ n, done: box[1] !== ' ', text: box[2].trim(), fields: [] });
      continue;
    }
    const item = items.at(-1);
    if (!item || text.trim() === '' || !/^[ \t]/.test(text)) continue;
    const field = FIELD.exec(text);
    if (field) item.fields.push({ name: field[1], value: field[2].trim(), n });
    else if (item.fields.length) item.fields.at(-1).value = `${item.fields.at(-1).value} ${text.trim()}`.trim();
    else item.text = `${item.text} ${text.trim()}`;
  }
  return items;
}

const dash = (value) => (value === undefined || value === '' ? '-' : value);

function parseWidths(value, where, problems) {
  if (value === '-' || value === '') return [];
  const widths = value.split(',').map((w) => w.trim());
  if (widths.some((w) => !/^[0-9]+$/.test(w))) {
    problems.push(`${where}: widths is not a comma-separated list of numbers or -`);
    return [];
  }
  return widths.map(Number);
}

function scenarioFrom(item, template, strict, problems) {
  const idMatch = ID.exec(item.text);
  if (!idMatch) {
    // A legacy section also holds plain checklists with no ids; they were never scenarios.
    if (template === 'v1' || strict) problems.push(`line ${item.n}: checklist item has no id right after the checkbox (an id is capital letters then digits)`);
    return null;
  }
  const id = idMatch[1];
  const where = `${id} (line ${item.n})`;
  const known = template === 'v1' ? TEMPLATE_FIELDS : LEGACY_FIELDS;
  const fields = {};
  for (const f of item.fields) {
    if (!known.includes(f.name)) {
      if (template === 'v1') problems.push(`${where}: unknown field ${f.name}`);
      continue;
    }
    if (f.name in fields) problems.push(`${where}: field ${f.name} given twice`);
    else fields[f.name] = f.value;
  }
  if (template === 'v1') {
    const given = item.fields.map((f) => f.name).filter((name, i, all) => TEMPLATE_FIELDS.includes(name) && all.indexOf(name) === i);
    const ordered = TEMPLATE_FIELDS.filter((name) => given.includes(name));
    if (given.join() !== ordered.join()) problems.push(`${where}: fields are out of order, the template order is ${TEMPLATE_FIELDS.join(', ')}`);
  }
  const required = template === 'v1' ? TEMPLATE_FIELDS : ['surface'];
  const missing = required.filter((name) => !(name in fields) || fields[name] === '');
  if (missing.length) problems.push(`${where}: missing field${missing.length > 1 ? 's' : ''} ${missing.join(', ')}`);
  let surface = fields.surface ?? '';
  // Legacy lines end the value with a full stop or a note, so only the word is read.
  if (template === 'legacy' && surface !== '') surface = /user-visible/.test(surface) ? 'user-visible' : /internal/.test(surface) ? 'internal' : surface;
  if (surface !== '' && surface !== 'user-visible' && surface !== 'internal') {
    problems.push(`${where}: surface is "${surface}", not user-visible or internal`);
  }
  let page;
  let draft;
  let widths;
  let controls = [];
  let env;
  if (template === 'v1') {
    const rawPage = dash(fields.page);
    draft = /\(draft\)/.test(rawPage);
    page = dash(rawPage.replace(/\s*\(draft\)/g, '').trim());
    widths = parseWidths(dash(fields.widths), where, problems);
    controls = dash(fields.controls) === '-' ? [] : fields.controls.split(';').map((c) => c.trim()).filter(Boolean);
    env = dash(fields.env);
    if (surface === 'user-visible' && (page === '-' || widths.length === 0)) {
      problems.push(`${where}: a user-visible scenario needs a page and widths other than -`);
    }
  } else {
    draft = /\(draft\)/.test(fields['env/page'] ?? '');
    page = '-';
    widths = surface === 'user-visible' ? [...LEGACY_WIDTHS] : [];
    env = dash(fields['env/page']);
  }
  return {
    id,
    line: idMatch[2].trim(),
    done: item.done,
    page,
    draft,
    widths,
    controls,
    env,
    proof: dash(fields.proof),
    data: dash(fields.data),
    mock: dash(fields.mock),
    surface: surface || '-',
  };
}

export function parseIssue(body, { strict = false } = {}) {
  const problems = [];
  const sections = splitSections(bodyLines(String(body ?? '')));
  const hasTemplate = sections.some((s) => s.name === 'Scenarios');
  const legacyHeading = sections.find((s) => LEGACY_HEADINGS.includes(s.name));
  const template = hasTemplate ? 'v1' : 'legacy';
  const outSections = {};
  let acceptance;
  if (template === 'v1') {
    let previous = -1;
    for (const name of TEMPLATE_SECTIONS) {
      const found = sections.filter((s) => s.name === name);
      if (found.length === 0) {
        problems.push(`missing section ## ${name}`);
        continue;
      }
      if (found.length > 1) problems.push(`section ## ${name} appears ${found.length} times (lines ${found.map((s) => s.line).join(', ')})`);
      const index = sections.indexOf(found[0]);
      if (index < previous) problems.push(`section ## ${name} is out of order`);
      previous = Math.max(previous, index);
      outSections[name] = { line: found[0].line, body: found[0].lines.map((l) => l.text).join('\n').trim() };
    }
    acceptance = sections.find((s) => s.name === 'Scenarios');
  } else {
    if (strict) problems.push('legacy acceptance section: --strict needs the template (## Scenarios with the eight fields)');
    if (legacyHeading) {
      outSections[legacyHeading.name] = { line: legacyHeading.line, body: legacyHeading.lines.map((l) => l.text).join('\n').trim() };
    } else if (strict) {
      problems.push('no ## Scenarios section');
    }
    acceptance = legacyHeading;
  }
  const scenarios = [];
  if (acceptance) {
    const seen = new Map();
    for (const item of checklist(acceptance)) {
      const scenario = scenarioFrom(item, template, strict, problems);
      if (!scenario) continue;
      if (seen.has(scenario.id)) {
        problems.push(`${scenario.id} (line ${item.n}): duplicate id, first used at line ${seen.get(scenario.id)}`);
        continue;
      }
      seen.set(scenario.id, item.n);
      scenarios.push(scenario);
    }
    if (template === 'v1' && scenarios.length === 0) problems.push('## Scenarios holds no scenario');
  }
  return { schema: SCHEMA, template, sections: outSections, scenarios, problems };
}

export function rows(parsed, { surface = 'user-visible', draft = false } = {}) {
  const out = [];
  for (const s of parsed.scenarios) {
    if (draft && !s.draft) continue;
    if (surface !== 'all' && s.surface !== surface) continue;
    for (const width of s.widths.length ? s.widths : ['-']) {
      out.push(`- ${s.id}@${width} | ${s.line} | pending | evidence: -`);
    }
  }
  return out;
}

export function digest(parsed) {
  const scenarios = parsed.scenarios.map(({ done, ...rest }) => rest);
  return createHash('sha256').update(JSON.stringify(scenarios)).digest('hex');
}

function readIssueBody(source) {
  if (source === '-') return fs.readFileSync(0, 'utf8');
  if (source.startsWith('task:')) source = source.slice(5);
  if (/^https?:\/\//.test(source) && source.includes('task=')) {
    const url = new URL(source);
    source = new URLSearchParams(url.hash.split('?')[1] || url.search).get('task') || source;
  }
  if (!/^https:\/\/[^/]+\/[^/]+\/[^/]+\/issues\/\d+$/.test(source)) {
    const task = process.env.FM_ACCEPTANCE_TASK || new URL('./fm-task.sh', import.meta.url).pathname;
    const run = spawnSync(task, ['document', source], { encoding: 'utf8', timeout: GH_TIMEOUT_MS, maxBuffer: 16 * 1024 * 1024 });
    if (run.error || run.status !== 0) throw new Error(`could not read task ${source}: ${run.error?.message || run.stderr || run.stdout}`);
    return run.stdout;
  }
  const gh = process.env.FM_ACCEPTANCE_GH || 'gh';
  const run = spawnSync(gh, ['issue', 'view', source, '--json', 'body'], { encoding: 'utf8', timeout: GH_TIMEOUT_MS });
  if (run.error) throw new Error(`could not read ${source}: ${run.error.code === 'ETIMEDOUT' ? `no answer in ${GH_TIMEOUT_MS / 1000} s` : run.error.message}`);
  if (run.status !== 0) throw new Error(`could not read ${source}: ${(run.stderr || '').trim() || `gh exited ${run.status}`}`);
  try {
    return JSON.parse(run.stdout).body ?? '';
  } catch {
    throw new Error(`could not read ${source}: gh printed no JSON body`);
  }
}

function main(argv) {
  const [command, source, ...flags] = argv;
  const usage = 'usage: fm-acceptance.mjs parse <task:id|task-id|board-url|issue-url|-> [--strict] | rows <source> [--surface user-visible|all] [--draft] [--strict] | digest <source> [--strict]';
  if (!['parse', 'rows', 'digest'].includes(command) || !source) {
    process.stderr.write(`${usage}\n`);
    return 2;
  }
  let strict = false;
  let draft = false;
  let surface;
  for (let i = 0; i < flags.length; i++) {
    if (flags[i] === '--strict') strict = true;
    else if (flags[i] === '--draft' && command === 'rows') draft = true;
    else if (flags[i] === '--surface' && command === 'rows' && ['user-visible', 'all'].includes(flags[i + 1])) surface = flags[++i];
    else {
      process.stderr.write(`error: unexpected argument ${flags[i]}\n${usage}\n`);
      return 2;
    }
  }
  let parsed;
  try {
    parsed = parseIssue(readIssueBody(source), { strict });
  } catch (error) {
    process.stderr.write(`error: ${error.message}\n`);
    return 2;
  }
  if (command === 'parse') {
    process.stdout.write(`${JSON.stringify(parsed)}\n`);
  } else if (command === 'digest') {
    if (parsed.problems.length === 0) process.stdout.write(`${digest(parsed)}\n`);
  } else if (parsed.problems.length === 0) {
    const list = rows(parsed, { surface: surface ?? (draft ? 'all' : 'user-visible'), draft });
    if (list.length) process.stdout.write(`${list.join('\n')}\n`);
  }
  if (parsed.problems.length) {
    if (command !== 'parse') process.stderr.write(`error: ${source} is refused: ${parsed.problems.join('; ')}\n`);
    return 1;
  }
  return 0;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = main(process.argv.slice(2));
