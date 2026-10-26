// Usage: fm-task-reconcile.sh once|loop [SECONDS=300] [--home HOME] [--now ISO]
// Writes only idempotent divergence events. Missing task records are listed in the
// summary because there is no task to attach an event to. No task is imported here.
import {options, parseBacklog, writer, hash, table} from './fm-task-sources-lib.mjs';
const argv = process.argv.slice(2);
if (argv.includes('--help')) { console.log('Usage: fm-task-reconcile.sh once|loop [SECONDS=300] [--home HOME] [--now ISO]'); process.exit(0); }
const mode = argv.shift();
const every = mode === 'loop' && /^\d+$/.test(argv[0] || '') ? Number(argv.shift()) : 300;
async function run(opts) {
  const records = new Map(writer(['list', '--json'], {json: true}).map(r => [r.taskId, r]));
  const checks = await table('fm_task_check');
  const owners = await table('fm_owner_check');
  let added = 0;
  const missing = [];
  for (const t of parseBacklog(opts.home, opts.now)) {
    const row = records.get(t.id);
    if (!row) { missing.push(t.id); continue; }
    const comparisons = ['state', 'nextActor', 'blockKind', 'assignee', 'kind'].map(field => ({field, oldSource: field === 'blockKind' && !t.holdKind ? null : t[field] ?? null, record: field === 'blockKind' && !t.holdKind ? null : row[field] ?? null}));
    for (const c of checks.filter(c => c.taskId === t.id && c.nextActor === 'owner' && c.status !== 'retired')) {
      if (!owners.some(o => o.taskId === t.id && o.scenarioId === c.scenarioId && o.width === c.width)) comparisons.push({field: `ownerItem:${c.scenarioId}@${c.width}`, oldSource: 'required', record: 'missing'});
    }
    for (const comparison of comparisons) {
      const {field} = comparison;
      if (comparison.oldSource === comparison.record) continue;
      const note = JSON.stringify(comparison);
      const before = writer(['show', t.id, '--json'], {json: true}).lastSeq;
      writer(['event', t.id, 'divergence', '--note', note, '--key', `reconcile:${t.id}:${field}:${hash(note)}`]);
      const after = writer(['show', t.id, '--json'], {json: true}).lastSeq;
      if (before !== after) added++;
    }
  }
  console.log(JSON.stringify({added, missing}));
}
try {
  if (!['once', 'loop'].includes(mode) || every < 1) throw new Error('expected once or loop with a positive interval');
  const opts = options(argv);
  do { await run(opts); if (mode === 'loop') await new Promise(r => setTimeout(r, every * 1000)); } while (mode === 'loop');
} catch (e) { console.error(e.message); process.exitCode = 1; }
