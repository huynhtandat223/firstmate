#!/usr/bin/env node
// Semantic policy for the browser kill guard (spec huynhtandat223/firstmate#200, E4b).
//
// Firstmate once killed chrome-devtools processes by pid or by age and closed
// the captain's 9222 and 9333 Chromes and the Tester's browser mid-round. This
// policy finds a kill, pkill or killall (also `xargs kill`, `fuser -k`) aimed at
// a browser: a pattern naming chrome, chromium or chrome-devtools, a pid in the
// list the transport resolved as a browser, or a watched debugging port named in
// the command, its substitutions, the pipeline feeding it, or a variable a
// bare assignment set from such a lookup. A bare number is a pid, so `kill 9222`
// and signal 0 (`kill -0 <pid>`) are not matched. A browser session
// closes by its name instead: CHROME_DEVTOOLS_AXI_SESSION=<name>
// chrome-devtools-axi stop. A heredoc, echo or grep that only mentions
// `pkill chrome` is not a command position and is never matched. The
// environmental scoping, the pid lookup and the log-only switch live in
// bin/fm-browser-kill-pretool-check.sh, not here.
//
// The shell tokenizer comes from bin/fm-arm-command-policy.mjs through
// bin/fm-shell-walk-lib.mjs. This policy never evaluates, expands or runs any
// byte of the submitted command.
// Usage: --command <cmd> [--ports 9222,9333,...] [--pids 12,34]
// Output: "allow", or "deny\t<code>\t<reason>".

import { walkCommands } from "./fm-shell-walk-lib.mjs";
import { realpathSync } from "node:fs";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";

const SAFE_FORM =
  "Close a browser session by its name: CHROME_DEVTOOLS_AXI_SESSION=<name> chrome-devtools-axi stop, and only for a session whose owner task is done. The 9222 and 9333 Chromes and the Tester's browser belong to people.";

const REASONS = {
  "kill-browser-name": `a kill aimed at a browser by name is blocked. ${SAFE_FORM}`,
  "kill-browser-pid": `a kill of a pid that runs or serves a browser is blocked. ${SAFE_FORM}`,
  "kill-browser-port": `a kill aimed at a browser debugging port is blocked. ${SAFE_FORM}`,
};

const BROWSER_NAME = /chrome|chromium/i;
const KILLERS = new Set(["kill", "pkill", "killall"]);
const DEFAULT_PORTS = [9222, 9333];

// A word's own text plus the text of every substitution inside it.
function wordText(word) {
  return [word.value, ...(word.subs || []).map((sub) => sub.content)].join(" ");
}

function mentionsPort(text, ports) {
  return ports.some((port) => new RegExp(`(^|[^0-9])${port}([^0-9]|$)`).test(text));
}

// A bare number is a pid even when it equals a watched port (kill 9222), so only
// a word that is more than digits, or a substitution, can be a port lookup.
function portLookupText(words) {
  return words.map((word) => [/^\d+$/.test(word.value) ? "" : word.value, ...(word.subs || []).map((sub) => sub.content)].join(" ")).join(" ");
}

// Signal 0 only tests that a process exists.
function isSignalZero(args) {
  return args.some((word, i) => word.value === "-0" || ((word.value === "-s" || word.value === "-n" || word.value === "--signal") && args[i + 1]?.value === "0") || word.value === "--signal=0");
}

function referencesVariable(word, name) {
  return new RegExp(`\\$(\\{${name}[^}]*\\}|${name}(?![A-Za-z0-9_]))`).test(word.value);
}

// The verdict for one kill-like invocation: the words it kills with, and the
// text of the stages that feed it through a pipe (xargs kill).
function killVerdict(args, fed, ports, pids, tainted = {}) {
  if (isSignalZero(args)) return null;
  const argText = args.map(wordText).join(" ");
  if (mentionsPort(portLookupText(args), ports) || mentionsPort(fed, ports)) return "kill-browser-port";
  if (BROWSER_NAME.test(argText) || BROWSER_NAME.test(fed)) return "kill-browser-name";
  for (const [name, code] of Object.entries(tainted)) if (args.some((word) => referencesVariable(word, name))) return code;
  if (args.some((word) => /^\d+$/.test(word.value) && pids.has(Number(word.value)))) return "kill-browser-pid";
  return null;
}

function decision(command, options = {}) {
  const ports = [...new Set([...DEFAULT_PORTS, ...(options.ports || [])])];
  const pids = new Set(options.pids || []);
  let code = null;
  walkCommands(command, (position, context, scope) => {
    if (code) return;
    if (!position.command) {
      // A bare `NAME=value` line: a value that came from a watched-port or browser
      // lookup taints NAME, so a later `kill "$NAME"` is judged as that lookup.
      if (position.prefixAssignments > 0 && position.prefixAssignments === position.words.length) {
        scope.tainted = { ...(scope.tainted || {}) };
        for (const word of position.words) {
          const equals = word.value.indexOf("=");
          const name = word.value.slice(0, equals);
          const value = { value: word.value.slice(equals + 1), subs: word.subs };
          const inherited = Object.entries(scope.tainted).find(([other]) => referencesVariable(value, other));
          if (mentionsPort(portLookupText([value]), ports)) scope.tainted[name] = "kill-browser-port";
          else if (BROWSER_NAME.test(wordText(value))) scope.tainted[name] = "kill-browser-name";
          else if (inherited) scope.tainted[name] = inherited[1];
          else delete scope.tainted[name];
        }
      }
      return;
    }
    const name = basename(position.command.value);
    const rest = position.words.slice(position.index + 1);
    const fed = (context.pipeline || []).flatMap((stage) => stage.words.map(wordText)).join(" ");
    if (KILLERS.has(name)) {
      code = killVerdict(rest, "", ports, pids, scope.tainted);
    } else if (name === "xargs") {
      const at = rest.findIndex((word) => KILLERS.has(basename(word.value)));
      if (at !== -1) code = killVerdict(rest.slice(at + 1), fed, ports, pids, scope.tainted);
    } else if (name === "fuser" && rest.some((word) => /^-[A-Za-z]*k/.test(word.value))) {
      const argText = rest.map(wordText).join(" ");
      if (mentionsPort(argText, ports)) code = "kill-browser-port";
    }
  });
  return code ? { decision: "deny", code, reason: REASONS[code] } : { decision: "allow" };
}

function numberList(text, name) {
  const items = text.split(",").filter(Boolean).map(Number);
  if (items.some((item) => !Number.isInteger(item) || item <= 0)) throw new Error(`${name} must be a comma list of positive integers`);
  return items;
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, ports: [], pids: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const value = (flag) => {
      if (i + 1 >= argv.length) throw new Error(`${flag} requires a value`);
      i += 1;
      return argv[i];
    };
    if (name === "--command") {
      result.command = value(name);
      result.commandSet = true;
    } else if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
    } else if (name === "--ports") {
      result.ports = numberList(value(name), "--ports");
    } else if (name === "--pids") {
      result.pids = numberList(value(name), "--pids");
    } else {
      throw new Error(`unknown argument: ${name}`);
    }
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
      const result = decision(args.command, { ports: args.ports, pids: args.pids });
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
