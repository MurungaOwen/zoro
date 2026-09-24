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
     `git log --oneline -10` and `git diff --stat` (not bare `git diff` — on a
     large codebase the full diff can be huge; pull `git diff -- <path>` only
     for files that matter) to confirm what actually landed. Continue from
     there — do not restart from scratch or re-ask the user what the task is.
   - **Doesn't exist → fresh task.** First confirm `<task-id>` isn't already a
     branch name unrelated to this protocol — `git rev-parse --verify --quiet
     agent/<task-id>` — since `.agent-runs/<task-id>/` not existing only means
     *this protocol* hasn't used that slug, not that the branch name is free.
     If it resolves, pick a more specific slug. Then create an isolated
     worktree and branch so nothing lands on the user's current branch until
     reviewed: `git worktree add .agent-runs/<task-id>/worktree -b
     agent/<task-id>`. Write `plan.md` inside `.agent-runs/<task-id>/` (not
     the worktree) with explicit, checkable acceptance criteria — include
     "existing tests still pass" whenever this repo has a test suite, not
     just the feature-specific criteria, since that's what `test-N.txt`
     (below) gets checked against. All implementation commands run with the
     CLI's working-directory flag pointed at that worktree (`codex exec -C
     ...`, `opencode run --dir ...`), never in the main checkout. On a very
     large repo where a full checkout per task is itself costly, follow the
     worktree add with `git -C .agent-runs/<task-id>/worktree sparse-checkout
     set <paths>` scoped to what the task touches — skip this for
     normal-sized repos, it's not worth the extra step.

## Guardrails — never do these autonomously

An implementer backend must **stop and write a `feedback-N.md` asking the
reviewer to escalate to the user** instead of doing any of the following,
even if it seems necessary to satisfy `plan.md` — unless `plan.md` names the
exact change explicitly (the user saw and approved it in the plan, not just
in a diff after the fact — see "Approved exceptions" below for how that
approval actually gets executed):

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
Verify these flags against `codex exec --help` / `opencode run --help` before
first use and whenever a round behaves unexpectedly — both CLIs are young
enough that flag names can drift between versions faster than this file gets
updated (this skill has already had to fix one flag that stopped existing;
see SKILL.md's Common mistakes).

- Codex: invoke with `-s workspace-write -a never` — sandboxes filesystem
  writes to the worktree, disables network access by default (blocks
  `git push`, registry publishes), and returns failures to the model instead
  of hanging on an approval prompt no one will answer. Never pass
  `--dangerously-bypass-approvals-and-sandbox` or enable
  `sandbox_workspace_write.network_access`, except for one round under
  "Approved exceptions" below.
- OpenCode: this repo ships `opencode.json` with explicit `"deny"` rules for
  the same dangerous patterns. `opencode run --auto` auto-approves only what
  would otherwise prompt (`"ask"`) — it should never override an explicit
  `"deny"` rule, so the deny list should hold even under `--auto`. Observed
  in testing at the time this skill was written (one small/free model, one
  OpenCode version — re-verify rather than treating this as a permanent
  guarantee): a denied edit does genuinely fail, the file stays untouched —
  but the model responded by retrying the *same* denied edit step after step
  instead of giving up and writing `report-N.md`. That's why every
  invocation runs through `scripts/run_backend.sh` (see
  `.claude/agents/worker.md`) instead of a bare command — it wraps a
  `timeout` *and* kills the round early the moment it detects that retry
  loop, instead of burning the whole time budget on nothing.

### Approved exceptions to the guardrails
`plan.md` can explicitly name an exception the user has already seen and
approved — "bump lodash to 4.17.21", "add the `posts` table migration". When
it does, the *policy* above allows it, but the *technical backstops* don't
know that on their own — they're static, repo-wide config, not aware of any
single task's plan. Loosen them for exactly that round, then restore
immediately after, so the repo is never left weakened between rounds:

1. Before delegating the round, snapshot what you're about to change:
   `cp opencode.json opencode.json.bak` (for Codex, just note in `state.md`
   that this round adds an extra flag — there's no file to snapshot).
2. Loosen only the specific thing `plan.md` approved, nothing broader:
   - **OpenCode** — edit the one matching `"deny"` rule in `opencode.json` to
     `"ask"`. An unattended `--auto` run against `"ask"` fails closed (no one
     to answer the prompt), which is the safe outcome if the exception was
     misjudged. If the round genuinely needs to run unattended, use
     `"allow"` for that single key only — never widen it to a whole
     category.
   - **Codex** — for a network-dependent exception (e.g. `npm install` for a
     dependency bump), add `-c sandbox_workspace_write.network_access=true`
     to that one invocation instead of raising `-s` to `danger-full-access` —
     grant the smallest capability the approved action actually needs.
3. Run the round.
4. Restore immediately, whether the round passed or failed:
   `mv opencode.json.bak opencode.json` (or drop the added `-c` flag from the
   next round's command). Record the loosen/restore in `state.md`'s progress
   log — a resuming agent that finds a weakened `opencode.json` with no
   explanation should assume something is wrong, not that it's normal.

Never loosen a backstop for anything `plan.md` doesn't name explicitly, and
never leave it loosened past the one round it was approved for.

### Files in .agent-runs/<task-id>/
- `worktree/` — the isolated git worktree/branch (`agent/<task-id>`) where all
  implementation actually happens. Never work directly in the user's checkout.
- `plan.md` — acceptance criteria, checkable against a diff. Written once at
  task start, not rewritten per round.
- `state.md` — single source of truth for where the task stands right now:
  ```
  Status: in_progress | blocked | done | abandoned
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
- `prompt-N.txt` — the exact prompt sent to the backend for round N (plan +
  feedback, if any), written by the worker before invoking the backend.
  Kept so a resuming agent — or a human — can see exactly what was asked
  for, not just what came back.
- `report-N.md` — what changed in round N, written by whichever backend ran
  it. If it's missing or empty after a round, that round did not finish
  normally — check `log-N.txt`, don't assume nothing happened.
- `log-N.txt` — raw stdout/stderr from round N's backend invocation. A denied
  permission can leave a model retrying the same blocked action instead of
  ever writing `report-N.md`, so this is the fallback evidence for what
  actually happened (grep for `action=deny` / `rule which prevents` for a
  guardrail denial, versus `401` / `Unauthorized` / `not logged in` for an
  auth failure that isn't a guardrail at all).
- `test-N.txt` — output of the repo's own build/test commands, run against
  round N's diff inside the worktree by `scripts/run_backend.sh`. Check this,
  not just `report-N.md`'s claims, before treating a round as passing.
- `feedback-N.md` — what's wrong with round N and what to fix, written by the reviewer.
- Never overwrite a prior round's prompt/report/feedback/log/test file —
  always increment N.

### Keeping `.agent-runs/` out of the project's history
Add `.agent-runs/` to `.gitignore` during setup if it isn't already there —
it's ephemeral orchestration state (worktrees, raw logs, per-round reports),
not something that belongs in the repo's history or shows up in a PR diff.
Nothing in this protocol pushes `agent/<task-id>` anywhere either (see
Guardrails), so there's no cross-machine handoff depending on it being
tracked — the numbered files are for the current checkout's own audit trail,
not something else to check out.

### Ending your turn on a task you haven't finished
Whatever backend you are — whether you finished the round, hit a context/token
limit, or were interrupted — update `state.md`'s Round, Last driver, Progress
log, and Next step fields before stopping. "Made progress" is not a valid Next
step; it must be concrete enough that an agent with zero prior context can act
on it immediately, in a different CLI, with no memory of this conversation.

### Finishing a task
Once the user has decided what to do with a task's branch (merged, or
explicitly discarded), clean up: `git worktree remove
.agent-runs/<task-id>/worktree` then `git branch -d agent/<task-id>`. Do this
only after that decision, never automatically — the worktree is the only
copy of a round's work until it's merged, and removing it early destroys
whatever was there. Leave `plan.md`, `state.md`, and the numbered
prompt/report/feedback/log/test files in place afterward (set `state.md`'s
Status to `done` or `abandoned`) — they're small, and they're the cheapest
record of what was tried if the same task comes back.
