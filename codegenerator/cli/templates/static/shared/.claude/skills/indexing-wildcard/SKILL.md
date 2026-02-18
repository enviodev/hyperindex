---
name: indexing-wildcard
description: >-
  Use when indexing all instances of a contract across all addresses (e.g., all
  ERC-20 transfers on a chain). Config setup (no address), wildcard handler
  option, and event.srcAddress.
---

# Wildcard Indexing

Index all events matching an event signature across all contract addresses on a chain.

## Config (no address = wildcard)

```yaml
contracts:
  - name: ERC20
    events:
      - event: Transfer(indexed address from, indexed address to, uint256 value)

chains:
  - id: 1
    contracts:
      - name: ERC20
        # No address = wildcard (indexes ALL matching events on the chain)
```

## Handler with `wildcard: true`

Pass `wildcard: true` as the handler's 2nd argument. Use `event.srcAddress` to identify which contract emitted the event:

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => {
    const tokenAddress = event.srcAddress; // The actual contract address
    const id = `${event.chainId}-${event.transaction.hash}-${event.logIndex}`;

    context.Transfer.set({
      id,
      token_id: `${event.chainId}-${tokenAddress}`,
      from: event.params.from,
      to: event.params.to,
      value: event.params.value,
    });
  },
  { wildcard: true }
);
```

## Combining with Event Filters

Wildcard indexing produces high event volume. Use `eventFilters` to reduce it — see the `indexing-filters` skill for array, function, and `addresses` forms.

```ts
ERC20.Transfer.handler(
  async ({ event, context }) => { /* ... */ },
  {
    wildcard: true,
    eventFilters: [{ from: ZERO_ADDRESS }],
  }
);
```

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
