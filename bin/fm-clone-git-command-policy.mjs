#!/usr/bin/env node
// Semantic policy for the project-clone git guard (spec huynhtandat223/firstmate#200, E10).
//
// AGENTS.md hard rule 1: firstmate reads the clones under <home>/projects/ and
// crewmates change them. This policy finds a git command aimed at such a clone
// that changes it: checkout, switch, reset, commit, stash, rebase, cherry-pick,
// revert, restore, add, rm, mv, am, apply, clean, push, pull, a branch or
// worktree or remote change, a merge without --ff-only, and a fetch of a
// refspec (pull/<n>/head, a:b, refs/..., +x). It allows fetch of a remote or
// of plain branch names, merge --ff-only, and every read (show, log, diff,
// grep, ls-tree, status, rev-parse ...). A clone is named by `git -C <dir>`,
// `--git-dir`, `--work-tree`, or a `cd` earlier in the same subshell.
// The environmental scoping and the log-only switch live in
// bin/fm-clone-git-pretool-check.sh, not here.
//
// The shell tokenizer comes from bin/fm-arm-command-policy.mjs through
// bin/fm-shell-walk-lib.mjs. This policy never evaluates, expands or runs any
// byte of the submitted command.
// Output: "allow", or "deny\t<code>\t<reason>".
//
// Replay: --replay <transcript.jsonl>... [--home <dir>] reads Claude
// transcripts, never writes them, and prints each Bash command the policy
// would deny with its session id and day, then the counts.

import { walkCommands } from "./fm-shell-walk-lib.mjs";
import { createReadStream, readdirSync, realpathSync, statSync } from "node:fs";
import { basename, join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const SAFE_FORMS =
  "To read a PR run gh pr diff <n> --repo <owner/repo>. To change code use git -C <worker worktree>. A clone takes only fetch <remote> [<branch>] and merge --ff-only origin/<default>.";

// A state-changing verb with no allowed form.
const ALWAYS_DENIED = new Set([
  "pull", "checkout", "switch", "reset", "commit", "stash", "rebase", "cherry-pick", "revert",
  "restore", "add", "rm", "mv", "am", "apply", "clean", "push",
]);
const BRANCH_MUTATING = new Set(["-d", "-D", "-m", "-M", "-c", "-C", "-f", "--delete", "--move", "--copy", "--force", "--set-upstream-to", "-u", "--unset-upstream"]);
const BRANCH_LISTING = new Set(["-l", "--list", "-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--show-current"]);
const WORKTREE_MUTATING = new Set(["add", "remove", "move", "prune", "lock", "unlock", "repair"]);
const REMOTE_MUTATING = new Set(["add", "remove", "rm", "rename", "set-url", "set-head", "set-branches"]);
// Global options that take the next word as their value.
const GLOBAL_WITH_VALUE = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"]);

function reason(verb, detail) {
  return `git ${verb} ${detail}. A state-changing git command in a project clone is blocked (AGENTS.md hard rule 1: firstmate reads projects/, crewmates change them). ${SAFE_FORMS}`;
}

function expand(value, scope, userHome) {
  const vars = scope.vars || {};
  let out = value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g, (all, braced, plain) => {
    const name = braced || plain;
    if (name === "HOME" && userHome) return userHome;
    return Object.hasOwn(vars, name) ? vars[name] : all;
  });
  if (out === "~" || out.startsWith("~/")) out = `${userHome}${out.slice(1)}`;
  return out;
}

// Join the next -C value onto the one before it, as git does.
function joinDir(base, next) {
  if (base === "" || next.startsWith("/") || next.startsWith("~")) return next;
  return `${base.replace(/\/+$/, "")}/${next}`;
}

// Does this path name a clone under <home>/projects/? Relative paths are read
// against the home, which the cd-guard keeps as the shell's directory.
function isCloneDir(path, home) {
  if (!path) return false;
  const normalized = path.replace(/\/{2,}/g, "/").replace(/^(\.\/)+/, "");
  const prefix = `${home.replace(/\/+$/, "")}/projects/`;
  let rest;
  if (normalized.startsWith(prefix)) rest = normalized.slice(prefix.length);
  else if (normalized.startsWith("projects/")) rest = normalized.slice("projects/".length);
  else if (normalized.startsWith("$") && normalized.includes("/projects/")) rest = normalized.slice(normalized.indexOf("/projects/") + "/projects/".length);
  else return false;
  return /^[^/\s]/.test(rest);
}

function plainRef(ref) {
  return !(ref.startsWith("+") || ref.startsWith("refs/") || ref.startsWith("pull/") || ref.startsWith("-") || /[:*]/.test(ref));
}

function positionals(args) {
  return args.filter((word) => !word.startsWith("-"));
}

// The verdict for one git invocation's verb and arguments, or null when allowed.
function verdict(verb, args) {
  if (ALWAYS_DENIED.has(verb)) return { code: `git-${verb}`, reason: reason(verb, "changes the clone") };
  if (verb === "fetch") {
    const refs = positionals(args).slice(1);
    const bad = refs.find((ref) => !plainRef(ref));
    if (bad) return { code: "git-fetch-refspec", reason: reason("fetch", `of the refspec ${bad} writes refs into the clone`) };
    return null;
  }
  if (verb === "merge") {
    if (args.includes("--ff-only") && !args.includes("--no-ff") && !args.includes("--squash")) return null;
    return { code: "git-merge", reason: reason("merge", "without --ff-only can create a merge commit") };
  }
  if (verb === "branch") {
    if (args.some((word) => BRANCH_MUTATING.has(word) || word.startsWith("--set-upstream-to="))) return { code: "git-branch", reason: reason("branch", "changes a branch") };
    if (positionals(args).length > 0 && !args.some((word) => BRANCH_LISTING.has(word))) return { code: "git-branch", reason: reason("branch", "creates a branch") };
    return null;
  }
  if (verb === "worktree") {
    const sub = positionals(args)[0];
    if (WORKTREE_MUTATING.has(sub)) return { code: "git-worktree", reason: reason("worktree", `${sub} changes the clone's worktree list`) };
    return null;
  }
  if (verb === "remote") {
    const sub = positionals(args)[0];
    if (REMOTE_MUTATING.has(sub)) return { code: "git-remote", reason: reason("remote", `${sub} changes the clone's remotes`) };
    return null;
  }
  return null;
}

// Parse `git [globals] <verb> <args>` from a command position, or null.
function parseGit(position) {
  if (!position.command || basename(position.command.value) !== "git") return null;
  const words = position.words.slice(position.index + 1).map((word) => word.value);
  const dirs = [];
  let i = 0;
  for (; i < words.length; i += 1) {
    const word = words[i];
    if (!word.startsWith("-")) break;
    if (word === "-C") {
      if (i + 1 < words.length) dirs.push(["C", words[i + 1]]);
      i += 1;
    } else if (GLOBAL_WITH_VALUE.has(word)) {
      if ((word === "--git-dir" || word === "--work-tree") && i + 1 < words.length) dirs.push([word, words[i + 1]]);
      i += 1;
    } else if (word.startsWith("--git-dir=") || word.startsWith("--work-tree=")) {
      dirs.push([word.slice(0, word.indexOf("=")), word.slice(word.indexOf("=") + 1)]);
    } else if (word.startsWith("-C") && word.length > 2) {
      dirs.push(["C", word.slice(2)]);
    }
  }
  if (i >= words.length) return null;
  return { dirs, verb: words[i], args: words.slice(i + 1) };
}

function decision(command, options = {}) {
  const home = options.home || process.env.FM_HOME || process.cwd();
  const userHome = options.userHome || process.env.HOME || "";
  let found = null;
  walkCommands(command, (position, _context, scope) => {
    if (found) return;
    if (!position.command) {
      // A bare `NAME=value` line: remember it so `git -C $NAME` resolves.
      if (position.prefixAssignments > 0 && position.prefixAssignments === position.words.length) {
        scope.vars = { ...(scope.vars || {}) };
        for (const word of position.words) {
          const equals = word.value.indexOf("=");
          scope.vars[word.value.slice(0, equals)] = expand(word.value.slice(equals + 1), scope, userHome);
        }
      }
      return;
    }
    const name = basename(position.command.value);
    if (name === "cd" || name === "pushd") {
      const target = position.words[position.index + 1];
      if (target) scope.cwd = expand(target.value, scope, userHome);
      return;
    }
    const git = parseGit(position);
    if (!git) return;
    let dir = scope.cwd || "";
    let aimed = false;
    for (const [kind, value] of git.dirs) {
      const expanded = expand(value, scope, userHome);
      if (kind === "C") dir = joinDir(dir, expanded);
      else if (isCloneDir(expanded.replace(/\/\.git\/?$/, ""), home)) aimed = true;
    }
    if (!aimed && !isCloneDir(dir, home)) return;
    const result = verdict(git.verb, git.args);
    if (result) found = result;
  });
  return found ? { decision: "deny", ...found } : { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, replay: [], home: "" };
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
    if (name === "--home") {
      if (i + 1 >= argv.length) throw new Error("--home requires a value");
      result.home = argv[i + 1];
      i += 1;
      continue;
    }
    if (name === "--replay") {
      while (i + 1 < argv.length && !argv[i + 1].startsWith("--")) {
        result.replay.push(argv[i + 1]);
        i += 1;
      }
      if (result.replay.length === 0) throw new Error("--replay requires a transcript file or directory");
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function transcriptFiles(paths) {
  const files = [];
  for (const path of paths) {
    if (statSync(path).isDirectory()) {
      for (const entry of readdirSync(path).sort()) if (entry.endsWith(".jsonl")) files.push(join(path, entry));
    } else {
      files.push(path);
    }
  }
  return files;
}

async function replay(paths, home) {
  const denied = new Set();
  const seen = new Set();
  let scanned = 0;
  let hits = 0;
  for (const file of transcriptFiles(paths)) {
    const session = basename(file, ".jsonl");
    const lines = createInterface({ input: createReadStream(file), crlfDelay: Infinity });
    for await (const line of lines) {
      // Cheap prefilter: only a Bash tool_use that names git and projects can deny.
      if (!line.includes('"Bash"') || !line.includes("git") || !line.includes("projects")) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch {
        continue;
      }
      const content = entry?.message?.content;
      if (!Array.isArray(content)) continue;
      for (const part of content) {
        if (part?.type !== "tool_use" || part.name !== "Bash" || typeof part.input?.command !== "string") continue;
        // A transcript can repeat one tool_use across streamed entries.
        if (part.id) {
          if (seen.has(part.id)) continue;
          seen.add(part.id);
        }
        scanned += 1;
        const result = decision(part.input.command, { home });
        if (result.decision !== "deny") continue;
        hits += 1;
        denied.add(session);
        const flat = part.input.command.replace(/\s+/g, " ").slice(0, 240);
        const day = typeof entry.timestamp === "string" ? entry.timestamp.slice(0, 10) : "-";
        process.stdout.write(`deny\t${session}\t${day}\t${result.code}\t${flat}\n`);
      }
    }
  }
  process.stdout.write(`replay: ${scanned} Bash commands naming git and projects scanned, ${hits} denied in ${denied.size} sessions\n`);
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
    if (args.replay.length > 0) {
      await replay(args.replay, args.home || process.env.FM_HOME || process.cwd());
    } else if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command, { home: args.home || undefined });
      if (result.decision === "allow") process.stdout.write("allow\n");
      else process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
