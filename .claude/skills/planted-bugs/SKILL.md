---
name: planted-bugs
description: >-
  Use when checking that tests catch what they claim, by planting bugs: after
  writing or rewriting tests, before deleting some, or when a review asks what
  a suite really covers.
---

# Planted bugs

A test proves something only if it fails when the behaviour breaks. For each behaviour the tests claim to pin, break it on purpose and see which test notices.

## Setup: a worktree outside the repo

Plant in a second checkout, never in the working tree. A session that ends with a planted bug in the working tree is asked to commit it.

```bash
git worktree add --detach ../hyperindex-planted HEAD
cd ../hyperindex-planted && pnpm install
cd packages/envio-tests && pnpm rescript
```

The first `pnpm vitest run` there builds the addon from scratch into `<worktree>/target/`, which takes about five minutes. Don't link that directory to the main checkout's build: both checkouts would then load one addon file, built from whichever ran last, so the main checkout can end up testing a planted bug.

## The loop

1. List the behaviours, one line each, with the test that claims it.
2. Plant one bug: the smallest edit that breaks that behaviour and nothing else. Flip a comparison, drop a branch, return early, move a bound by one.
3. Run what should catch it: `pnpm rescript && pnpm vitest run test/Name_test.res.mjs`. A Rust plant needs no extra step; the run rebuilds the addon.
4. Write down what failed, then undo the plant: `git checkout -- .`
5. Next bug. One at a time, so a failure has one cause.

## Reading a result

- **A test fails on the behaviour**: caught.
- **It doesn't compile**: caught by the types. Say so; it needs no test.
- **Everything passes**: write the missing test in the main checkout, copy it into the worktree, and check both ways: it fails with the bug planted and passes on clean code.
- **Everything passes and no input from outside can tell the bug from correct code**: a finding, not a test. Report it with the reason. The code stays as defence in depth.
- **An unrelated test fails**: the plant was too broad. Narrow it and run again.

## Report

In the PR body: one row per planted bug, with the behaviour, the edit and the test that caught it. List the bugs nothing can catch separately, each with why. https://github.com/enviodev/hyperindex/pull/1853 is the model.

## Clean up

```bash
git worktree remove --force ../hyperindex-planted
```
