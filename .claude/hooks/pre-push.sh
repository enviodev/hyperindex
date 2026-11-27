#!/usr/bin/env bash
# Blocks `git push` while a file this branch touches is unformatted, fails
# clippy or fails the test-input lint. Edits made through Bash bypass the
# PostToolUse formatter, and nothing runs clippy or the lint on an edit, so
# without this the first anyone hears of any of them is a CI failure.
set -uo pipefail

cmd=$(jq -r '.tool_input.command // ""')
case "$cmd" in
*"git push"*) ;;
*) exit 0 ;;
esac

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

base=$(git merge-base HEAD origin/main 2>/dev/null || true)
changed=$(
  {
    git diff --name-only HEAD
    [ -n "$base" ] && git diff --name-only "$base"...HEAD
    git ls-files -o --exclude-standard
  } | sort -u | while read -r f; do [ -f "$f" ] && echo "$f"; done
)

problems=""

res=$(printf '%s\n' "$changed" | grep -E '\.resi?$' || true)
if [ -n "$res" ]; then
  out=$(printf '%s\n' "$res" | xargs pnpx rescript@12.2.0 format --check 2>&1 | grep '^\[format check\]' || true)
  if [ -n "$out" ]; then
    problems="$problems"$'\n'"Unformatted ReScript (fix: pnpx rescript@12.2.0 format <files>):"$'\n'"$out"
  fi
fi

if printf '%s\n' "$changed" | grep -q '^packages/cli/'; then
  if ! out=$(cd packages/cli && cargo fmt --check 2>&1); then
    problems="$problems"$'\n'"Unformatted Rust (fix: cd packages/cli && cargo fmt):"$'\n'"$out"
  fi

  # Clippy takes over a minute even with warm dependencies, so it is skipped
  # while packages/cli is byte for byte what the last clean run saw. The stamp
  # is taken before the run: an edit landing mid-run then forces another one.
  clippy_stamp_file=target/.clippy-clean
  clippy_stamp=$(
    {
      git ls-files -s packages/cli
      git diff HEAD -- packages/cli
      git ls-files -o --exclude-standard packages/cli
      git ls-files -o --exclude-standard -z packages/cli | xargs -0 git hash-object --
    } 2>&1 | git hash-object --stdin
  )
  if [ "$clippy_stamp" != "$(cat "$clippy_stamp_file" 2>/dev/null)" ]; then
    if out=$(cd packages/cli && cargo clippy --all-targets --all-features 2>&1); then
      mkdir -p target && printf '%s\n' "$clippy_stamp" >"$clippy_stamp_file"
    else
      # A diagnostic starts at `error` or `warning` in the first column and
      # runs to the next blank line; cargo's progress lines sit between them.
      blocks=$(printf '%s\n' "$out" | awk '/^(error|warning)/ { inBlock = 1 } inBlock { print } /^$/ { inBlock = 0 }')
      [ -n "$blocks" ] || blocks=$out
      shown=$(printf '%s\n' "$blocks" | head -n 80)
      hidden=$(($(printf '%s\n' "$blocks" | wc -l) - 80))
      if [ "$hidden" -gt 0 ]; then
        shown="$shown"$'\n'"... $hidden more lines (cd packages/cli && cargo clippy --all-targets --all-features)"
      fi
      problems="$problems"$'\n'"Clippy failed (fix, then push again):"$'\n'"$shown"
    fi
  fi
fi

if printf '%s\n' "$changed" | grep -qE '^packages/(envio-tests/test|envio/src)/'; then
  if ! out=$(node packages/envio-tests/scripts/lint-inputs.ts 2>&1); then
    problems="$problems"$'\n'"Lint failed (fix, then push again):"$'\n'"$out"
  fi
fi

if [ -n "$problems" ]; then
  jq -n --arg r "Pre-push checks failed, so the push was not run.$problems" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
