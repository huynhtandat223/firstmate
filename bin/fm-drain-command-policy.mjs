#!/usr/bin/env node
// Semantic policy for the drain-and-ack guard: does one shell command run
// bin/fm-wake-drain.sh --ack-through together with another drain?
//
// The wake drain prints rows firstmate must read; the ack printed after them
// (WAKE_ACK_REQUIRED) is what consumes them. Chaining the two in one command
// acks rows the same command only just printed, so nothing was read between
// them. This policy denies exactly that, and logs a plain drain whose output is
// cut by grep, head, cut or sed, because a filtered drain hides rows. Reading
// the script's source (grep, cat, bash -n) is never matched: only an executed
// command word counts. The environmental scoping and the log-only switch live
// in bin/fm-drain-pretool-check.sh, not here.
//
// The shell tokenizer and command-position analysis come from
// bin/fm-arm-command-policy.mjs, as bin/fm-cd-command-policy.mjs does. This
// policy never evaluates, expands or runs any byte of the submitted command.
// Output: "allow", or "<deny|log>\t<code>\t<reason>".

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const REASONS = {
  "chained-ack":
    "run the drain alone, read every row, then run WAKE_ACK_REQUIRED exactly as printed. One command that acks and also runs a drain acknowledges rows nobody read.",
  "filtered-drain":
    "a drain piped into grep, head, cut or sed shows only part of the rows. Run bin/fm-wake-drain.sh alone and read every row it prints.",
};

const DRAIN = "fm-wake-drain.sh";
const SHELLS = new Set(["sh", "bash", "zsh"]);
const FILTERS = new Set(["grep", "head", "cut", "sed"]);

function isPipe(separator) {
  return separator === "|" || separator === "|&";
}

// The script argument of `bash [options] script args`, or null.
function shellScript(position) {
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "-n") return null;
    if (value.startsWith("-")) continue;
    return value;
  }
  return null;
}

function drainExecution(position) {
  if (!position.command) return null;
  const name = basename(position.command.value);
  let script = null;
  let first = position.index;
  if (name === DRAIN) {
    script = position.command.value;
  } else if (SHELLS.has(name)) {
    script = shellScript(position);
    first = position.words.findIndex((word) => word.value === script);
  }
  if (script === null || basename(script) !== DRAIN) return null;
  const ack = position.words.slice(first + 1).some((word) => word.value === "--ack-through");
  return { ack };
}

function collect(program, found) {
  const lexed = new Lexer(program).tokenize();
  // Fail open on syntax this classifier cannot tokenize: the guard's threat
  // model is agent mistakes, which tokenize.
  if (lexed.error) return;
  const { nodes, separators } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    for (const token of nodes[index]) {
      if (token.type === "group") collect(token.content, found);
      if (token.type === "word") for (const sub of token.subs) collect(sub.content, found);
    }
    const execution = drainExecution(commandPosition(nodes[index]));
    if (!execution) continue;
    let filter = "";
    if (isPipe(separators[index]) && nodes[index + 1]) {
      const next = commandPosition(nodes[index + 1]).command;
      if (next && FILTERS.has(basename(next.value))) filter = basename(next.value);
    }
    found.push({ ...execution, filter });
  }
}

function decision(command) {
  const found = [];
  collect(command, found);
  if (found.some((execution) => execution.ack) && found.length >= 2) {
    return { decision: "deny", code: "chained-ack", reason: REASONS["chained-ack"] };
  }
  if (found.some((execution) => !execution.ack && execution.filter)) {
    return { decision: "log", code: "filtered-drain", reason: REASONS["filtered-drain"] };
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`${result.decision}\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
