Migrate a TheGraph subgraph to Envio HyperIndex indexer.

**Prerequisites:**
- Ensure the subgraph folder is in your workspace before starting
- This migration follows a step-by-step process - complete each step before moving to the next

Follow the instructions in the `subgraph-migration.mdc` rule file for the complete migration process.

The migration consists of 7 main steps:
1. Clear boilerplate code in EventHandlers.ts
2. Migrate schema from TheGraph to Envio format
3. Refactor file structure to mirror subgraph
4. Register dynamic contracts with factory events
5. Implement handlers (helper functions → simple → moderate → complex)
6. Final migration verification
7. Environment variables setup

**Commands to run for validation at each step:**
```bash
pnpm codegen
pnpm tsc --noEmit
TUI_OFF=true pnpm dev
```

**Key Differences from TheGraph:**
- Remove `@entity` decorators from schema
- Change `Bytes!` to `String!` in schema
- Entity arrays MUST have `@derivedFrom` directives
- Use `context.Entity.set()` instead of `entity.save()`
- Use `context.Entity.get()` instead of `store.get()`
- Use Effect API for all external calls (RPC, API)
- Use spread operator for entity updates (entities are immutable)
- Prefix entity IDs with `chainId` for multichain support
