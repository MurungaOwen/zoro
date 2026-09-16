#!/usr/bin/env bash
# Hand off the most recently active in-progress .agent-runs/ task to another
# backend. Use this the moment one CLI hits its limit — it reads state.md so
# the next backend doesn't have to guess the task-id or what's left to do.
#
# Usage: scripts/resume.sh <codex|opencode|claude>
set -euo pipefail

backend="${1:?usage: resume.sh <codex|opencode|claude>}"

task_dir=""
for d in $(ls -dt .agent-runs/*/ 2>/dev/null); do
  if grep -q '^Status: in_progress' "$d/state.md" 2>/dev/null; then
    task_dir="${d%/}"
    break
  fi
done

if [ -z "$task_dir" ]; then
  echo "No in-progress task found under .agent-runs/" >&2
  exit 1
fi

task_id=$(basename "$task_dir")
next_step=$(awk '/## Next step/{f=1;next} f && NF{print; exit}' "$task_dir/state.md")

worktree="$task_dir/worktree"
if [ ! -d "$worktree" ]; then
  echo "Expected worktree at $worktree but it's missing — check AGENTS.md's isolation step." >&2
  exit 1
fi

prompt="Read AGENTS.md, then resume the task in .agent-runs/${task_id}/ per its resumability protocol (read state.md, plan.md, the latest report-N.md/feedback-N.md, then git log/git diff before acting) and its Guardrails section. state.md's Next step: ${next_step}"

echo "Resuming task: $task_id"
echo "Next step: $next_step"
echo "Working directory (isolated worktree): $worktree"
echo

# A denied edit doesn't make a backend give up — it can retry the same
# blocked action step after step instead of stopping (confirmed by testing).
# Cap wall-clock time so a resumed task can't run unattended forever.
timeout_s="${RESUME_TIMEOUT:-600}"

case "$backend" in
  codex)    timeout "$timeout_s" codex exec -C "$worktree" -s workspace-write -a never "$prompt" ;;
  opencode) timeout "$timeout_s" opencode run --auto --dir "$worktree" "$prompt" ;;
  claude)   claude -p "$prompt" ;;
  *) echo "unknown backend: $backend (use codex, opencode, or claude)" >&2; exit 1 ;;
esac
