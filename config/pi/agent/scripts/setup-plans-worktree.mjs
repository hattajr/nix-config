#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { cpSync, existsSync, readFileSync, rmSync, statSync } from "node:fs";
import { join } from "node:path";

const PLANS_DIR = "PLANS";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function emitSyntheticPaths(paths) {
  process.stdout.write(`${JSON.stringify({ syntheticPaths: paths })}\n`);
}

function readInput() {
  const raw = readFileSync(0, "utf-8").trim();
  if (!raw) fail("worktree setup hook expected JSON on stdin");

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    fail(`worktree setup hook received invalid JSON: ${message}`);
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    fail("worktree setup hook expected a JSON object on stdin");
  }
  return parsed;
}

function requireDirectoryField(input, field) {
  const value = input[field];
  if (typeof value !== "string" || !value.trim()) {
    fail(`worktree setup hook input field '${field}' must be a non-empty string`);
  }
  const normalized = value.trim();
  const stat = statSync(normalized, { throwIfNoEntry: false });
  if (!stat?.isDirectory()) {
    fail(`worktree setup hook input field '${field}' is not a directory: ${normalized}`);
  }
  return normalized;
}

function runGit(cwd, args) {
  return spawnSync("git", ["-C", cwd, ...args], {
    encoding: "utf-8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function hasTrackedEntries(repoRoot, relativePath) {
  const result = runGit(repoRoot, ["ls-files", "--", relativePath]);
  return result.status === 0 && (result.stdout ?? "").trim().length > 0;
}

function main() {
  const input = readInput();
  const repoRoot = requireDirectoryField(input, "repoRoot");
  const worktreePath = requireDirectoryField(input, "worktreePath");
  const sourcePath = join(repoRoot, PLANS_DIR);

  if (!existsSync(sourcePath)) {
    emitSyntheticPaths([]);
    return;
  }

  const sourceStat = statSync(sourcePath, { throwIfNoEntry: false });
  if (!sourceStat?.isDirectory()) {
    emitSyntheticPaths([]);
    return;
  }

  if (hasTrackedEntries(repoRoot, PLANS_DIR)) {
    emitSyntheticPaths([]);
    return;
  }

  const targetPath = join(worktreePath, PLANS_DIR);
  if (existsSync(targetPath)) {
    rmSync(targetPath, { recursive: true, force: true });
  }
  cpSync(sourcePath, targetPath, { recursive: true });
  emitSyntheticPaths([PLANS_DIR]);
}

try {
  main();
} catch (error) {
  const message = error instanceof Error ? error.message : String(error);
  fail(`worktree setup hook failed: ${message}`);
}
