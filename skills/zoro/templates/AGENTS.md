# AGENTS.md

## Build/test
<real build and test commands for this project — inspect package.json/Makefile/etc first; if none exist yet, say so instead of guessing>

## Conventions
<real code style / architecture conventions found in the repo>

## Agent harness: plan -> implement -> review, resumable across backends

Implementation work in this repo runs through Codex CLI and/or OpenCode CLI,
planned and reviewed by Claude Code. All task state lives in files under
`.agent-runs/<task-id>/` — never only inside one CLI's conversation — so any
backend (Claude, Codex, OpenCode) can pick a task up cold if another one runs
out of context, crashes, or simply isn't the one currently running.

### Before starting ANY task
1. Slug the request into a `<task-id>`.
2. Check whether `.agent-runs/<task-id>/` already exists.
   - **Exists → this is a RESUME, not a fresh start.** Read, in order:
     `state.md` (current status + next step), `plan.md` (acceptance criteria),
     the highest-numbered `report-N.md` and `feedback-N.md`, then run
     `git log --oneline -10` and `git diff` to confirm what actually landed.
     Continue from there — do not restart from scratch or re-ask the user what
     the task is.
   - **Doesn't exist → fresh task.** Create an isolated worktree and branch so
     nothing lands on the user's current branch until reviewed:
     `git worktree add .agent-runs/<task-id>/worktree -b agent/<task-id>`.
     Then write `plan.md` inside `.agent-runs/<task-id>/` (not the worktree).
     All implementation commands run with the CLI's working-directory flag
     pointed at that worktree (`codex exec -C ...`, `opencode run --dir ...`),
     never in the main checkout.

## Guardrails — never do these autonomously

An implementer backend must **stop and write a `feedback-N.md` asking the
reviewer to escalate to the user** instead of doing any of the following,
even if it seems necessary to satisfy `plan.md` — unless `plan.md` names the
exact change explicitly (the user saw and approved it in the plan, not just
in a diff after the fact):

- `git push`, `git push --force`, or any change to the remote — merging
  `agent/<task-id>` into the user's branch is a decision for the user, not
  the loop.
- Schema/migration changes (`migrations/`, `schema.prisma`, `*.sql`, ORM
  migration commands) or anything that runs against a real database.
- Editing `.env`, secrets, credentials, or CI/CD config (`.github/workflows/`,
  etc.).
- Changing dependency versions or lockfiles (`package.json` deps,
  `package-lock.json`, `Cargo.lock`, ...) unless the task is explicitly a
  dependency bump.
- Deleting or rewriting files outside what `plan.md` scopes.

The reviewer (whichever backend is driving) must check every round's diff
against this list, not just against `plan.md`'s acceptance criteria — a diff
can satisfy the stated criteria and still touch something on this list.

### Technical backstops (defense in depth, not a substitute for the list above)
- Codex: invoke with `-s workspace-write -a never` — sandboxes filesystem
  writes to the worktree, disables network access by default (blocks
  `git push`, registry publishes), and returns failures to the model instead
  of hanging on an approval prompt no one will answer. Never pass
  `--dangerously-bypass-approvals-and-sandbox` or enable
  `sandbox_workspace_write.network_access`.
- OpenCode: this repo ships `opencode.json` with explicit `"deny"` rules for
  the same dangerous patterns. `opencode run --auto` auto-approves only what
  would otherwise prompt (`"ask"`) — it can never override an explicit
  `"deny"` rule, so the deny list holds even under `--auto`. Confirmed by live
  testing (not just documentation): a denied edit does genuinely fail — the
  file stays untouched — but a small/free model can respond by retrying the
  *same* denied edit step after step instead of giving up and writing
  `report-N.md`. That's why every invocation is wrapped in `timeout` (see
  `.claude/agents/worker.md`) — the guardrail protects the files, the timeout
  protects the round from spinning forever on a wall it can't get through.

### Files in .agent-runs/<task-id>/
- `worktree/` — the isolated git worktree/branch (`agent/<task-id>`) where all
  implementation actually happens. Never work directly in the user's checkout.
- `plan.md` — acceptance criteria, checkable against a diff. Written once at
  task start, not rewritten per round.
- `state.md` — single source of truth for where the task stands right now:
  ```
  Status: in_progress | blocked | done
  Round: <n>
  Last driver: claude | codex | opencode

  ## Original request
  <verbatim>

  ## Progress log
  - round 1 (<backend>): <one line — what happened, which report file>
  - round 2 (<backend>): <...>

  ## Next step
  <one concrete sentence: exactly what whoever picks this up next should do>
  ```
- `report-N.md` — what changed in round N, written by whichever backend ran
  it. If it's missing or empty after a round, that round did not finish
  normally — check `log-N.txt`, don't assume nothing happened.
- `log-N.txt` — raw stdout/stderr from round N's backend invocation. A denied
  permission can leave a model retrying the same blocked action instead of
  ever writing `report-N.md`, so this is the fallback evidence for what
  actually happened (grep for `action=deny` / `rule which prevents`).
- `feedback-N.md` — what's wrong with round N and what to fix, written by the reviewer.
- Never overwrite a prior round's report/feedback/log file — always increment N.

### Ending your turn on a task you haven't finished
Whatever backend you are — whether you finished the round, hit a context/token
limit, or were interrupted — update `state.md`'s Round, Last driver, Progress
log, and Next step fields before stopping. "Made progress" is not a valid Next
step; it must be concrete enough that an agent with zero prior context can act
on it immediately, in a different CLI, with no memory of this conversation.
