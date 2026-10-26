// Usage: fm-task-backfill.sh [--home HOME] [--source-home HOME]... [--now ISO] [--dry-run]
// Imports open backlog rows and Done rows completed in the last 30 days, then keyed
// source-pointer events. Run only with the runtime grant, or against test-owned probe homes.
import {options, parseBacklog, writer, history} from './fm-task-sources-lib.mjs';
try {
  if (process.argv.includes('--help')) { console.log('Usage: fm-task-backfill.sh [--home HOME] [--source-home HOME]... [--now ISO] [--dry-run]'); process.exit(0); }
  const opts = options(process.argv.slice(2));
  const tasks = parseBacklog(opts.home, opts.now);
  const counts = {};
  for (const t of tasks) counts[t.state] = (counts[t.state] || 0) + 1;
  console.log(Object.entries(counts).sort().map(([k,v]) => `${k}=${v}`).join(' '));
  if (!opts.dry) {
    let added = 0;
    for (const t of tasks) {
      const kind = ['ship', 'scout', 'assistance', 'secondmate', 'plan'].includes(t.kind) ? t.kind : 'other';
      const args = ['import', t.id, '--title', t.title, '--kind', kind, '--state', t.state, '--assignee', t.assignee, '--next-actor', t.nextActor, '--key', `backfill:${t.id}:task`];
      if (t.repo) args.push('--repo', t.repo);
      if (t.blockKind) args.push('--block-kind', t.blockKind, '--block-reason', t.hold || 'Old-source hold');
      if (t.since && Number.isFinite(Date.parse(t.since))) args.push('--since', new Date(t.since).toISOString());
      const out = writer(args);
      if (!/already/.test(out)) added++;
      for (const e of history(opts.home, t, opts.sourceHomes)) {
        const eventArgs = ['event', t.id, e.kind, '--note', e.note, '--key', `backfill:${t.id}:${e.source}:${e.digest}`];
        if (e.url) eventArgs.push('--pr-url', e.url);
        // Check existing keys through the public resume digest is not sufficient;
        // writer replay output is the same receipt, so count additions by sequence.
        const before = writer(['show', t.id, '--json'], {json: true}).lastSeq;
        writer(eventArgs);
        const after = writer(['show', t.id, '--json'], {json: true}).lastSeq;
        if (after !== before) added++;
      }
    }
    console.log(`${added} added`);
  }
} catch (e) { console.error(e.message); process.exitCode = 1; }
