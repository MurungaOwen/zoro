# Autonomous plan -> implement -> review workflow

On a build/feature/fix request, run this loop end to end without pausing for
confirmation between steps. Only speak to the user at the very start (acknowledge
the task) and at the very end (final result). Do not ask "should I proceed?" or
"should I try again?" mid-loop.

See AGENTS.md for the cross-backend resumability protocol
(`.agent-runs/<task-id>/state.md`, `plan.md`, `report-N.md`, `feedback-N.md`)
and — just as important — its **Guardrails** section listing what an
implementer must never do autonomously (git push, schema/migration changes,
`.env`/CI edits, dependency/lockfile changes, out-of-scope deletions). Follow
both exactly. The protocol is shared with Codex/OpenCode so any of you can
resume the other's work if this session runs out of context; the guardrails
apply to every backend equally.

## Steps
1. Slug the request. Check for an existing `.agent-runs/<task-id>/` — if
   found, resume per AGENTS.md instead of starting over. Otherwise create the
   isolated worktree/branch (`git worktree add .agent-runs/<task-id>/worktree
   -b agent/<task-id>`) and write `plan.md` with explicit, checkable
   acceptance criteria (not vague goals - things you can verify against a
   diff). If the request itself requires a guardrail item (e.g. "bump this
   dependency"), say so explicitly in `plan.md` — that's what makes it an
   approved exception instead of a violation.
2. Choose a backend: <fill in based on which of codex/opencode are actually
   installed on this machine, and any preference for implementation-heavy vs
   test-writing/refactor tasks>.
3. Delegate via the `worker` subagent (blocking) for tasks you expect to take under
   ~2 minutes. For longer tasks, launch the backend CLI directly as a background
   Bash command instead (see "Background mode" below) so you can do other useful
   work meanwhile instead of sitting idle. Every invocation runs inside the
   task's worktree, never the main checkout.
4. When the result comes back: read the new `report-N.md`, then run
   `git diff --stat` (not bare `git diff`) inside the worktree first — on a
   large codebase a full diff can be huge, and `--stat`'s file list is enough
   to check scope against `plan.md` and the Guardrails list before reading any
   content. Only pull `git diff -- <path>` for the specific files `plan.md`
   actually concerns; if `--stat` shows files outside that scope, that's a
   guardrail question to raise before you spend context reading their
   content. Check every acceptance criterion against the actual diff — do not
   just trust `report-N.md`'s claims — **and separately check the changed-file
   list against AGENTS.md's Guardrails list**, even for files `plan.md` never
   mentioned.
5. If any criterion fails, or the diff touches a guardrail item `plan.md`
   didn't explicitly call out: write `feedback-N.md` describing precisely
   what's wrong and what to fix (for a guardrail hit, the fix is "don't touch
   this — ask the user"). Re-delegate with `plan.md` + `feedback-N.md`. Max 3
   rounds total.
6. After every round — pass or fail — update `state.md` (Round, Last driver,
   Progress log, Next step) before doing anything else. If you notice your own
   context getting long (many rounds, huge diffs, long tool output), update
   `state.md` proactively and tell the user, so a fresh Claude session or a
   direct `codex exec` / `opencode run` call can continue without missing
   anything.
7. If all criteria pass, or round 3 is reached without passing: stop. Summarize
   for the user what was built and checked, and **explicitly surface the diff
   for review** — never merge `agent/<task-id>` into their branch or push
   anywhere yourself. Merging/pushing happens only on a direct, separate
   instruction from the user, after they've seen the diff. (If round 3 failed,
   also say what's still wrong and why you stopped instead of continuing.)

## Background mode
Launch as: `Bash(command="<backend command> > .agent-runs/<task-id>/report-N.md 2>&1; echo DONE >> .agent-runs/<task-id>/status", run_in_background=true)`
Then, instead of blocking: continue other useful work if any exists, and check
`BashOutput` on that shell before ending any turn or starting new work. The
moment status contains DONE, stop polling that shell, update `state.md`, and
proceed to step 4.

## Backend commands
<only list the ones actually installed/authenticated>
codex:    codex exec -C .agent-runs/<task-id>/worktree -s workspace-write -a never "<prompt>"
opencode: opencode run --auto --dir .agent-runs/<task-id>/worktree "<prompt>"

Never add `--dangerously-bypass-approvals-and-sandbox` (codex) or raise the
sandbox to `danger-full-access`, and never enable
`sandbox_workspace_write.network_access` — network access being off by
default is what keeps an autonomous `git push` from reaching the remote.
