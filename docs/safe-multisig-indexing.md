# Indexing Safe Multisig with HyperIndex

This guide explains how to use HyperIndex to index [Safe](https://safe.global/) (formerly Gnosis Safe) multisig wallets — tracking deployments, transactions, ownership changes, and module management across multiple EVM chains.

## Overview

Safe is the most widely used smart account infrastructure, with 57M+ accounts deployed across 15+ EVM chains. HyperIndex's factory pattern and multichain support make it an ideal indexer for Safe's architecture.

### Why HyperIndex for Safe?

- **Factory pattern support**: Safe wallets are deployed via `SafeProxyFactory`. HyperIndex's `contractRegister` dynamically discovers and indexes new Safes as they're created — no hardcoded addresses needed.
- **Multichain**: Index Safe wallets across Ethereum, Gnosis, Polygon, Arbitrum, Base, Optimism, and 80+ other chains in a single config.
- **Performance**: 25,000+ events/sec during historical backfills.
- **GraphQL API**: Auto-generated API for querying indexed data.

## Safe Contract Architecture

Safe uses a proxy pattern:

1. **SafeProxyFactory** — Deploys new Safe proxy instances via `CREATE2`
2. **SafeL2** — The Safe implementation contract that emits events for all transaction executions

> **Important**: Use `SafeL2`, not `Safe`. The base `Safe.sol` contract doesn't emit detailed transaction events (it relies on trace-level indexing). `SafeL2.sol` emits full events at the cost of slightly higher gas, which is what HyperIndex needs.

## Events Reference

### SafeProxyFactory Events

| Event | Description |
|---|---|
| `ProxyCreation(address indexed proxy, address singleton)` | Emitted when a new Safe proxy is deployed |

### SafeL2 Events

| Event | Description |
|---|---|
| `SafeSetup(address indexed initiator, address[] owners, uint256 threshold, address to, address fallbackHandler)` | Initial Safe configuration after deployment |
| `ExecutionSuccess(bytes32 indexed txHash, uint256 payment)` | Transaction executed successfully |
| `ExecutionFailure(bytes32 indexed txHash, uint256 payment)` | Transaction execution failed |
| `SafeMultiSigTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures, bytes additionalInfo)` | Full multisig transaction details (L2 only) |
| `AddedOwner(address owner)` | Owner added to the Safe |
| `RemovedOwner(address owner)` | Owner removed from the Safe |
| `ChangedThreshold(uint256 threshold)` | Signing threshold changed |
| `ApproveHash(bytes32 indexed approvedHash, address indexed owner)` | Transaction hash pre-approved by an owner |
| `EnabledModule(address module)` | Module enabled on the Safe |
| `DisabledModule(address module)` | Module disabled on the Safe |
| `ExecutionFromModuleSuccess(address indexed module)` | Module-initiated transaction succeeded |
| `ExecutionFromModuleFailure(address indexed module)` | Module-initiated transaction failed |

The `SafeMultiSigTransaction` event's `additionalInfo` parameter is ABI-encoded as `abi.encode(nonce, msg.sender, threshold)` to work around Solidity's stack depth limitations.

## Setup

### 1. Initialize a HyperIndex Project

```bash
pnpm envio init
```

Select the EVM ecosystem and TypeScript language when prompted.

### 2. Configuration (`config.yaml`)

```yaml
# yaml-language-server: $schema=./node_modules/envio/evm.schema.json
name: safe-multisig-indexer
description: Index Safe multisig wallets - deployments, transactions, and ownership changes

contracts:
  # Factory contract — discovers new Safe deployments
  - name: SafeProxyFactory
    events:
      - event: ProxyCreation(address indexed proxy, address singleton)

  # Each Safe wallet (dynamically registered via factory)
  - name: SafeL2
    events:
      - event: SafeSetup(address indexed initiator, address[] owners, uint256 threshold, address to, address fallbackHandler)
      - event: ExecutionSuccess(bytes32 indexed txHash, uint256 payment)
      - event: ExecutionFailure(bytes32 indexed txHash, uint256 payment)
      - event: AddedOwner(address owner)
      - event: RemovedOwner(address owner)
      - event: ChangedThreshold(uint256 threshold)
      - event: ApproveHash(bytes32 indexed approvedHash, address indexed owner)
      - event: EnabledModule(address module)
      - event: DisabledModule(address module)

chains:
  - id: 1  # Ethereum Mainnet
    start_block: 17440000
    contracts:
      - name: SafeProxyFactory
        address:
          - 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67  # v1.4.1
          - 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2  # v1.3.0
      - name: SafeL2
```

> **Note**: Adjust `start_block` to the block when the factory was deployed on each chain. For multichain indexing, add additional chain entries with their respective factory addresses.

### 3. Schema (`schema.graphql`)

```graphql
type Safe {
  id: ID!                    # Safe proxy address
  owners: [String!]!
  threshold: BigInt!
  singleton: String!
  createdAtBlock: Int!
  createdAtTimestamp: BigInt!
  createdBy: String!
  txCount: Int!
  chainId: Int!
  transactions: [SafeTransaction!]! @derivedFrom(field: "safe")
  ownerChanges: [OwnerChange!]! @derivedFrom(field: "safe")
  thresholdChanges: [ThresholdChange!]! @derivedFrom(field: "safe")
}

type SafeTransaction {
  id: ID!
  safe: Safe!
  txHash: String!
  success: Boolean!
  payment: BigInt!
  blockNumber: Int!
  timestamp: BigInt!
  chainId: Int!
}

type OwnerChange {
  id: ID!
  safe: Safe!
  owner: String!
  added: Boolean!            # true = added, false = removed
  blockNumber: Int!
  timestamp: BigInt!
  chainId: Int!
}

type ThresholdChange {
  id: ID!
  safe: Safe!
  newThreshold: BigInt!
  blockNumber: Int!
  timestamp: BigInt!
  chainId: Int!
}

type ModuleChange {
  id: ID!
  safe: Safe!
  module: String!
  enabled: Boolean!          # true = enabled, false = disabled
  blockNumber: Int!
  timestamp: BigInt!
  chainId: Int!
}
```

### 4. Event Handlers

#### `src/handlers/SafeProxyFactory.ts`

The factory handler dynamically registers each new Safe for indexing:

```typescript
import { SafeProxyFactory } from "generated";

// Dynamically register each new Safe wallet for event indexing.
// This runs BEFORE the handler and tells HyperIndex to start
// listening for SafeL2 events on the newly deployed proxy address.
SafeProxyFactory.ProxyCreation.contractRegister(({ event, context }) => {
  context.addSafeL2(event.params.proxy);
});

SafeProxyFactory.ProxyCreation.handler(async ({ event, context }) => {
  context.Safe.set({
    id: event.params.proxy,
    owners: [],
    threshold: 0n,
    singleton: event.params.singleton,
    createdAtBlock: event.block.number,
    createdAtTimestamp: BigInt(event.block.timestamp),
    createdBy: event.transaction?.from ?? "unknown",
    txCount: 0,
    chainId: event.chainId,
  });
});
```

#### `src/handlers/SafeL2.ts`

```typescript
import { SafeL2 } from "generated";

// ── Setup ────────────────────────────────────────────────────

SafeL2.SafeSetup.handler(async ({ event, context }) => {
  const safe = await context.Safe.get(event.srcAddress);
  context.Safe.set({
    id: event.srcAddress,
    owners: event.params.owners,
    threshold: event.params.threshold,
    singleton: safe?.singleton ?? "",
    createdAtBlock: safe?.createdAtBlock ?? event.block.number,
    createdAtTimestamp: safe?.createdAtTimestamp ?? BigInt(event.block.timestamp),
    createdBy: event.params.initiator,
    txCount: safe?.txCount ?? 0,
    chainId: event.chainId,
  });
});

// ── Transactions ─────────────────────────────────────────────

SafeL2.ExecutionSuccess.handler(async ({ event, context }) => {
  const safe = await context.Safe.get(event.srcAddress);
  if (safe) {
    context.Safe.set({ ...safe, txCount: safe.txCount + 1 });
  }

  context.SafeTransaction.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    txHash: event.params.txHash,
    success: true,
    payment: event.params.payment,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

SafeL2.ExecutionFailure.handler(async ({ event, context }) => {
  context.SafeTransaction.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    txHash: event.params.txHash,
    success: false,
    payment: event.params.payment,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

// ── Ownership ────────────────────────────────────────────────

SafeL2.AddedOwner.handler(async ({ event, context }) => {
  const safe = await context.Safe.get(event.srcAddress);
  if (safe) {
    context.Safe.set({
      ...safe,
      owners: [...safe.owners, event.params.owner],
    });
  }

  context.OwnerChange.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    owner: event.params.owner,
    added: true,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

SafeL2.RemovedOwner.handler(async ({ event, context }) => {
  const safe = await context.Safe.get(event.srcAddress);
  if (safe) {
    context.Safe.set({
      ...safe,
      owners: safe.owners.filter((o) => o !== event.params.owner),
    });
  }

  context.OwnerChange.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    owner: event.params.owner,
    added: false,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

// ── Threshold ────────────────────────────────────────────────

SafeL2.ChangedThreshold.handler(async ({ event, context }) => {
  const safe = await context.Safe.get(event.srcAddress);
  if (safe) {
    context.Safe.set({ ...safe, threshold: event.params.threshold });
  }

  context.ThresholdChange.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    newThreshold: event.params.threshold,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

// ── Modules ──────────────────────────────────────────────────

SafeL2.EnabledModule.handler(async ({ event, context }) => {
  context.ModuleChange.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    module: event.params.module,
    enabled: true,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

SafeL2.DisabledModule.handler(async ({ event, context }) => {
  context.ModuleChange.set({
    id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
    safe_id: event.srcAddress,
    module: event.params.module,
    enabled: false,
    blockNumber: event.block.number,
    timestamp: BigInt(event.block.timestamp),
    chainId: event.chainId,
  });
});

// ── Hash Approvals ───────────────────────────────────────────
// ApproveHash events can be used to track off-chain signature
// collection. Uncomment and add a HashApproval entity if needed.
//
// SafeL2.ApproveHash.handler(async ({ event, context }) => {
//   context.HashApproval.set({
//     id: `${event.chainId}_${event.block.number}_${event.logIndex}`,
//     safe_id: event.srcAddress,
//     approvedHash: event.params.approvedHash,
//     owner: event.params.owner,
//     blockNumber: event.block.number,
//     timestamp: BigInt(event.block.timestamp),
//     chainId: event.chainId,
//   });
// });
```

### 5. Run the Indexer

```bash
# Generate types and code from config
pnpm envio codegen

# Start the indexer (with local database)
pnpm envio dev
```

## Multichain Configuration

To index Safe across multiple chains, add entries under `chains`:

```yaml
chains:
  - id: 1        # Ethereum
    start_block: 17440000
    contracts:
      - name: SafeProxyFactory
        address:
          - 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
          - 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2
      - name: SafeL2

  - id: 10       # Optimism
    start_block: 106000000
    contracts:
      - name: SafeProxyFactory
        address:
          - 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
          - 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2
      - name: SafeL2

  - id: 8453     # Base
    start_block: 1000000
    contracts:
      - name: SafeProxyFactory
        address:
          - 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
          - 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2
      - name: SafeL2

  - id: 42161    # Arbitrum
    start_block: 100000000
    contracts:
      - name: SafeProxyFactory
        address:
          - 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67
          - 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2
      - name: SafeL2
```

For a full list of Safe deployment addresses per chain, see the [safe-deployments](https://github.com/safe-global/safe-deployments) repository.

## Example GraphQL Queries

Once the indexer is running, query the auto-generated GraphQL API:

### Get a Safe's details and recent transactions

```graphql
query SafeDetails($address: String!) {
  Safe(where: { id: $address }) {
    id
    owners
    threshold
    txCount
    chainId
    createdAtTimestamp
    transactions(limit: 10, order_by: { blockNumber: desc }) {
      txHash
      success
      payment
      blockNumber
      timestamp
    }
  }
}
```

### List all Safes created by a specific deployer

```graphql
query SafesByDeployer($deployer: String!) {
  Safe(where: { createdBy: $deployer }) {
    id
    owners
    threshold
    chainId
  }
}
```

### Get ownership change history for a Safe

```graphql
query OwnerHistory($safeAddress: String!) {
  OwnerChange(
    where: { safe_id: $safeAddress }
    order_by: { blockNumber: asc }
  ) {
    owner
    added
    blockNumber
    timestamp
  }
}
```

## Known Factory Addresses

| Version | Address | Notes |
|---|---|---|
| v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | Latest, deployed on most chains |
| v1.3.0 | `0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2` | Widely deployed, still in active use |

Both versions emit the same `ProxyCreation` event signature.

## References

- [Safe Smart Account Contracts](https://github.com/safe-global/safe-smart-account)
- [SafeL2.sol (v1.4.1)](https://github.com/safe-global/safe-smart-account/blob/v1.4.1/contracts/SafeL2.sol)
- [SafeProxyFactory.sol](https://github.com/safe-global/safe-smart-account/blob/main/contracts/proxies/SafeProxyFactory.sol)
- [Safe Deployments (all chains)](https://github.com/safe-global/safe-deployments)
- [HyperIndex Documentation](https://docs.envio.dev)
- [HyperIndex Factory Pattern Guide](https://docs.envio.dev/docs/HyperIndex/contract-import)
