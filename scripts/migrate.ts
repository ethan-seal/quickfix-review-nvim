#!/usr/bin/env bun
// Migrate quickfix-review.json: backfill `user_data` (commit + diff snippet)
// onto comments created before commit-aware context capture was added.
//
// Usage: bun run scripts/migrate.ts [path/to/quickfix-review.json]
// Defaults to $XDG_DATA_HOME/nvim/quickfix-review.json (or ~/.local/share/...).
//
// IMPORTANT: captures context using the *current* HEAD and working tree.
// If you've moved off the commit a comment was about, check out that commit
// before running so the captured snippet matches what you originally saw.

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type QfItem = {
  filename?: string;
  lnum: number;
  end_lnum?: number;
  text: string;
  user_data?: unknown;
  [k: string]: unknown;
};

type Hunk = { newStart: number; newCount: number; lines: string[] };

const defaultStorage =
  process.env.XDG_DATA_HOME
    ? join(process.env.XDG_DATA_HOME, "nvim/quickfix-review.json")
    : join(homedir(), ".local/share/nvim/quickfix-review.json");

const storage = process.argv[2] ?? defaultStorage;

if (!existsSync(storage)) {
  console.error(`storage file not found: ${storage}`);
  process.exit(1);
}

function git(args: string[]): { stdout: string; code: number } {
  const r = spawnSync("git", args, { encoding: "utf8" });
  return { stdout: r.stdout ?? "", code: r.status ?? 1 };
}

function parseHunks(diff: string): Hunk[] {
  const hunks: Hunk[] = [];
  let current: Hunk | null = null;
  for (const line of diff.split("\n")) {
    if (line.startsWith("@@")) {
      const m = line.match(/^@@ -\d+,?\d* \+(\d+),?(\d*) @@/);
      if (m) {
        const [, startStr, countStr] = m;
        if (startStr) {
          const newStart = parseInt(startStr, 10);
          const newCount = !countStr ? 1 : parseInt(countStr, 10);
          current = { newStart, newCount, lines: [line] };
          hunks.push(current);
        }
      }
    } else if (current) {
      const c = line[0];
      if (c === "+" || c === "-" || c === " " || c === "\\") {
        current.lines.push(line);
      }
    }
  }
  return hunks;
}

function findHunk(hunks: Hunk[], lnum: number): Hunk | null {
  for (const h of hunks) {
    const last = h.newStart + (h.newCount || 1) - 1;
    if (lnum >= h.newStart && lnum <= last) return h;
  }
  return null;
}

function diffHunk(file: string, lnum: number, base: string): string[] | null {
  const { stdout, code } = git(["diff", "--no-color", "--unified=3", base, "--", file]);
  if (code !== 0 || !stdout) return null;
  const h = findHunk(parseHunks(stdout), lnum);
  return h ? h.lines : null;
}

function fileSnippet(file: string, startLine: number, endLine: number): string[] {
  const pad = 3;
  const from = Math.max(1, startLine - pad);
  const to = endLine + pad;
  let lines: string[];
  try {
    lines = readFileSync(file, "utf8").split("\n");
  } catch {
    return ["<unable to read file>"];
  }
  const snippet: string[] = [];
  for (let i = from; i <= Math.min(to, lines.length); i++) {
    snippet.push(`${String(i).padStart(4, " ")}  ${lines[i - 1] ?? ""}`);
  }
  if (snippet.length === 0) snippet.push("<no content>");
  return snippet;
}

function capture(file: string, startLine: number, endLine: number) {
  const { stdout: shaOut, code } = git(["rev-parse", "HEAD"]);
  const commit = code === 0 ? shaOut.trim() : null;
  const snippet =
    diffHunk(file, startLine, "HEAD~1") ??
    diffHunk(file, startLine, "HEAD") ??
    fileSnippet(file, startLine, endLine);
  return {
    commit,
    commit_short: commit ? commit.slice(0, 8) : null,
    snippet,
  };
}

const items = JSON.parse(readFileSync(storage, "utf8")) as QfItem[];
let migrated = 0;
let skipped = 0;

for (const item of items) {
  if (item.user_data) {
    skipped++;
    continue;
  }
  if (!item.filename) {
    skipped++;
    continue;
  }
  item.user_data = capture(item.filename, item.lnum, item.end_lnum ?? item.lnum);
  migrated++;
}

const backup = `${storage}.bak`;
copyFileSync(storage, backup);
writeFileSync(storage, JSON.stringify(items));
console.log(`migrated ${migrated}, skipped ${skipped}. backup: ${backup}`);
