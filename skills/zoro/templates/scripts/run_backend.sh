#!/usr/bin/env bash
# Runs one implementation round against a backend CLI, adding three things a
# bare `timeout <cmd>` call can't give you on its own:
#   1. an early exit when the backend is stuck retrying the same denied
#      action instead of burning the whole time budget on nothing — a
#      guardrail can hold (the file stays untouched) while the model just
#      keeps retrying the same blocked edit instead of giving up (see
#      AGENTS.md's Guardrails section for why this happens)
#   2. the project's own build/test commands run afterward, so the reviewer
#      checks real pass/fail output instead of trusting whatever the backend
#      claims in report-N.md
#   3. one place this logic lives, instead of duplicated inline wherever a
#      backend gets invoked
#
# Usage:
#   scripts/run_backend.sh <task_dir> <codex|opencode> <round_n> <prompt_file> [timeout_seconds] [build_test_cmd]
#
# build_test_cmd is the real command from AGENTS.md's Build/test section
# (e.g. "npm test"), passed as one quoted argument. Omit it to skip
# verification (test-N.txt will say so explicitly rather than silently
# looking like a pass).
set -uo pipefail

task_dir="${1:?usage: run_backend.sh <task_dir> <codex|opencode> <round_n> <prompt_file> [timeout_seconds] [build_test_cmd]}"
backend="${2:?missing backend}"
round_n="${3:?missing round number}"
prompt_file="${4:?missing prompt file}"
timeout_s="${5:-600}"
build_test_cmd="${6:-}"

worktree="$task_dir/worktree"
log_file="$task_dir/log-${round_n}.txt"
test_file="$task_dir/test-${round_n}.txt"

if [ ! -d "$worktree" ]; then
  echo "Expected worktree at $worktree but it's missing." >&2
  exit 1
fi
if [ ! -f "$prompt_file" ]; then
  echo "Prompt file $prompt_file not found." >&2
  exit 1
fi

prompt="$(cat "$prompt_file")"

case "$backend" in
  codex)    cmd=(codex exec -C "$worktree" -s workspace-write -a never "$prompt") ;;
  opencode) cmd=(opencode run --auto --dir "$worktree" "$prompt") ;;
  *) echo "unknown backend: $backend (use codex or opencode)" >&2; exit 1 ;;
esac

: > "$log_file"
"${cmd[@]}" >> "$log_file" 2>&1 &
backend_pid=$!

# Watch the log for the same denial line repeating. A small/free model can
# retry an identical blocked action step after step instead of giving up
# (observed in testing at the time this skill was written — see AGENTS.md's
# Guardrails section; treat this as "this can happen," not a guarantee about
# every model/version). Three repeats of the exact same line is a stuck
# loop, not progress, so kill early instead of waiting out the full timeout
# for nothing.
deadline=$((SECONDS + timeout_s))
last_line=""
repeat_count=0
killed_early=0
timed_out=0
while kill -0 "$backend_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    kill "$backend_pid" 2>/dev/null
    timed_out=1
    break
  fi
  current_line=$(grep -E 'action=deny|rejected permission|rule which prevents' "$log_file" 2>/dev/null | tail -1)
  if [ -n "$current_line" ] && [ "$current_line" = "$last_line" ]; then
    repeat_count=$((repeat_count + 1))
    if [ "$repeat_count" -ge 3 ]; then
      kill "$backend_pid" 2>/dev/null
      killed_early=1
      break
    fi
  else
    repeat_count=0
  fi
  last_line="$current_line"
  sleep 5
done
wait "$backend_pid" 2>/dev/null
exit_code=$?

if [ "$timed_out" -eq 1 ]; then
  echo "TIMEOUT after ${timeout_s}s" >> "$log_file"
elif [ "$killed_early" -eq 1 ]; then
  echo "KILLED EARLY: same denial line repeated ${repeat_count}x - guardrail held, backend was stuck retrying it instead of stopping" >> "$log_file"
fi

# Verify against the repo's own build/test commands rather than trusting
# report-N.md's claim that things work - a backend can report success on a
# broken build.
if [ -n "$build_test_cmd" ]; then
  ( cd "$worktree" && eval "$build_test_cmd" ) > "$test_file" 2>&1
  test_exit=$?
  echo "exit_code=$test_exit" >> "$test_file"
else
  echo "No build_test_cmd given - skipped. Pass the real command from AGENTS.md's Build/test section as this script's 6th argument." > "$test_file"
fi

echo "backend_exit=$exit_code killed_early=$killed_early timed_out=$timed_out"
exit "$exit_code"
