#!/usr/bin/env node
// Core of the captain reply lint (spec huynhtandat223/firstmate#200, E2).
// bin/fm-reply-lint.sh is the Stop-hook transport; this file reads a Claude
// transcript (JSONL) and decides which captain rules the end of each turn broke.
// It never writes anything. Codes and the fix each one prints:
//   english  no Vietnamese letter and 20+ Latin letters in the reply (captain.md:16)
//   question a `?` in the last 400 characters and no agent-ask call in the turn (captain.md:20)
//   notes    captain notes wait in the inbox directory (--inbox-dir)
//   unread   data/captain.md was not read since the last SessionStart
// Usage:
//   fm-reply-lint.mjs --transcript F [--replay] [--last] [--language vi]
//                     [--inbox-dir D] [--home H] [--last-text T] [--json]
// --replay lists every turn end that would be flagged. --last prints
// "stop<TAB><last turn end uuid><TAB><previous turn end uuid>" and then the
// findings of the final turn end, one "<uuid><TAB><code><TAB><message>" per line.

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { basename, join } from "node:path";
import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

const VIETNAMESE = /[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]/i;
const REACH_LINES = 470;

export function parseTranscript(path) {
  const rows = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      /* a torn last line is skipped */
    }
  }
  return rows;
}

function textOf(message) {
  const content = message?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b.type === "text").map((b) => b.text).join("\n");
}

// A turn end: an assistant entry that ends the turn and carries text.
function isTurnEnd(row) {
  return row.type === "assistant" && row.message?.stop_reason === "end_turn" && textOf(row.message).trim() !== "";
}

function toolUses(row) {
  if (row.type !== "assistant" || !Array.isArray(row.message?.content)) return [];
  return row.message.content.filter((b) => b.type === "tool_use");
}

// The executed commands of a shell line: [{ name, operands }] for every node,
// including groups and $(...) substitutions. A word inside a pattern, an echo or
// a quoted string is an operand, never a command. An unparsable line yields none.
export function shellCommands(line) {
  const found = [];
  const walk = (program) => {
    const lexed = new Lexer(program).tokenize();
    if (lexed.error) return;
    for (const node of splitProgram(lexed.tokens).nodes) {
      for (const token of node) {
        if (token.type === "group") walk(token.content);
        if (token.type === "word") for (const sub of token.subs) walk(sub.content);
      }
      const position = commandPosition(node);
      if (position.command) {
        found.push({ name: basename(position.command.value), operands: position.words.slice(position.index + 1).map((w) => w.value) });
      }
    }
  };
  walk(line);
  return found;
}

function commandOf(use) {
  return String(use.input?.command ?? use.input?.file_path ?? use.input?.path ?? "");
}

function hookContent(row) {
  const a = row.attachment;
  if (row.type !== "attachment" || !a || a.hookEvent !== "SessionStart") return null;
  return String(a.stdout ?? a.content ?? "");
}

// Did a digest print data/captain.md where a session reads it? The heading line
// must sit inside the first lines a Read shows, and the digest must not have
// spilled to a file that was never opened.
function digestHoldsCaptain(text) {
  const lines = text.split("\n");
  const at = lines.findIndex((l, i) => l === "data/captain.md" && /^-{20,}$/.test(lines[i + 1] ?? ""));
  return at !== -1 && at < REACH_LINES;
}

// The harness replaces an oversize hook output with a <persisted-output> notice
// and a 2KB preview. The words "Output too large" also sit inside the digest's
// own RE-EMIT CUE, so only the wrapper tag marks a real spill.
function isSpillNotice(text) {
  return text.trimStart().startsWith("<persisted-output>");
}

function readsCaptain(use) {
  const target = commandOf(use);
  if (use.name === "Read") return /(^|\/)data\/captain\.md$/.test(target);
  if (use.name !== "Bash") return false;
  const SEARCH = new Set(["grep", "rg", "sed", "awk"]);
  const READERS = new Set(["cat", "head", "tail", "less", "more", "bat", "nl", "view", ...SEARCH]);
  return shellCommands(target).some((c) => {
    if (!READERS.has(c.name)) return false;
    const operands = c.operands.filter((o) => !o.startsWith("-"));
    // The first operand of a search or edit command is its pattern or script.
    const files = SEARCH.has(c.name) ? operands.slice(1) : operands;
    return files.some((f) => /(^|\/)data\/captain\.md$/.test(f));
  });
}

function callsAgentAsk(use) {
  return use.name === "Bash" && shellCommands(commandOf(use)).some((c) => c.name === "agent-ask");
}

export function findStops(rows, options = {}) {
  const language = options.language ?? "vi";
  const stops = [];
  let turnTools = [];
  let sessionStartIdx = -1;
  let sessionStartInReach = false;
  let readSince = false;
  const evaluate = (text) => {
    const codes = [];
    const latin = (text.match(/[A-Za-z]/g) ?? []).length;
    if (language === "vi" && !VIETNAMESE.test(text) && latin >= 20) codes.push("english");
    if (text.slice(-400).includes("?") && !turnTools.some(callsAgentAsk)) codes.push("question");
    if (sessionStartIdx !== -1 && !readSince && !sessionStartInReach) codes.push("unread");
    return codes;
  };
  rows.forEach((row, index) => {
    const digest = hookContent(row);
    if (digest !== null) {
      sessionStartIdx = index;
      sessionStartInReach = digestHoldsCaptain(digest) && !isSpillNotice(digest);
      readSince = false;
    }
    for (const use of toolUses(row)) {
      turnTools.push(use);
      if (readsCaptain(use)) readSince = true;
    }
    if (!isTurnEnd(row)) return;
    const text = textOf(row.message).trim();
    stops.push({ index, uuid: row.uuid, timestamp: row.timestamp, text, codes: evaluate(text) });
    turnTools = [];
  });
  // The transcript can lag the hook payload: a final reply it does not hold yet
  // is judged from the payload text, with the tools used since the last turn end.
  const extra = (options.extraText ?? "").trim();
  if (extra && stops.at(-1)?.text !== extra) {
    stops.push({ index: rows.length, uuid: `payload:${extra.length}`, timestamp: "", text: extra, codes: evaluate(extra) });
  }
  return stops;
}

const MESSAGES = {
  english: "captain.md:16: resend in Vietnamese, technical terms stay English",
  question: "captain.md:20: post it with agent-ask (FM_TASK_ID, AGENT_ASK_ASKER=firstmate); chat carries its id",
  unread: (handoff) =>
    `data/captain.md was not read since the last SessionStart: read data/captain.md${handoff ? ` and the handoff it names (${handoff})` : " and the handoff its Start here line names"} before replying`,
};

export function noteIds(inboxDir) {
  if (!inboxDir || !existsSync(inboxDir)) return [];
  return readdirSync(inboxDir).filter((f) => f.endsWith(".note")).map((f) => f.slice(0, -5)).sort();
}

export function handoffOf(home) {
  if (!home) return "";
  const file = join(home, "data", "captain.md");
  if (!existsSync(file)) return "";
  const line = readFileSync(file, "utf8").split("\n").find((l) => l.includes("Start here"));
  return line?.match(/`([^`]+)`/)?.[1] ?? "";
}

export function messagesFor(stop, { notes = [], home = "" } = {}) {
  const out = [];
  for (const code of stop.codes) {
    out.push([code, typeof MESSAGES[code] === "function" ? MESSAGES[code](handoffOf(home)) : MESSAGES[code]]);
  }
  if (notes.length > 0) {
    out.push(["notes", `${notes.length} captain note${notes.length === 1 ? "" : "s"} wait: handle them first (${notes.join(", ")}); then fm-inbox.sh drain --ack <id>`]);
  }
  return out;
}

function parseArguments(argv) {
  const args = { replay: false, last: false, json: false, language: "vi" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      i += 1;
      return argv[i];
    };
    if (name === "--transcript") args.transcript = value();
    else if (name === "--replay") args.replay = true;
    else if (name === "--last") args.last = true;
    else if (name === "--json") args.json = true;
    else if (name === "--language") args.language = value();
    else if (name === "--inbox-dir") args.inboxDir = value();
    else if (name === "--home") args.home = value();
    else if (name === "--last-text") args.lastText = value();
    else throw new Error(`unknown argument: ${name}`);
  }
  if (!args.transcript) throw new Error("--transcript is required");
  return args;
}

process.stdout.on("error", () => process.exit(0));

function main() {
  const args = parseArguments(process.argv.slice(2));
  const stops = findStops(parseTranscript(args.transcript), { language: args.language, extraText: args.lastText });
  if (args.last) {
    const stop = stops.at(-1);
    if (!stop) return;
    process.stdout.write(`stop\t${stop.uuid}\t${stops.at(-2)?.uuid ?? ""}\n`);
    for (const [code, message] of messagesFor(stop, { notes: noteIds(args.inboxDir), home: args.home })) {
      process.stdout.write(`${stop.uuid}\t${code}\t${message}\n`);
    }
    return;
  }
  let flagged = 0;
  stops.forEach((stop, n) => {
    if (stop.codes.length === 0) return;
    flagged += 1;
    const excerpt = stop.text.replace(/\s+/g, " ").slice(0, 90);
    if (args.json) process.stdout.write(`${JSON.stringify({ turn: n + 1, uuid: stop.uuid, timestamp: stop.timestamp, codes: stop.codes, text: stop.text })}\n`);
    else process.stdout.write(`turn ${n + 1}\t${stop.timestamp ?? ""}\t${stop.codes.join(",")}\t${excerpt}\n`);
  });
  if (!args.json) process.stdout.write(`# ${stops.length} turn ends, ${flagged} flagged\n`);
}

import { fileURLToPath } from "node:url";
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
