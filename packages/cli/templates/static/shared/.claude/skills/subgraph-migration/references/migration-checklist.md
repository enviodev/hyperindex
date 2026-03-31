# Migration Quality Checklist

Use this checklist to verify migration completeness before final sign-off.

## Setup
- [ ] Subgraph GraphQL endpoint obtained
- [ ] Test blocks identified with representative events
- [ ] Subgraph folder available in workspace for reference

## Schema
- [ ] All `@entity` decorators removed
- [ ] `Bytes!` → `String!` in schema
- [ ] All entity arrays have `@derivedFrom`
- [ ] `entity_id` fields used for relationships (not entity references)
- [ ] `ID!` used for primary key fields
- [ ] No unsupported time-series aggregation fields

## Config
- [ ] Uses `chains` (not `networks`)
- [ ] `field_selection` added for transaction fields (hash, etc.)
- [ ] Dynamic contracts have no `address` field
- [ ] `contractRegister` defined before handler for factory patterns

## Handlers
- [ ] Entity IDs prefixed with `chainId` (`${event.chainId}-${id}`)
- [ ] All external calls use Effect API (`createEffect` + `context.effect()`)
- [ ] BigDecimal precision maintained (import from `generated`)
- [ ] Field names match generated types (`_id` suffix for relations)
- [ ] `context.Entity.get()` calls use `await`
- [ ] `context.Entity.set()` calls do NOT use `await`
- [ ] Spread operator used for entity updates

## Testing
- [ ] Tests pass for all handlers
- [ ] Snapshots captured for regression testing
- [ ] Results verified against subgraph data at test blocks
- [ ] Entity counts match between subgraph and HyperIndex
