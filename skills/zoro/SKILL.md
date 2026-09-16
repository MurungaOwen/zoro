---
name: zoro
description: Use when starting a new or existing project and you want Claude Code to plan/review while Codex CLI and/or OpenCode CLI implement, with the ability for any of those backends to resume a task if another one runs out of context — sets up AGENTS.md, CLAUDE.md, .claude/settings.json, a worker subagent, and a file-based .agent-runs/ handoff protocol.
---

# zoro

## Overview
Scaffolds a plan -> implement -> review loop into any repo: Claude Code writes
plans and checks diffs, Codex CLI and/or OpenCode CLI do the actual
implementation as non-interactive subprocesses. Every fact about a task's
progress is written to `.agent-runs/<task-id>/` as plain files, never kept
only in a chat session — so if Claude runs out of context mid-task, a fresh
Claude session, `codex exec`, or `opencode run` can pick the same task up
cold and continue, with no shared memory required.

## When to use
- User asks to set up "the harness", "multi-agent setup", "codex+claude loop",
  or similar in a project.
- Starting a new repo where implementation work should be delegated to
  Codex/OpenCode while Claude Code plans and reviews.
- An existing project needs the harness layered in without disturbing what's
  already there.
- A long task is at risk of exceeding one backend's context window and needs
  to be resumable by a different tool.

Don't use for a one-off task with no ongoing delegation need — just do the
task directly.

## Steps
1. **Check backends.** Run `codex --version` and `opencode --version`
   (whichever exist). At least one must be installed — if neither responds,
   tell the user and stop. This only confirms the binary runs, not that it's
   authenticated; say so.
2. **Inspect the target repo.** Find real build/test commands (package.json
   scripts, Makefile, Cargo.toml, pyproject.toml, etc.) and note actual code
   conventions. If the repo is empty or unfamiliar, say so in AGENTS.md
   instead of inventing commands.
3. **Copy the four templates** from `templates/` in this skill directory into
   the target repo, filling in the placeholders:
   - `templates/AGENTS.md` → `<repo>/AGENTS.md` — this is the cross-backend
     file; Codex and OpenCode both read it automatically, so the resumability
     protocol (`.agent-runs/<task-id>/state.md`, `plan.md`, `report-N.md`,
     `feedback-N.md`) lives here, not just in CLAUDE.md.
   - `templates/CLAUDE.md` → `<repo>/CLAUDE.md` — Claude-specific
     orchestration (subagent vs background delegation, when to proactively
     checkpoint `state.md` before context runs out).
   - `templates/settings.json` → `<repo>/.claude/settings.json` — merge into
     an existing file if one is already there, don't clobber other
     permissions.
   - `templates/worker.md` → `<repo>/.claude/agents/worker.md`.
   - `templates/scripts/resume.sh` → `<repo>/scripts/resume.sh` (make it
     executable: `chmod +x scripts/resume.sh`) — the one-command handoff: run
     `scripts/resume.sh opencode` (or `codex` / `claude`) the moment one
     backend hits its limit, and it hands the in-progress task to the other
     with the exact next step, no retyping needed.
   - `templates/opencode.json` → `<repo>/opencode.json` — the deny-list
     backstop described below. Merge into an existing file rather than
     overwriting, same as settings.json.
4. **Adjust the backend rule in CLAUDE.md** to only reference the backend(s)
   actually installed (step 1).
5. **Show the final files to the user and stop** — do not start an actual
   implementation task in the same turn unless asked.

## Safety: why an autonomous backend won't push schema changes or force-push
Three independent layers, because none of them alone is enough:
1. **Isolation** — every task runs in its own `git worktree`/branch
   (`agent/<task-id>`), created before any implementation starts. Nothing
   touches the user's checked-out branch; there's a diff to review, not a
   fait accompli.
2. **Guardrails as policy** — `AGENTS.md`'s Guardrails section lists what no
   backend may do without the user explicitly naming it in `plan.md` first:
   `git push`/force-push, schema/migration changes, `.env`/CI edits,
   dependency/lockfile changes, out-of-scope deletions. The reviewer step in
   `CLAUDE.md` checks every round's diff against this list, not just against
   `plan.md`'s acceptance criteria.
3. **Guardrails as mechanism** — belt and suspenders for when policy alone
   isn't trusted: `codex exec -s workspace-write -a never` sandboxes writes to
   the worktree and disables network access by default (an autonomous
   `git push` has nowhere to go), and `opencode.json`'s `permission.bash`/
   `permission.edit` `"deny"` rules block the same patterns — confirmed by
   live testing (real `opencode run --auto` call against a free model, not
   just documentation) that the deny fires and the file genuinely stays
   untouched. Never pass `--dangerously-bypass-approvals-and-sandbox`, raise
   the sandbox to `danger-full-access`, or enable
   `sandbox_workspace_write.network_access` — any of those defeats layer 3
   (and layer 1 stays as backup, but don't rely on it alone).

**A fourth thing the same test surfaced:** a denied edit doesn't make a small/
free model give up — it can retry the identical blocked action step after
step instead of writing `report-N.md` and stopping (observed: 3+ retries of
the same denied `package.json` edit in under a minute). The guardrail holds —
nothing gets written — but the round can burn its whole time budget doing
nothing. That's why `worker.md` and `resume.sh` wrap every backend invocation
in `timeout`, and why a missing `report-N.md` is treated as "check the log,"
never as "nothing happened."

## Quick reference

| File | Purpose |
|---|---|
| `AGENTS.md` | Shared context + resumability protocol: build/test commands, conventions, how ANY backend resumes a task from `.agent-runs/` |
| `.claude/settings.json` | Pre-approves `codex exec`, `opencode run`, git diff/commit/worktree so the loop doesn't stall on prompts |
| `.claude/agents/worker.md` | Blocking subagent: invokes the backend CLI, updates `state.md`'s progress log, relays `report-N.md` + `git diff --stat` verbatim |
| `CLAUDE.md` | The orchestration loop: resume-or-create task dir, delegate, verify diff against `plan.md`, checkpoint `state.md` every round, retry via `feedback-N.md` up to 3 rounds |
| `scripts/resume.sh` | Run when a backend hits its limit: finds the in-progress task, reads its Next step, and re-launches it with another backend |
| `opencode.json` | Deny-list backstop: blocks `git push`, schema/migration commands, `.env`/CI/lockfile edits even under `opencode run --auto` |

### The handoff files (`.agent-runs/<task-id>/`)
| File | Written by | Purpose |
|---|---|---|
| `plan.md` | reviewer, once | Acceptance criteria, checkable against a diff |
| `state.md` | whoever last touched the task | Status, round, last driver, progress log, **next step** — the one file a cold agent reads first |
| `report-N.md` | implementer, per round | What changed and why (numbered, never overwritten) |
| `log-N.txt` | worker, per round | Raw stdout/stderr — fallback evidence when a permission denial silently stops the backend before it writes `report-N.md` |
| `feedback-N.md` | reviewer, per failed round | What's wrong and what to fix (numbered, never overwritten) |

## Common mistakes
- Inventing build/test commands for an empty or unfamiliar repo instead of
  inspecting it first — leave a placeholder and say so.
- Overwriting an existing `.claude/settings.json` wholesale instead of
  merging permissions.
- Referencing a backend CLI in CLAUDE.md that isn't actually installed on the
  machine.
- Putting the resumability protocol only in CLAUDE.md — Codex and OpenCode
  never read that file, only AGENTS.md. If it's not in AGENTS.md, they can't
  resume.
- Letting a backend end its turn on an unfinished task without updating
  `state.md`'s Next step — a vague "made progress" leaves the next agent
  unable to continue cold.
- Kicking off a real implementation task in the same turn as scaffolding —
  confirm the harness with the user first.
- Using `--full-auto` for codex — it doesn't exist in current codex-cli; use
  `-s workspace-write -a never`.
- Running an implementer against the main checkout instead of the task's
  worktree, or passing `--dangerously-bypass-approvals-and-sandbox` /
  `danger-full-access` / `network_access=true` — each one removes a layer of
  the safety design above.
- Treating `plan.md`'s acceptance criteria as the only thing worth checking —
  a diff can satisfy them and still violate a guardrail; check both.
- Treating a missing/empty `report-N.md` as "nothing to review" — a denied
  permission can silently stop OpenCode's agent loop mid-task before it
  writes anything; check `log-N.txt` before assuming the round was a no-op.

## Templates
See `templates/` for the four files verbatim (placeholders in
`<angle-brackets>`).
