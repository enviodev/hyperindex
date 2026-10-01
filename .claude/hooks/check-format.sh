#!/usr/bin/env bash
# Blocks `git push` while a file this branch touches is unformatted. Edits made
# through Bash bypass the PostToolUse formatter, so without this the first
# anyone hears of the formatting is a CI failure.
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
fi

if [ -n "$problems" ]; then
  jq -n --arg r "Formatting check failed, so the push was not run.$problems" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
