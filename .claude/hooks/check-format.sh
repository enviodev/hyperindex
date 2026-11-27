#!/usr/bin/env bash
# Blocks `git push` while a file this branch touches is unformatted, or while
# `pnpm lint` fails. Edits made through Bash bypass the PostToolUse formatter,
# and nothing runs the lint on an edit, so without this the first anyone hears
# of either is a CI failure.
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

# The lint reads the whole working tree in about a second, so it runs on every
# push rather than only when a file it covers changed.
if ! out=$(cd packages/envio-tests && pnpm --silent lint 2>&1); then
  failures=$(printf '%s\n' "$out" | grep -E '^([^ ]+:[0-9]+: |not ok )' || printf '%s\n' "$out" | tail -n 20)
  problems="$problems"$'\n'"Lint failed (rerun: cd packages/envio-tests && pnpm lint). Each line ends with its fix:"$'\n'"$failures"
fi

if [ -n "$problems" ]; then
  jq -n --arg r "The push check failed, so the push was not run.$problems" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
