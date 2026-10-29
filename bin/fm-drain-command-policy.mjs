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
// Shell reserved words that can lead a command node (`then cmd`, `do cmd`, `! cmd`).
const RESERVED = new Set(["if", "then", "else", "elif", "fi", "while", "until", "do", "done", "!", "time"]);
// flattenCase() turns each case pattern into this word, so a case arm still starts a new path.
const ARM = "__fm_case_arm__";
// Each if or case group gets a number no other group shares, across nested payloads too.
let groupCount = 0;

// The leading control words of a node (`then`, `else if`, `case`), so
// commandPosition sees the executed command word rather than `if` or `then`.
function leadingWords(node) {
  const words = [];
  while (words.length < node.length && node[words.length].type === "word" && !node[words.length].quoted) {
    const value = node[words.length].value;
    if (!RESERVED.has(value) && value !== "case" && value !== "esac" && value !== ARM) break;
    words.push(value);
  }
  return words;
}

function withoutReserved(node) {
  return node.slice(leadingWords(node).length);
}

// The exclusive-path bookkeeping: an `if` or `case` group is on the stack with
// the branch the walk is in. A branch is null while the walk is in the first
// condition, so commands there share every path. An elif condition is `cond`:
// it runs whenever the earlier bodies did not, so it shares the path of every
// later branch.
function enterControl(stack, word) {
  const top = stack[stack.length - 1];
  if (word === "if" || word === "case") stack.push({ id: (groupCount += 1), kind: word, branch: null, cond: false });
  else if (word === "then" && top?.kind === "if" && top.branch === null) top.branch = 0;
  else if (word === "then" && top?.kind === "if") top.cond = false;
  else if (word === "elif" && top?.kind === "if") {
    top.branch += 1;
    top.cond = true;
  } else if (word === "else" && top?.kind === "if") {
    top.branch += 1;
    top.cond = false;
  }
  else if (word === ARM && top?.kind === "case") top.branch = top.branch === null ? 0 : top.branch + 1;
  else if ((word === "fi" && top?.kind === "if") || (word === "esac" && top?.kind === "case")) stack.pop();
}

// Two executions are exclusive when some group puts them in different bodies,
// or puts a body before an elif condition: that condition runs only after the
// earlier bodies were skipped. Two elif conditions of one group share a path.
function exclusive(a, b) {
  const apart = ([x, xCond], [y, yCond]) => {
    if (xCond && yCond) return false;
    if (xCond) return y < x;
    if (yCond) return x < y;
    return x !== y;
  };
  return a.path.some(([id, ...x]) => b.path.some(([otherId, ...y]) => id === otherId && apart(x, y)));
}

// The literal payload of `bash -c '<payload>'` (also -lc, -ec), or null.
function shellPayload(position) {
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(words[i].value)) {
      const payload = words[i + 1]?.value === "--" ? words[i + 2] : words[i + 1];
      return payload ? payload.value : null;
    }
  }
  return null;
}

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

// True for `bash -n`, `bash -nc` and `bash -o noexec`: the shell only parses.
function noExecShell(position) {
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "--" || !value.startsWith("-")) return false;
    if (value === "-o" || value === "-O") {
      if (value === "-o" && words[i + 1]?.value === "noexec") return true;
      i += 1;
    } else if (/^-[A-Za-z]*n[A-Za-z]*$/.test(value)) {
      return true;
    }
  }
  return false;
}

function drainExecution(position, found, path) {
  if (!position.command) return null;
  const name = basename(position.command.value);
  let script = null;
  let first = position.index;
  if (name === DRAIN) {
    script = position.command.value;
  } else if (SHELLS.has(name)) {
    if (noExecShell(position)) return null;
    const payload = shellPayload(position);
    if (payload !== null) {
      collect(payload, found, path);
      return null;
    }
    script = shellScript(position);
    first = position.words.findIndex((word) => word.value === script);
  }
  if (script === null || basename(script) !== DRAIN) return null;
  const ack = position.words.slice(first + 1).some((word) => word.value === "--ack-through");
  return { ack };
}

// The shared lexer cannot read a case pattern such as `x)`. Rewrite each pattern
// and `;;` into a plain `;` so the commands in the case bodies still classify.
function flattenCase(program) {
  return program
    .replace(/(^|\bin\s|;;\s*|\n)\s*\(?[^\s()|;'"]+(?:\|[^\s()|;'"]+)*\)(?=\s)/g, `$1 ; ${ARM} ;`)
    .replace(/;;/g, ";");
}

function collect(program, found, parentPath = []) {
  let lexed = new Lexer(program).tokenize();
  if (lexed.error && /\bcase\b[\s\S]*\bin\b/.test(program)) lexed = new Lexer(flattenCase(program)).tokenize();
  // Fail open on syntax this classifier cannot tokenize: the guard's threat
  // model is agent mistakes, which tokenize.
  if (lexed.error) return;
  const { nodes, separators } = splitProgram(lexed.tokens);
  const stack = [];
  for (let index = 0; index < nodes.length; index += 1) {
    for (const word of leadingWords(nodes[index])) enterControl(stack, word);
    const path = [...parentPath, ...stack.filter((group) => group.branch !== null).map((group) => [group.id, group.branch, group.cond])];
    for (const token of nodes[index]) {
      if (token.type === "group") collect(token.content, found, path);
      if (token.type === "word") for (const sub of token.subs) collect(sub.content, found, path);
    }
    const execution = drainExecution(commandPosition(withoutReserved(nodes[index])), found, path);
    if (!execution) continue;
    let filter = "";
    if (isPipe(separators[index]) && nodes[index + 1]) {
      const next = commandPosition(withoutReserved(nodes[index + 1])).command;
      if (next && FILTERS.has(basename(next.value))) filter = basename(next.value);
    }
    found.push({ ...execution, filter, path });
  }
}

function decision(command) {
  const found = [];
  collect(command, found);
  const chained = found.some((execution, i) => execution.ack && found.some((other, j) => i !== j && !exclusive(execution, other)));
  if (chained) {
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
