# Migration Patterns

Detailed code patterns for migrating from TheGraph subgraph to Envio HyperIndex.

## Entity Creation Pattern

```typescript
// TheGraph:
let entity = new EventEntity(
  event.transaction.hash.concatI32(event.logIndex.toI32())
);
entity.field1 = event.params.field1;
entity.save();

// Envio:
const entity: EventEntity = {
  id: `${event.chainId}-${event.transaction.hash}-${event.logIndex}`,
  field1: event.params.field1,
  blockNumber: BigInt(event.block.number),
  blockTimestamp: BigInt(event.block.timestamp),
  transactionHash: event.transaction.hash,
};
context.EventEntity.set(entity);
```

**`transaction.hash` requires `field_selection` in config.yaml:**

```yaml
- event: EventName(...)
  field_selection:
    transaction_fields:
      - hash
```

This applies to ALL events that need transaction data (Transfer, Mint, Burn, Swap, any event creating Transaction entities).

**Without field selection:** `event.transaction.hash` is undefined, `event.transaction` is empty `{}`.

## Entity Updates Pattern

```typescript
// TheGraph:
let entity = store.get("EntityName", id);
if (entity) {
  entity.field = newValue;
  entity.save();
}

// Envio:
let entity = await context.EntityName.get(id);
if (entity) {
  const updatedEntity: EntityName = {
    ...entity,
    field: newValue,
    updatedAt: BigInt(Date.now()),
  };
  context.EntityName.set(updatedEntity);
}
```

**Entities are read-only — always use spread operator for updates.**

## Contract Registration Pattern

```typescript
// TheGraph:
ContractTemplate.create(event.params.contract);

// Envio:
Contract.EventCreated.contractRegister(({ event, context }) => {
  context.addContract(event.params.contract);
});
```

## BigDecimal Precision

**Maintain the same mathematical precision as the original subgraph.**

```typescript
// WRONG — loses precision for financial calculations
export const ZERO_BD = 0;
export function convertTokenToDecimal(tokenAmount: bigint, exchangeDecimals: bigint): number {
  return Number(tokenAmount) / Math.pow(10, Number(exchangeDecimals));
}

// CORRECT — maintains precision
import { BigDecimal } from "generated";

export const ZERO_BD = new BigDecimal(0);
export const ONE_BD = new BigDecimal(1);
export const ZERO_BI = BigInt(0);
export const ONE_BI = BigInt(1);
export const ADDRESS_ZERO = "0x0000000000000000000000000000000000000000";

export function convertTokenToDecimal(tokenAmount: bigint, exchangeDecimals: bigint): BigDecimal {
  if (exchangeDecimals == ZERO_BI) {
    return new BigDecimal(tokenAmount.toString());
  }
  return new BigDecimal(tokenAmount.toString()).div(exponentToBigDecimal(exchangeDecimals));
}
```

**Common mistakes:**
1. Replacing `ZERO_BD` with `0` — loses precision
2. Replacing `ZERO_BI` with `0` — wrong type
3. Returning `number` instead of `BigDecimal` — loses precision
4. Using `Math.pow()` instead of `BigDecimal` arithmetic — loses precision

**Entity field initialization:**
```typescript
// CORRECT — use constants
const pair: Pair = {
  id: event.params.pair,
  reserve0: ZERO_BD,     // NOT 0
  reserve1: ZERO_BD,     // NOT 0
  totalSupply: ZERO_BD,  // NOT 0
  volumeUSD: ZERO_BD,    // NOT 0
  txCount: ZERO_BI,      // NOT 0
};
```

## Handling Subgraph Array Access Patterns

Subgraphs can directly access entity arrays. Envio cannot — `@derivedFrom` arrays are virtual.

```typescript
// TheGraph — direct array access:
transaction.mints.push(mint);
transaction.burns.push(burn);

// Envio — query via indexed fields:
const mints = await context.Mint.getWhere({ transaction_id: { _eq: transactionId } });
const burns = await context.Burn.getWhere({ transaction_id: { _eq: transactionId } });
```

**Full example:**
```typescript
const existingMint = await context.Mint.getWhere({ transaction_id: { _eq: transactionId } });

if (existingMint.length > 0) {
  // Update existing mint entity
  const updatedMint: Mint = {
    ...existingMint[0],
    amount0: event.params.amount0,
    amount1: event.params.amount1,
  };
  context.Mint.set(updatedMint);
} else {
  // Create new mint entity
  const newMint: Mint = {
    id: mintId,
    transaction_id: transactionId,
    amount0: event.params.amount0,
    amount1: event.params.amount1,
  };
  context.Mint.set(newMint);
}
```

---

## Effect API for External Calls

ALL external calls (RPC, fetch, APIs) MUST use the Effect API. This is mandatory because handlers run twice (preload + sequential).

### Basic Effect Pattern

```typescript
import { S, createEffect } from "envio";

export const getSomething = createEffect(
  {
    name: "getSomething",
    input: { address: S.string, blockNumber: S.number },
    output: S.union([S.string, null]),
    cache: true,
    rateLimit: false,
  },
  async ({ input, context }) => {
    const something = await fetch(
      `https://api.example.com/something?address=${input.address}&blockNumber=${input.blockNumber}`
    );
    return something.json();
  }
);
```

### Handler Consumption

```typescript
import { getSomething } from "./effects";

Contract.Event.handler(async ({ event, context }) => {
  const something = await context.effect(getSomething, {
    address: event.srcAddress,
    blockNumber: event.block.number,
  });
});
```

### Contract State Fetching (.bind() → Effect API)

TheGraph uses `.bind()` for contract state. Envio requires Effect API with viem:

```typescript
// TheGraph:
let token = Token.bind(event.params.token);
entity.name = token.name();
entity.symbol = token.symbol();
entity.decimals = token.decimals();

// Envio — use Effect API with viem:
```

**Full viem Effect implementation:**

```typescript
// src/effects/tokenMetadata.ts
import { createEffect, S } from "envio";
import { createPublicClient, http, parseAbi } from "viem";

const ERC20_ABI = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
]);

const publicClient = createPublicClient({
  transport: http(process.env.RPC_URL),
});

export const getTokenMetadata = createEffect(
  {
    name: "getTokenMetadata",
    input: S.string,
    output: S.object({
      name: S.string,
      symbol: S.string,
      decimals: S.number,
      totalSupply: S.string,
    }),
    cache: true,
  },
  async ({ input: tokenAddress, context }) => {
    try {
      const [name, symbol, decimals, totalSupply] = await Promise.all([
        publicClient.readContract({ address: tokenAddress as `0x${string}`, abi: ERC20_ABI, functionName: "name" }),
        publicClient.readContract({ address: tokenAddress as `0x${string}`, abi: ERC20_ABI, functionName: "symbol" }),
        publicClient.readContract({ address: tokenAddress as `0x${string}`, abi: ERC20_ABI, functionName: "decimals" }),
        publicClient.readContract({ address: tokenAddress as `0x${string}`, abi: ERC20_ABI, functionName: "totalSupply" }),
      ]);
      return { name, symbol, decimals: Number(decimals), totalSupply: totalSupply.toString() };
    } catch (error) {
      context.log.error(`Error fetching token metadata for ${tokenAddress}: ${error}`);
      return { name: "Unknown", symbol: "Unknown", decimals: 0, totalSupply: "0" };
    }
  }
);
```

### Handler with Effect API

```typescript
import { getTokenMetadata } from "./effects/tokenMetadata";

Contract.EventName.handler(async ({ event, context }) => {
  const tokenMetadata = await context.effect(getTokenMetadata, event.params.token);

  const entity: Entity = {
    id: `${event.chainId}-${event.transaction.hash}-${event.logIndex}`,
    name: tokenMetadata.name,
    symbol: tokenMetadata.symbol,
    decimals: BigInt(tokenMetadata.decimals),
    totalSupply: BigInt(tokenMetadata.totalSupply),
    blockNumber: BigInt(event.block.number),
    blockTimestamp: BigInt(event.block.timestamp),
    transactionHash: event.transaction.hash,
  };
  context.Entity.set(entity);
});
```

### Batch Effect Calls

```typescript
// Parallel Effect API calls for efficiency
const [tokenMetadata, vaultMetadata] = await Promise.all([
  context.effect(getTokenMetadata, event.params.token),
  context.effect(getTokenMetadata, event.params.vault),
]);
```

### Factory + Effect API Combined

```typescript
import { getTokenMetadata } from "./effects/tokenMetadata";

ContractFactory.ContractCreated.contractRegister(({ event, context }) => {
  context.addContract(event.params.contract);
});

ContractFactory.ContractCreated.handler(async ({ event, context }) => {
  const [contractMetadata, tokenMetadata] = await Promise.all([
    context.effect(getTokenMetadata, event.params.contract),
    context.effect(getTokenMetadata, event.params.token),
  ]);

  let token = await context.Token.get(event.params.token);
  if (!token) {
    token = {
      id: event.params.token,
      name: tokenMetadata.name,
      symbol: tokenMetadata.symbol,
      decimals: BigInt(tokenMetadata.decimals),
      totalSupply: BigInt(tokenMetadata.totalSupply),
    };
    context.Token.set(token);
  }

  const contract: ContractDataEntity = {
    id: event.params.contract,
    name: contractMetadata.name,
    symbol: contractMetadata.symbol,
    decimals: BigInt(contractMetadata.decimals),
    token_id: event.params.token,
    timestamp: BigInt(event.block.timestamp),
  };
  context.ContractDataEntity.set(contract);
});
```

## Multichain Support

- Prefix ALL entity IDs: `${event.chainId}-${originalId}`
- Never hardcode `chainId = 1` — use `event.chainId`
- Chain-specific Bundle IDs: `${event.chainId}-1`
- Update helper functions to accept `chainId` parameter
