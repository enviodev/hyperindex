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

# A session's clone can carry an origin/main days behind the commit the branch
# started from. Everything main gained since then would count as this branch's
# change, and a push that touched no Rust would pay for clippy.
git fetch -q origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null || true
base=$(git merge-base HEAD origin/main 2>/dev/null || true)

# Files the branch, the working tree or an untracked file adds or changes,
# narrowed to the given pathspecs.
changed_files() {
  {
    git diff --name-only HEAD -- "$@"
    [ -n "$base" ] && git diff --name-only "$base"...HEAD -- "$@"
    git ls-files -o --exclude-standard -- "$@"
  } | sort -u | while read -r f; do [ -f "$f" ] && echo "$f"; done
}

problems=""

res=$(changed_files '*.res' '*.resi')
if [ -n "$res" ]; then
  out=$(printf '%s\n' "$res" | xargs pnpx rescript@12.2.0 format --check 2>&1 | grep '^\[format check\]' || true)
  if [ -n "$out" ]; then
    problems="$problems"$'\n'"Unformatted ReScript (fix: pnpx rescript@12.2.0 format <files>):"$'\n'"$out"
  fi
fi

# Everything that can change what rustfmt or clippy report. The templates,
# snapshots and docs under packages/cli reach the build as bytes at most.
rust_inputs=('packages/cli/*.rs' packages/cli/Cargo.toml packages/cli/clippy.toml Cargo.toml Cargo.lock rust-toolchain.toml)
if [ -n "$(changed_files "${rust_inputs[@]}")" ]; then
  if ! out=$(cd packages/cli && cargo fmt --check -- --color never 2>&1); then
    problems="$problems"$'\n'"Unformatted Rust (fix: cd packages/cli && cargo fmt):"$'\n'"$out"
  fi

  # Clippy is the one slow check here, from 15 s warm to minutes cold, so it is
  # skipped while its inputs are byte for byte what the last clean run saw. The
  # stamp is taken before the run: an edit landing mid-run forces another one.
  clippy_stamp_file=target/.clippy-clean
  clippy_stamp=$(
    {
      git ls-files -s -- "${rust_inputs[@]}"
      git diff HEAD -- "${rust_inputs[@]}"
      git ls-files -o --exclude-standard -- "${rust_inputs[@]}"
      git ls-files -o --exclude-standard -z -- "${rust_inputs[@]}" | xargs -0 git hash-object --
    } | git hash-object --stdin
  )
  if [ "$clippy_stamp" != "$(cat "$clippy_stamp_file" 2>/dev/null)" ]; then
    if out=$(cd packages/cli && cargo clippy --quiet --all-targets --all-features 2>&1); then
      mkdir -p target && printf '%s\n' "$clippy_stamp" >"$clippy_stamp_file"
    else
      shown=$(printf '%s\n' "$out" | head -n 80)
      if [ "$shown" != "$out" ]; then
        shown="$shown"$'\n'"... cut at 80 lines (rest: cd packages/cli && cargo clippy --all-targets --all-features)"
      fi
      problems="$problems"$'\n'"Clippy failed (fix, then push again):"$'\n'"$shown"
    fi
  fi
fi

if [ -n "$(changed_files packages/envio-tests/test packages/envio/src)" ]; then
  if ! out=$(node packages/envio-tests/scripts/lint-inputs.ts 2>&1); then
    problems="$problems"$'\n'"Lint failed (fix, then push again):"$'\n'"$out"
  fi
fi

if [ -n "$problems" ]; then
  jq -n --arg r "Pre-push checks failed, so the push was not run.$problems" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
