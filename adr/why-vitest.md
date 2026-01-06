# Why Vitest for User-Facing Indexer Tests

## Status

Accepted

## Context

Previously used Mocha and Chai for user-facing indexer tests. This approach had several problems:

- Complex configuration required for TypeScript with TSX
- Difficult to expose to users since we don't control their environment
- Snapshot testing support would make configuration even more complex
- Not flexible enough for a user-controlled setup

Main drivers for change:

1. Upgrade to ESM modules
2. Updated TypeScript setup made Mocha/Chai very difficult to configure
3. New createTestIndexer framework (end-to-end testing) relies heavily on snapshot testing - configuring this per-user with Mocha/Chai would be very complicated

## Alternatives Considered

- **Node.js built-in test runner**: Same configuration complexity issues as Mocha/Chai
- **Ava.js**: Good testing framework, but requires complex setup for TypeScript + ESM
- **Jest**: Not considered at all - bad ESM support, essentially deprecated for modern projects. Vitest is its successor and does things much better

## Decision

Chose Vitest because:

- **Zero configuration for users**: Just install and run `vitest run`
- **Most popular testing framework** in modern JS/web development, well-supported
- **Uses Vite under the hood**: We may adopt Vite for indexer compilation in the future
- **Flexible test file discovery**: Tests can live next to handlers (e.g., `handler.test.ts` in `src/`) without extra config
- **Powerful runtime API**: Potentially can vendor Vitest in the future and expose it behind `envio test`

## Consequences

### Positive

- Users can run tests without any configuration
- Test files can be colocated with handlers in `src/` directory
- Excellent snapshot testing support out of the box
- Future path to vendor and customize the test runner

### Negative

- Watch mode (`vitest --watch`) doesn't work well - it tries to auto-detect affected tests via imports, but handlers don't directly import test files, so handler changes don't trigger test reruns. Not critical; solution may exist but not yet investigated
