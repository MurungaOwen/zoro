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

Codex, Copilot CLI, and Gemini CLI also recognize `~/.agents/skills/` as a
cross-runtime alias, if you want the skill available there too:

```sh
cp -r skills/zoro ~/.agents/skills/
```

## Use

In any project, ask Claude Code to set up the harness (or invoke the `zoro`
skill directly). It will:
1. Check that `codex` and/or `opencode` are installed.
2. Inspect the target repo for real build/test commands.
3. Write `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`,
   `.claude/agents/worker.md`, `scripts/resume.sh`, and `opencode.json`,
   filled in for that project.

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
   confirmed that `opencode run --auto` only auto-approves what would
   otherwise prompt, and can never override a `"deny"` rule.

None of this stops you from approving something on that list yourself — it
stops it from happening *without* you noticing.

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

See [`skills/zoro/SKILL.md`](skills/zoro/SKILL.md) for the full process and
the `.agent-runs/` handoff protocol.
