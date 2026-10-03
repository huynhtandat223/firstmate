#!/usr/bin/env node
// Worker turn-end context notification. Usage:
//   fm-context-handoff.mjs <status-file> <session-generation> <threshold> <used> <window>
//   fm-context-handoff.mjs <status-file> <session-generation> <threshold> claude <model>
// Claude mode reads Stop-hook JSON on stdin, then the last transcript usage.
// Window source: https://platform.claude.com/docs/en/about-claude/models/overview
// [1m] explicitly selects 1M; Opus 5 and current 5.x models have 1M;
// older models and Haiku 4.5 have 200K. Unknown models refuse measurement.
import fs from 'node:fs';
const [status, generation, thresholdText, mode, windowOrModel] = process.argv.slice(2);
const threshold = Number(thresholdText || 40);
let used = Number(mode), window = Number(windowOrModel);
if (mode === 'claude') {
  const hook = JSON.parse(fs.readFileSync(0, 'utf8'));
  let message, newestUsage;
  // Claude's Stop event can precede its asynchronous transcript flush.
  for (let attempt = 0; attempt < 20; attempt++) {
    const entries = fs.readFileSync(hook.transcript_path, 'utf8').trim().split('\n');
    let attemptNewestUsage;
    for (const line of entries.reverse()) {
      try {
        const entry = JSON.parse(line);
        if (entry.message?.usage) {
          attemptNewestUsage ??= entry.message;
          const text = entry.message.content?.filter(part => part.type === 'text').map(part => part.text).join('') || '';
          if (hook.last_assistant_message && text !== hook.last_assistant_message) continue;
          message = entry.message; break;
        }
      } catch { /* A partial transcript line is not a measurement. */ }
    }
    newestUsage = attemptNewestUsage || newestUsage;
    if (message) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  message ??= newestUsage;
  if (!message) process.exit(0);
  // Aliases vary by provider: use the actual transcript model, preserving [1m].
  const model = windowOrModel.includes('[1m]') ? windowOrModel : (message.model || windowOrModel);
  if (!model) process.exit(0);
  if (model.includes('[1m]') || /^claude-(?!.*200k)(opus-5|(?:opus|sonnet)-5[.-]|fable-5)/.test(model)) window = 1000000;
  else if (/^(?:claude-)?(?:opus|sonnet|haiku)(?:-|$)/.test(model)) window = 200000;
  else process.exit(0);
  const usage = message.usage;
  used = (usage.input_tokens || 0) + (usage.cache_read_input_tokens || 0) + (usage.cache_creation_input_tokens || 0);
}
if (!Number.isFinite(threshold) || threshold < 0 || threshold > 100 || !Number.isFinite(used) || used <= 0 || !Number.isFinite(window) || window <= 0) process.exit(0);
const percent = used * 100 / window;
if (percent < threshold) process.exit(0);
// The spawn busy generation survives extension reloads but changes on relaunch.
const marker = `${status}.handoff-session`;
if (fs.existsSync(marker)) {
  if (fs.readFileSync(marker, 'utf8') === generation) process.exit(0);
  fs.unlinkSync(marker);
}
try { fs.writeFileSync(marker, generation, {flag: 'wx', mode: 0o600}); }
catch (error) { if (error.code === 'EEXIST') process.exit(0); throw error; }
const history = fs.existsSync(status) ? fs.readFileSync(status, 'utf8') : '';
const count = history.split('\n').filter(line => /^handoff-needed(?:\s|:)/.test(line)).length;
const pct = Math.floor(percent);
const at = Math.floor(Date.now() / 1000);
const line = count >= 3
  ? `blocked [key=handoff-limit] [at=${at}]: 3 handoffs done; context ${pct}%; firstmate to judge quality`
  : `handoff-needed [at=${at}]: context ${pct}% (${used}/${window})`;
try { fs.appendFileSync(status, `${line}\n`); process.stdout.write(`${line}\n`); }
catch (error) { fs.unlinkSync(marker); throw error; }
