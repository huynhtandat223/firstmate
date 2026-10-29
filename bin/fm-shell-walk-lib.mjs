// Shared walker for the PreToolUse command policies (spec huynhtandat223/firstmate#200).
//
// walkCommands(program, visit, scope) calls visit(position, context, scope) once for
// every executed command node of a shell program: top-level nodes, the
// contents of groups and substitutions, `bash -c` payloads, and the bodies of
// if, while, until and case. The shell tokenizer and command-position
// analysis come from bin/fm-arm-command-policy.mjs, the sole owner of
// firstmate's shell classification. Nothing here evaluates, expands or runs
// any byte of the submitted command; only lexical command positions are read.
//
// scope is a plain object the visitor may write to (a directory it saw `cd`
// into, a variable it saw assigned). Each group, substitution and payload gets
// its own copy, so a `cd` inside a subshell does not leak out of it.
// context is { next, separator }: the command position that follows in the
// same list and the operator after this node, so a visitor can read a pipe.
// A program the classifier cannot tokenize is skipped: these guards target
// agent mistakes, which tokenize.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { basename } from "node:path";

const SHELLS = new Set(["sh", "bash", "zsh"]);
// Shell reserved words that can lead a command node (`then cmd`, `do cmd`, `! cmd`).
const RESERVED = new Set(["if", "then", "else", "elif", "fi", "while", "until", "do", "done", "!", "time"]);

// A node with its leading reserved words removed, so commandPosition sees the
// executed command word rather than `if` or `then`.
function withoutReserved(node) {
  let start = 0;
  while (start < node.length && node[start].type === "word" && !node[start].quoted && RESERVED.has(node[start].value)) start += 1;
  return node.slice(start);
}

// The literal payload of `bash -c '<payload>'` (also -lc, -ec), or null.
function shellPayload(position) {
  if (!position.command || !SHELLS.has(basename(position.command.value))) return null;
  const words = position.words;
  for (let i = position.index + 1; i < words.length; i += 1) {
    if (/^-[A-Za-z]*c[A-Za-z]*$/.test(words[i].value)) {
      const payload = words[i + 1]?.value === "--" ? words[i + 2] : words[i + 1];
      return payload ? payload.value : null;
    }
  }
  return null;
}

// The shared lexer cannot read a case pattern such as `x)`. Rewrite each pattern
// and `;;` into a plain `;` so the commands in the case bodies still classify.
function flattenCase(program) {
  return program
    .replace(/(^|\bin\s|;;\s*|\n)\s*\(?[^\s()|;'"]+(?:\|[^\s()|;'"]+)*\)(?=\s)/g, "$1 ; ")
    .replace(/;;/g, ";");
}

function walkCommands(program, visit, scope = {}) {
  let lexed = new Lexer(program).tokenize();
  if (lexed.error && /\bcase\b[\s\S]*\bin\b/.test(program)) lexed = new Lexer(flattenCase(program)).tokenize();
  if (lexed.error) return;
  const { nodes, separators } = splitProgram(lexed.tokens);
  for (let index = 0; index < nodes.length; index += 1) {
    for (const token of nodes[index]) {
      if (token.type === "group") walkCommands(token.content, visit, { ...scope });
      if (token.type === "word") for (const sub of token.subs) walkCommands(sub.content, visit, { ...scope });
    }
    const position = commandPosition(withoutReserved(nodes[index]));
    const payload = shellPayload(position);
    if (payload !== null) {
      walkCommands(payload, visit, { ...scope });
      continue;
    }
    const next = nodes[index + 1] ? commandPosition(withoutReserved(nodes[index + 1])) : null;
    visit(position, { next, separator: separators[index] }, scope);
  }
}

export { walkCommands };
