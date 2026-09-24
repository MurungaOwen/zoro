# zoro

A Claude Code skill that scaffolds a **plan -> implement -> review** loop into
any project: Claude Code plans and reviews, Codex CLI and/or OpenCode CLI do
the implementation as non-interactive subprocesses.

All task state is written to files under `.agent-runs/<task-id>/`, never kept
only in one CLI's conversation. If Claude runs out of context mid-task, a
fresh Claude session — or `codex exec` / `opencode run` directly — can pick
the same task up cold and continue.

## Install

Clone this repo, then copy (or symlink) the `zoro` skill folder into your
personal skills directory:

```sh
git clone <this-repo-url>
cd <cloned-folder>
cp -r skills/zoro ~/.claude/skills/
```

Some other CLIs are converging on a shared `~/.agents/skills/` directory as a
cross-runtime alias for skills — check your specific CLI's docs to confirm it
actually reads that path before relying on it, since (unlike `AGENTS.md`
itself) this isn't a universally documented convention yet:

```sh
cp -r skills/zoro ~/.agents/skills/
```

## Use

In any project, ask Claude Code to set up the harness (or invoke the `zoro`
skill directly). It will:
1. Check that `codex` and/or `opencode` are installed, and sanity-check that
   the flags the templates use still exist on your installed version.
2. Inspect the target repo for real build/test commands — these get run
   after every implementation round to verify a diff, not just documented.
3. Write `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`,
   `.claude/agents/worker.md`, `scripts/resume.sh`, `scripts/run_backend.sh`,
   `opencode.json`, and a `.agent-runs/` entry in `.gitignore`, filled in for
   that project.

## Guardrails — keeping autonomous runs from doing something you didn't want

Three layers, so no single flag or forgotten check leaves you exposed:

1. **Isolation.** Every task runs in its own `git worktree` on branch
   `agent/<task-id>` — never your checked-out branch. You always get a diff
   to review, never a change that already happened.
2. **A written deny-list.** `AGENTS.md` lists what no backend may do without
   you naming it explicitly in that task's `plan.md` first: `git push`/
   force-push, schema or migration changes, editing `.env`/CI config,
   touching lockfiles or dependency versions, deleting anything out of scope.
   The reviewing backend checks every round's diff against this list, not
   just against the task's stated acceptance criteria.
3. **Enforced at the tool level too.** Codex runs with
   `-s workspace-write -a never` — sandboxed to the worktree, network access
   off by default, so a stray `git push` has nowhere to go. OpenCode runs
   with `opencode.json`'s explicit `"deny"` rules for the same patterns —
   `opencode run --auto` is designed to only auto-approve what would
   otherwise prompt, never to override an explicit `"deny"` rule (observed
   holding in testing at the time this was built; re-verify if OpenCode's
   permission behavior ever changes underneath you).

None of this stops you from approving something on that list yourself — via
`AGENTS.md`'s "Approved exceptions to the guardrails" process, which loosens
layer 3 for exactly one named round and restores it immediately after. It
stops something from happening *without* you noticing, not from happening at
all once you've said yes.

Every round also runs through `scripts/run_backend.sh`, which adds two things
a bare CLI call doesn't give you: it kills a round early if the backend gets
stuck retrying the same denied action instead of waiting out the full
timeout, and it runs the project's real build/test commands afterward so a
round is graded on `test-N.txt`, not on the backend's own claim that things
work.

## Switching backends mid-task

When Claude hits its usage limit (or any backend does) partway through a
task, don't re-explain anything — run:

```sh
scripts/resume.sh opencode   # or: codex / claude
```

It finds the in-progress task under `.agent-runs/`, reads its `state.md`
(what's done, what's left, the exact next step), and launches the new backend
with that context handed to it directly. The new backend also reads
`AGENTS.md` automatically on startup (Codex and OpenCode both honor it, the
same way Claude honors `CLAUDE.md`), which carries the full resumability
protocol — so it knows to check `.agent-runs/` before doing anything else even
if you invoke it without the script.

## Finishing up

Once you've decided what to do with a task's branch — merge it or discard it
— clean up with `git worktree remove .agent-runs/<task-id>/worktree` and
`git branch -d agent/<task-id>`. Nothing does this automatically, on purpose:
the worktree is the only copy of a round's work until it's actually merged.
The task directory itself (`plan.md`, `state.md`, the numbered
prompt/report/feedback/log/test files) is safe to leave in place afterward —
it's `.gitignore`d, small, and doubles as a record of what was tried if the
same task comes back.

See [`skills/zoro/SKILL.md`](skills/zoro/SKILL.md) for the full process and
the `.agent-runs/` handoff protocol.
