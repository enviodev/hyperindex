open Vitest

// A self-contained mock indexer whose generated `envio` types back every
// assertion below. Two chains, two contracts (one event carries a custom
// `field_selection`, the rest inherit the global one), plus a schema with
// entities and enums — enough surface to pin the whole public TypeScript API.
let schema = `
enum AccountType {
  ADMIN
  USER
}

enum GravatarSize {
  SMALL
  MEDIUM
  LARGE
}

type Account {
  id: ID!
  balance: BigInt!
  accountType: AccountType!
  delegate: Account
}

type Delegation {
  id: ID!
  amount: BigInt!
}
`

let configYaml = `
name: ts-api-types
field_selection:
  transaction_fields:
    - transactionIndex
    - hash
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
        field_selection:
          block_fields:
            - parentHash
          transaction_fields:
            - to
            - from
            - hash
      - event: "Synced()"
  - name: Factory
    events:
      - event: PoolCreated(address indexed pool)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
      - name: Factory
        address: "0x0000000000000000000000000000000000000002"
  - id: 137
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000003"
      - name: Factory
        address: "0x0000000000000000000000000000000000000004"
`

// Type-checks `handlers` against the mock's generated types. A type error is
// thrown as the test failure, so each `it` only needs to hand over a snippet.
let check = handlers => InternalTestIndexer.fromUserApi(~schema, ~handlers, ~configYaml)->ignore

// Fuel needs a real Sway ABI (parsed by the `fuels` crate), so a known-good
// greeter ABI is supplied as a virtual file.
let fuelFiles = Dict.fromArray([("abis/greeter-abi.json", FuelAbiFixtures.greeter)])
let fuelConfig = `
name: fuel-api-types
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: 0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b
        abi_file_path: abis/greeter-abi.json
        events:
          - name: NewGreeting
          - name: ClearGreeting
`

let svmConfig = `
name: svm-api-types
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          instructions:
            - name: swap
              discriminator: "0x09"
              args:
                - { name: amountIn, type: u64 }
                - { name: minAmountOut, type: u64 }
              accounts:
                - source
                - destination
              field_selection:
                transaction_fields: [signatures]
`

let checkFuel = handlers =>
  InternalTestIndexer.fromUserApi(~schema, ~files=fuelFiles, ~handlers, ~configYaml=fuelConfig)->ignore

let checkSvm = handlers =>
  InternalTestIndexer.fromUserApi(~schema, ~handlers, ~configYaml=svmConfig)->ignore

describe("TypeScript API types", () => {
  it("resolves config-bound chain/contract name and id unions", _ =>
    check(`
import type {
  Address,
  EvmChainId,
  EvmChainName,
  EvmContractName,
  FuelChainId,
  SvmChainId,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<Address, \`0x\${string}\`>>(true);
expectType<TypeEqual<EvmChainId, 1 | 137>>(true);
expectType<TypeEqual<EvmChainName, "ethereumMainnet" | "polygon">>(true);
expectType<TypeEqual<EvmContractName, "Token" | "Factory">>(true);

// @ts-expect-error - "NotAContract" is not configured
const _bad: EvmContractName = "NotAContract";

// Non-configured ecosystems resolve to the codegen hint string, not a union.
expectType<
  TypeEqual<
    FuelChainId,
    "FuelChainId is not available. Configure Fuel chains in config.yaml and run 'envio codegen'"
  >
>(true);
expectType<
  TypeEqual<
    SvmChainId,
    "SvmChainId is not available. Configure SVM chains in config.yaml and run 'envio codegen'"
  >
>(true);
`)
  )

  it("looks up EvmEvent by contract and event name", _ =>
    check(`
import type {
  Address,
  EvmChainId,
  EvmEvent,
  EvmOnEvent,
  EvmOnEventWhereChain,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

// Without generics, the discriminant spans every configured event.
type AllEvents = EvmEvent;
expectType<TypeEqual<AllEvents["contractName"], "Token" | "Factory">>(true);

// EvmOnEvent is the config-generic form behind the EvmEvent alias.
expectType<TypeEqual<EvmOnEvent["contractName"], "Token" | "Factory">>(true);

// The where-callback chain object exposes the event's own contract addresses.
expectType<
  TypeEqual<EvmOnEventWhereChain<"Token">["Token"]["addresses"], readonly Address[]>
>(true);

type TokenEvent = EvmEvent<"Token">;
expectType<TypeEqual<TokenEvent["contractName"], "Token">>(true);

type TransferEvent = EvmEvent<"Token", "Transfer">;
expectType<TypeEqual<TransferEvent["contractName"], "Token">>(true);
expectType<TypeEqual<TransferEvent["eventName"], "Transfer">>(true);
expectType<TypeEqual<TransferEvent["chainId"], EvmChainId>>(true);
expectType<TypeEqual<TransferEvent["logIndex"], number>>(true);
expectType<TypeEqual<TransferEvent["srcAddress"], \`0x\${string}\`>>(true);
expectType<
  TypeEqual<
    TransferEvent["params"],
    {
      readonly from: Address;
      readonly to: Address;
      readonly value: bigint;
    }
  >
>(true);
expectType<TypeEqual<TransferEvent["block"]["number"], number>>(true);
expectType<TypeEqual<TransferEvent["block"]["timestamp"], number>>(true);
expectType<TypeEqual<TransferEvent["block"]["hash"], string>>(true);
`)
  )

  it("shapes onEvent / contractRegister options, handlers and contexts", _ =>
    check(`
import type {
  Account,
  Address,
  EvmContractRegisterContext,
  EvmContractRegisterHandler,
  EvmContractRegisterOptions,
  EvmEvent,
  EvmOnEventContext,
  EvmOnEventHandler,
  EvmOnEventOptions,
  EvmOnEventWhere,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

// Synced() has no indexed params, so the eventFilters lookup resolves to {}.
type SyncedOpts = EvmOnEventOptions<EvmEvent<"Token", "Synced">>;
expectType<
  TypeEqual<
    SyncedOpts,
    {
      readonly contract: "Token";
      readonly event: "Synced";
      readonly wildcard?: boolean;
      readonly where?: EvmOnEventWhere<{}, "Token">;
    }
  >
>(true);

type PoolCreated = EvmEvent<"Factory", "PoolCreated">;
expectType<
  TypeEqual<EvmContractRegisterOptions<PoolCreated>, EvmOnEventOptions<PoolCreated>>
>(true);

expectType<
  TypeEqual<
    EvmOnEventHandler<PoolCreated>,
    (args: { event: PoolCreated; context: EvmOnEventContext }) => Promise<void>
  >
>(true);
expectType<
  TypeEqual<
    EvmContractRegisterHandler<PoolCreated>,
    (args: {
      event: PoolCreated;
      context: EvmContractRegisterContext;
    }) => Promise<void>
  >
>(true);

// Without generics the handler accepts the union of every EVM event.
type DefaultArgs = Parameters<EvmOnEventHandler>[0];
expectType<TypeEqual<DefaultArgs["event"], EvmEvent>>(true);
expectType<TypeEqual<DefaultArgs["context"], EvmOnEventContext>>(true);

expectType<TypeEqual<EvmOnEventContext["chain"]["id"], 1 | 137>>(true);
expectType<TypeEqual<EvmOnEventContext["chain"]["isRealtime"], boolean>>(true);
expectType<TypeEqual<EvmOnEventContext["isPreload"], boolean>>(true);
expectType<
  TypeEqual<
    EvmOnEventContext["Account"]["get"],
    (id: string) => Promise<Account | undefined>
  >
>(true);
expectType<
  TypeEqual<EvmOnEventContext["Account"]["set"], (entity: Account) => void>
>(true);

expectType<TypeEqual<EvmContractRegisterContext["chain"]["id"], 1 | 137>>(true);
expectType<
  TypeEqual<
    EvmContractRegisterContext["chain"]["Token"]["add"],
    (address: Address) => void
  >
>(true);
expectType<
  TypeEqual<
    EvmContractRegisterContext["chain"]["Factory"]["add"],
    (address: Address) => void
  >
>(true);

// contractRegister context exposes no entity operations.
// @ts-expect-error - Account ops are not on the contractRegister context
type _accountOnCr = EvmContractRegisterContext["Account"];

// EvmOnEventOptions rejects an Event that isn't EventLike.
// @ts-expect-error - missing contractName/eventName
type _bad = EvmOnEventOptions<{ foo: "bar" }>;

// Union events keep contract/event paired; mismatches are rejected.
type UnionEvent = EvmEvent<"Token", "Transfer"> | EvmEvent<"Factory", "PoolCreated">;
type UnionOpts = EvmOnEventOptions<UnionEvent>;
const _a: UnionOpts = { contract: "Token", event: "Transfer" };
const _b: UnionOpts = { contract: "Factory", event: "PoolCreated" };
// @ts-expect-error - "PoolCreated" is not an event of "Token"
const _bad1: UnionOpts = { contract: "Token", event: "PoolCreated" };
// @ts-expect-error - "Transfer" is not an event of "Factory"
const _bad2: UnionOpts = { contract: "Factory", event: "Transfer" };
`)
  )

  it("narrows event block/transaction fields by field_selection", _ =>
    check(`
import type { EvmEvent } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

// Unselected fields carry the branded FieldNotSelected sentinel so reading
// them is a compile error instead of silently passing.
type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

// Approval declares custom block_fields [parentHash] and transaction_fields
// [to, from, hash]; defaults (number/timestamp/hash) stay included.
type ApprovalEvent = EvmEvent<"Token", "Approval">;
expectType<TypeEqual<ApprovalEvent["block"]["number"], number>>(true);
expectType<TypeEqual<ApprovalEvent["block"]["parentHash"], string>>(true);
expectType<IsNotSelected<ApprovalEvent["block"]["nonce"]>>(true);
expectType<
  TypeEqual<ApprovalEvent["transaction"]["to"], \`0x\${string}\` | undefined>
>(true);
expectType<
  TypeEqual<ApprovalEvent["transaction"]["from"], \`0x\${string}\` | undefined>
>(true);
expectType<TypeEqual<ApprovalEvent["transaction"]["hash"], string>>(true);
expectType<IsNotSelected<ApprovalEvent["transaction"]["gas"]>>(true);

// Transfer inherits the global selection: transaction [transactionIndex, hash].
type TransferEvent = EvmEvent<"Token", "Transfer">;
expectType<TypeEqual<TransferEvent["transaction"]["transactionIndex"], number>>(true);
expectType<TypeEqual<TransferEvent["transaction"]["hash"], string>>(true);
expectType<IsNotSelected<TransferEvent["transaction"]["from"]>>(true);
expectType<IsNotSelected<TransferEvent["block"]["parentHash"]>>(true);
`)
  )

  it("binds Entity / EntityName / Enum / EnumName to the schema", _ =>
    check(`
import type { Account, Entity, EntityName, Enum, EnumName } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const _account: EntityName = "Account";
const _delegation: EntityName = "Delegation";
// @ts-expect-error - "NotAnEntity" is not in the schema
const _badEntity: EntityName = "NotAnEntity";

expectType<TypeEqual<Entity<"Account">, Account>>(true);
expectType<TypeEqual<Entity<"Account">["id"], string>>(true);
expectType<TypeEqual<Entity<"Account">["balance"], bigint>>(true);
expectType<TypeEqual<Entity<"Account">["accountType"], "ADMIN" | "USER">>(true);
expectType<TypeEqual<Entity<"Account">["delegate_id"], string | undefined>>(true);
// @ts-expect-error - "NotAnEntity" is not assignable to EntityName
type _badEntityLookup = Entity<"NotAnEntity">;

const _accountType: EnumName = "AccountType";
const _size: EnumName = "GravatarSize";
// @ts-expect-error - "NotAnEnum" is not in the schema
const _badEnum: EnumName = "NotAnEnum";

expectType<TypeEqual<Enum<"AccountType">, "ADMIN" | "USER">>(true);
expectType<TypeEqual<Enum<"GravatarSize">, "SMALL" | "MEDIUM" | "LARGE">>(true);
// @ts-expect-error - "NotAnEnum" is not assignable to EnumName
type _badEnumLookup = Enum<"NotAnEnum">;
`)
  )

  it("shapes the onBlock surface", _ =>
    check(`
import type {
  EvmChainId,
  EvmOnBlockContext,
  EvmOnBlockFilter,
  EvmOnBlockHandler,
  EvmOnBlockHandlerArgs,
  EvmOnBlockOptions,
  EvmOnBlockWhereArgs,
  EvmOnBlockWhereResult,
  EvmOnEventContext,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<EvmOnBlockContext, EvmOnEventContext>>(true);
const _blockOpts: EvmOnBlockOptions = {
  name: "b",
  where: ({ chain }) => (chain.id === 1 ? true : false),
};
expectType<EvmOnBlockOptions>(_blockOpts);
expectType<
  TypeEqual<EvmOnBlockHandlerArgs["block"], { readonly number: number }>
>(true);
expectType<TypeEqual<EvmOnBlockHandlerArgs["context"], EvmOnBlockContext>>(true);
expectType<
  TypeEqual<EvmOnBlockHandler, (args: EvmOnBlockHandlerArgs) => Promise<void>>
>(true);

expectType<TypeEqual<EvmOnBlockWhereArgs["chain"]["id"], EvmChainId>>(true);
expectType<TypeEqual<EvmOnBlockWhereArgs["chain"]["isRealtime"], boolean>>(true);
expectType<TypeEqual<EvmOnBlockWhereArgs["chain"]["Token"]["name"], "Token">>(true);
expectType<
  TypeEqual<EvmOnBlockWhereArgs["chain"]["Factory"]["name"], "Factory">
>(true);

// The predicate result excludes void/undefined, so an implicit return fails.
expectType<TypeEqual<EvmOnBlockWhereResult, boolean | EvmOnBlockFilter>>(true);
type _Predicate = (args: {
  readonly chain: { readonly id: number };
}) => EvmOnBlockWhereResult;
// @ts-expect-error - implicit undefined return is not assignable
const _missingReturn: _Predicate = ({ chain }) => {
  if (chain.id === 1) return true;
};

const _ok: EvmOnBlockFilter = {
  block: { number: { _gte: 1, _lte: 10, _every: 2 } },
};
const _empty: EvmOnBlockFilter = {};
expectType<EvmOnBlockFilter>(_ok);
expectType<EvmOnBlockFilter>(_empty);
`)
  )

  it("guards the indexer.onEvent / contractRegister registration surface", _ =>
    check(`
import { indexer } from "envio";
import type { Address } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

// Type-only: guarded by \`if (0)\` so tsc validates the surface without
// registering handlers (registration throws once the indexer is built).
if (0) {
  indexer.onEvent(
    // @ts-expect-error - "BadContract" is not a configured contract
    { contract: "BadContract", event: "X" },
    async () => {},
  );
  indexer.onEvent(
    // @ts-expect-error - "BadEvent" is not an event of Token
    { contract: "Token", event: "BadEvent" },
    async () => {},
  );
  indexer.onEvent(
    { contract: "Token", event: "Transfer" },
    async ({ event }) => {
      expectType<TypeEqual<typeof event.params.value, bigint>>(true);
      expectType<TypeEqual<typeof event.params.from, Address>>(true);
    },
  );
  indexer.contractRegister(
    { contract: "Factory", event: "PoolCreated" },
    async ({ event, context }) => {
      expectType<TypeEqual<typeof event.params.pool, \`0x\${string}\`>>(true);
      context.chain.Factory.add(event.params.pool);
      context.chain.Token.add(event.params.pool);
      // @ts-expect-error - UnknownContract is not configured
      context.chain.UnknownContract.add(event.params.pool);
    },
  );

  // where.block must stay on the EVM \`number\` filter with only \`_gte\`.
  indexer.onEvent(
    {
      contract: "Token",
      event: "Transfer",
      wildcard: true,
      where: { block: { number: { _gte: 1 } } },
    },
    async () => {},
  );
  indexer.onEvent(
    {
      contract: "Token",
      event: "Transfer",
      wildcard: true,
      // @ts-expect-error - EVM keys block by \`number\`, not \`height\`.
      where: { block: { height: { _gte: 1 } } },
    },
    async () => {},
  );
  indexer.onEvent(
    {
      contract: "Token",
      event: "Transfer",
      wildcard: true,
      where: {
        block: {
          number: {
            // @ts-expect-error - Only \`_gte\` is supported on event filters.
            _lte: 1,
          },
        },
      },
    },
    async () => {},
  );
  indexer.onEvent(
    {
      contract: "Token",
      event: "Transfer",
      wildcard: true,
      where: {
        block: {
          number: {
            // @ts-expect-error - Only \`_gte\` is supported on event filters.
            _every: 100,
          },
        },
      },
    },
    async () => {},
  );
}
`)
  )

  it("narrows onEvent where.params by indexed event params", _ =>
    check(`
import { indexer } from "envio";
import type { Address, EvmOnEventWhere, SingleOrMultiple } from "envio";
import { expectType } from "ts-expect";

const ZERO: Address = "0x0000000000000000000000000000000000000000";

// Transfer's indexed params (from/to) resolve the where.params filter, each
// accepting a single value or an array (OR semantics).
type TransferWhere = EvmOnEventWhere<
  {
    readonly from?: SingleOrMultiple<Address>;
    readonly to?: SingleOrMultiple<Address>;
  },
  "Token"
>;
const _single: TransferWhere = { params: { from: ZERO } };
const _multi: TransferWhere = { params: { from: [ZERO], to: [ZERO] } };
expectType<TransferWhere>(_single);
expectType<TransferWhere>(_multi);

if (0) {
  indexer.onEvent(
    { contract: "Token", event: "Transfer", wildcard: true, where: { params: { from: ZERO } } },
    async () => {},
  );
  indexer.onEvent(
    { contract: "Token", event: "Transfer", wildcard: true, where: { params: { to: [ZERO] } } },
    async () => {},
  );
  indexer.onEvent(
    {
      contract: "Token",
      event: "Transfer",
      wildcard: true,
      // @ts-expect-error - value is not an indexed param, so it isn't filterable
      where: { params: { value: 1n } },
    },
    async () => {},
  );
}
`)
  )

  it("binds the Indexer / TestIndexer instances and TestHelpers", _ =>
    check(`
import { createTestIndexer, indexer, TestHelpers } from "envio";
import type {
  Account,
  Indexer,
  TestIndexer,
  TestIndexerProcessConfig,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<typeof indexer, Indexer>>(true);
expectType<TypeEqual<typeof createTestIndexer, () => TestIndexer>>(true);
expectType<TypeEqual<Indexer["name"], string>>(true);
expectType<TypeEqual<Indexer["chainIds"], readonly (1 | 137)[]>>(true);

// The test indexer exposes entity operations bound to the schema.
expectType<
  TypeEqual<TestIndexer["Account"]["set"], (entity: Account) => void>
>(true);

// process() config is keyed by chain id.
const _proc: TestIndexerProcessConfig = { chains: { 1: { startBlock: 0 } } };
expectType<TestIndexerProcessConfig>(_proc);

expectType<
  TypeEqual<typeof TestHelpers.Addresses.defaultAddress, \`0x\${string}\`>
>(true);
`)
  )
})

describe("Fuel API types", () => {
  it("resolves config-bound Fuel chain/contract name and id unions", _ =>
    checkFuel(`
import type { FuelChainId, FuelChainName, FuelContractName } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<FuelChainId, 0>>(true);
expectType<TypeEqual<FuelChainName, "0">>(true);
expectType<TypeEqual<FuelContractName, "Greeter">>(true);

// @ts-expect-error - "NotAContract" is not configured
const _bad: FuelContractName = "NotAContract";
`)
  )

  it("looks up FuelEvent and its Fuel-specific block/transaction", _ =>
    checkFuel(`
import type { FuelChainId, FuelEvent } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type AllEvents = FuelEvent;
expectType<TypeEqual<AllEvents["contractName"], "Greeter">>(true);

type NewGreeting = FuelEvent<"Greeter", "NewGreeting">;
expectType<TypeEqual<NewGreeting["contractName"], "Greeter">>(true);
expectType<TypeEqual<NewGreeting["eventName"], "NewGreeting">>(true);
expectType<TypeEqual<NewGreeting["chainId"], FuelChainId>>(true);
expectType<TypeEqual<NewGreeting["logIndex"], number>>(true);
expectType<TypeEqual<NewGreeting["srcAddress"], \`0x\${string}\`>>(true);

// Fuel blocks are keyed by height (not number) and carry an id + time.
expectType<TypeEqual<NewGreeting["block"]["height"], number>>(true);
expectType<TypeEqual<NewGreeting["block"]["id"], string>>(true);
expectType<TypeEqual<NewGreeting["block"]["time"], number>>(true);
expectType<TypeEqual<NewGreeting["transaction"]["id"], string>>(true);
`)
  )

  it("shapes Fuel onEvent / contractRegister options, handlers and contexts", _ =>
    checkFuel(`
import type {
  Account,
  Address,
  FuelContractRegisterContext,
  FuelContractRegisterHandler,
  FuelContractRegisterOptions,
  FuelEvent,
  FuelOnEventContext,
  FuelOnEventHandler,
  FuelOnEventOptions,
  FuelOnEventWhere,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type NewGreeting = FuelEvent<"Greeter", "NewGreeting">;

// Fuel has no indexed params, so the eventFilters lookup resolves to {}.
expectType<
  TypeEqual<
    FuelOnEventOptions<NewGreeting>,
    {
      readonly contract: "Greeter";
      readonly event: "NewGreeting";
      readonly wildcard?: boolean;
      readonly where?: FuelOnEventWhere<{}, "Greeter">;
    }
  >
>(true);

expectType<
  TypeEqual<
    FuelContractRegisterOptions<NewGreeting>,
    FuelOnEventOptions<NewGreeting>
  >
>(true);

expectType<
  TypeEqual<
    FuelOnEventHandler<NewGreeting>,
    (args: { event: NewGreeting; context: FuelOnEventContext }) => Promise<void>
  >
>(true);
expectType<
  TypeEqual<
    FuelContractRegisterHandler<NewGreeting>,
    (args: {
      event: NewGreeting;
      context: FuelContractRegisterContext;
    }) => Promise<void>
  >
>(true);

expectType<TypeEqual<FuelOnEventContext["chain"]["id"], 0>>(true);
expectType<TypeEqual<FuelOnEventContext["chain"]["isRealtime"], boolean>>(true);
expectType<
  TypeEqual<FuelOnEventContext["Account"]["set"], (entity: Account) => void>
>(true);

expectType<TypeEqual<FuelContractRegisterContext["chain"]["id"], 0>>(true);
expectType<
  TypeEqual<
    FuelContractRegisterContext["chain"]["Greeter"]["add"],
    (address: Address) => void
  >
>(true);
`)
  )

  it("keys the Fuel onBlock / where surface on block.height", _ =>
    checkFuel(`
import type {
  Address,
  FuelChainId,
  FuelOnBlockContext,
  FuelOnBlockFilter,
  FuelOnBlockHandler,
  FuelOnBlockHandlerArgs,
  FuelOnBlockOptions,
  FuelOnBlockWhereArgs,
  FuelOnBlockWhereResult,
  FuelOnEvent,
  FuelOnEventContext,
  FuelOnEventWhere,
  FuelOnEventWhereArgs,
  FuelOnEventWhereChain,
  FuelOnEventWhereFilter,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<FuelOnBlockContext, FuelOnEventContext>>(true);

// FuelOnEvent is the config-generic form behind the FuelEvent alias.
expectType<TypeEqual<FuelOnEvent["contractName"], "Greeter">>(true);

const _fBlockOpts: FuelOnBlockOptions = {
  name: "b",
  where: ({ chain }) => (chain.id === 0 ? true : false),
};
expectType<FuelOnBlockOptions>(_fBlockOpts);

// The Fuel where-callback surface mirrors EVM but filters on block.height.
expectType<TypeEqual<FuelOnEventWhereChain<"Greeter">["id"], number>>(true);
expectType<
  TypeEqual<
    FuelOnEventWhereArgs<"Greeter">["chain"]["Greeter"]["addresses"],
    readonly Address[]
  >
>(true);
const _fFilter: FuelOnEventWhereFilter<{}> = { block: { height: { _gte: 1 } } };
expectType<FuelOnEventWhereFilter<{}>>(_fFilter);
expectType<
  TypeEqual<FuelOnBlockHandlerArgs["block"], { readonly height: number }>
>(true);
expectType<TypeEqual<FuelOnBlockHandlerArgs["context"], FuelOnBlockContext>>(true);
expectType<
  TypeEqual<FuelOnBlockHandler, (args: FuelOnBlockHandlerArgs) => Promise<void>>
>(true);
expectType<TypeEqual<FuelOnBlockWhereArgs["chain"]["id"], FuelChainId>>(true);
expectType<TypeEqual<FuelOnBlockWhereResult, boolean | FuelOnBlockFilter>>(true);

const _ok: FuelOnBlockFilter = {
  block: { height: { _gte: 1, _lte: 10, _every: 2 } },
};
expectType<FuelOnBlockFilter>(_ok);

// Fuel event filters narrow block.height with _gte only.
const _where: FuelOnEventWhere<{}, "Greeter"> = {
  block: { height: { _gte: 1 } },
};
expectType<FuelOnEventWhere<{}, "Greeter">>(_where);
`)
  )

  it("guards the Fuel indexer registration surface", _ =>
    checkFuel(`
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

if (0) {
  indexer.onEvent(
    // @ts-expect-error - "BadContract" is not a configured contract
    { contract: "BadContract", event: "X" },
    async () => {},
  );
  indexer.onEvent(
    // @ts-expect-error - "BadEvent" is not an event of Greeter
    { contract: "Greeter", event: "BadEvent" },
    async () => {},
  );
  indexer.onEvent(
    { contract: "Greeter", event: "NewGreeting" },
    async ({ event }) => {
      expectType<TypeEqual<typeof event.contractName, "Greeter">>(true);
    },
  );
  indexer.contractRegister(
    { contract: "Greeter", event: "ClearGreeting" },
    async ({ context }) => {
      context.chain.Greeter.add("0x0");
    },
  );
  indexer.onBlock(
    { name: "fuelBlock", where: ({ chain }) => (chain.id === 0 ? true : false) },
    async ({ block }) => {
      expectType<TypeEqual<typeof block.height, number>>(true);
    },
  );
  indexer.onEvent(
    {
      contract: "Greeter",
      event: "NewGreeting",
      wildcard: true,
      // @ts-expect-error - Fuel keys block by \`height\`, not \`number\`.
      where: { block: { number: { _gte: 1 } } },
    },
    async () => {},
  );
}
`)
  )
})

describe("SVM API types", () => {
  it("resolves config-bound SVM chain name and id unions", _ =>
    checkSvm(`
import type { SvmChainId, SvmChainName } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<SvmChainId, 0>>(true);
expectType<TypeEqual<SvmChainName, "0">>(true);
`)
  )

  it("shapes the onSlot surface", _ =>
    checkSvm(`
import type {
  Account,
  SvmChainId,
  SvmOnSlotContext,
  SvmOnSlotFilter,
  SvmOnSlotHandler,
  SvmOnSlotHandlerArgs,
  SvmOnSlotOptions,
  SvmOnSlotWhereArgs,
  SvmOnSlotWhereResult,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<SvmOnSlotContext["chain"]["id"], SvmChainId>>(true);

const _slotOpts: SvmOnSlotOptions = {
  name: "s",
  where: ({ chain }) => (chain.id === 0 ? true : false),
};
expectType<SvmOnSlotOptions>(_slotOpts);
expectType<TypeEqual<SvmOnSlotContext["isPreload"], boolean>>(true);
expectType<
  TypeEqual<SvmOnSlotContext["Account"]["set"], (entity: Account) => void>
>(true);

expectType<TypeEqual<SvmOnSlotHandlerArgs["slot"], number>>(true);
expectType<TypeEqual<SvmOnSlotHandlerArgs["context"], SvmOnSlotContext>>(true);
expectType<
  TypeEqual<SvmOnSlotHandler, (args: SvmOnSlotHandlerArgs) => Promise<void>>
>(true);

expectType<TypeEqual<SvmOnSlotWhereArgs["chain"]["id"], SvmChainId>>(true);
expectType<TypeEqual<SvmOnSlotWhereResult, boolean | SvmOnSlotFilter>>(true);

const _ok: SvmOnSlotFilter = { slot: { _gte: 1, _lte: 10, _every: 2 } };
const _empty: SvmOnSlotFilter = {};
expectType<SvmOnSlotFilter>(_ok);
expectType<SvmOnSlotFilter>(_empty);
`)
  )

  it("shapes the config-independent instruction named types", _ =>
    checkSvm(`
import type {
  SvmInstruction,
  SvmInstructionBlock,
  SvmInstructionParams,
  SvmLog,
  SvmTokenBalance,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<SvmInstruction["programName"], string>>(true);
expectType<TypeEqual<SvmInstruction["instructionName"], string>>(true);
expectType<TypeEqual<SvmInstruction["programId"], string>>(true);
expectType<TypeEqual<SvmInstruction["data"], string>>(true);
expectType<TypeEqual<SvmInstruction["accounts"], readonly string[]>>(true);
expectType<TypeEqual<SvmInstruction["isInner"], boolean>>(true);
expectType<TypeEqual<SvmInstruction["params"], SvmInstructionParams | undefined>>(true);

expectType<TypeEqual<SvmInstructionParams["name"], string>>(true);
expectType<TypeEqual<SvmInstructionParams["args"], unknown>>(true);
expectType<
  TypeEqual<SvmInstructionParams["accounts"], Readonly<Record<string, string>>>
>(true);
expectType<
  TypeEqual<SvmInstructionParams["extraAccounts"], readonly string[]>
>(true);

expectType<TypeEqual<SvmInstructionBlock["slot"], number>>(true);
expectType<TypeEqual<SvmInstructionBlock["hash"], string>>(true);
expectType<TypeEqual<SvmInstructionBlock["time"], number | undefined>>(true);

expectType<TypeEqual<SvmLog, { readonly kind: string; readonly message: string }>>(true);
expectType<TypeEqual<SvmTokenBalance["mint"], string | undefined>>(true);
`)
  )

  it("shapes onInstruction options / handler and narrows params from config", _ =>
    checkSvm(`
import type {
  SvmOnInstructionHandler,
  SvmOnInstructionHandlerArgs,
  SvmOnInstructionOptions,
  SvmOnSlotContext,
  SvmTransaction,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<
  TypeEqual<
    SvmOnInstructionOptions<"Swapper", "swap">,
    { readonly program: "Swapper"; readonly instruction: "swap" }
  >
>(true);
expectType<
  TypeEqual<SvmOnInstructionHandlerArgs["context"], SvmOnSlotContext>
>(true);
expectType<
  TypeEqual<
    SvmOnInstructionHandler,
    (args: SvmOnInstructionHandlerArgs) => Promise<void>
  >
>(true);

// The configured instruction selects the signatures transaction field.
expectType<TypeEqual<SvmTransaction["signatures"], readonly string[]>>(true);
`)
  )

  it("guards the SVM indexer registration surface", _ =>
    checkSvm(`
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

if (0) {
  indexer.onSlot(
    { name: "everySlot", where: ({ chain }) => (chain.id === 0 ? true : false) },
    async ({ slot }) => {
      expectType<TypeEqual<typeof slot, number>>(true);
    },
  );
  indexer.onInstruction(
    // @ts-expect-error - "BadProgram" is not a configured program
    { program: "BadProgram", instruction: "swap" },
    async () => {},
  );
  indexer.onInstruction(
    { program: "Swapper", instruction: "swap" },
    async ({ instruction }) => {
      expectType<TypeEqual<typeof instruction.programName, string>>(true);
      if (instruction.params) {
        expectType<TypeEqual<typeof instruction.params.args.amountIn, string>>(true);
        expectType<TypeEqual<typeof instruction.params.accounts.source, string>>(true);
      }
    },
  );
}
`)
  )
})

describe("Effect and utility types", () => {
  it("infers createEffect input/output and Effect handles", _ =>
    check(`
import { createEffect, S } from "envio";
import type {
  Effect,
  EffectArgs,
  EffectCaller,
  EffectChain,
  EffectContext,
  EffectOptions,
  Logger,
  RateLimit,
  RateLimitDuration,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const getBalance = createEffect(
  {
    name: "getBalance",
    input: { address: S.address, blockNumber: S.optional(S.bigint) },
    output: S.bigint,
    rateLimit: false,
  },
  async ({ input, context }) => {
    expectType<
      TypeEqual<
        typeof input,
        { address: \`0x\${string}\`; blockNumber?: bigint | undefined }
      >
    >(true);
    expectType<TypeEqual<typeof context.log, Logger>>(true);
    expectType<TypeEqual<typeof context.effect, EffectCaller>>(true);
    expectType<TypeEqual<typeof context.chain, EffectChain>>(true);
    // @ts-expect-error - input is required for a non-undefined schema
    await context.effect(getBalance, undefined);
    return input.blockNumber ?? 0n;
  },
);

expectType<
  TypeEqual<
    typeof getBalance,
    Effect<{ address: \`0x\${string}\`; blockNumber?: bigint | undefined }, bigint>
  >
>(true);

// Ecosystem-agnostic surface aliases.
expectType<TypeEqual<EffectContext["cache"], boolean>>(true);
expectType<TypeEqual<EffectArgs<number>["input"], number>>(true);
expectType<TypeEqual<EffectChain["id"], number>>(true);
const _rlOff: RateLimit = false;
const _rl: RateLimit = { calls: 1, per: "second" };
const _dur: RateLimitDuration = "minute";
expectType<RateLimit>(_rlOff);
expectType<RateLimit>(_rl);
expectType<RateLimitDuration>(_dur);
expectType<TypeEqual<EffectOptions<number, string>["name"], string>>(true);
expectType<TypeEqual<EffectOptions<number, string>["rateLimit"], RateLimit>>(true);
`)
  )

  it("shapes getWhere filters, the dynamic where callback, and misc aliases", _ =>
    check(`
import type {
  Account,
  Address,
  EvmOnEventWhere,
  EvmOnEventWhereArgs,
  EvmOnEventWhereFilter,
  GetWhereFilter,
  GetWhereOperator,
  Logger,
  SingleOrMultiple,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

// getWhere operators/filters over an entity type.
const _op: GetWhereOperator<bigint> = { _gte: 1n, _in: [1n, 2n] };
expectType<GetWhereOperator<bigint>>(_op);
const _filter: GetWhereFilter<Account> = { balance: { _gt: 0n }, id: { _eq: "x" } };
expectType<GetWhereFilter<Account>>(_filter);

// The dynamic where callback form exposes the event's own contract addresses.
type Args = EvmOnEventWhereArgs<"Token">;
expectType<TypeEqual<Args["chain"]["id"], number>>(true);
expectType<
  TypeEqual<Args["chain"]["Token"]["addresses"], readonly Address[]>
>(true);
const _cb: EvmOnEventWhere<{}, "Token"> = ({ chain }) =>
  chain.id === 1 ? true : { block: { number: { _gte: 1 } } };
expectType<EvmOnEventWhere<{}, "Token">>(_cb);
const _staticFilter: EvmOnEventWhereFilter<{}> = { block: { number: { _gte: 1 } } };
expectType<EvmOnEventWhereFilter<{}>>(_staticFilter);

// SingleOrMultiple accepts a value or a readonly array of it.
const _single: SingleOrMultiple<Address> = "0x0";
const _multi: SingleOrMultiple<Address> = ["0x0", "0x1"];
expectType<SingleOrMultiple<Address>>(_single);
expectType<SingleOrMultiple<Address>>(_multi);

expectType<
  TypeEqual<Logger["info"], (message: string, params?: Record<string, unknown> | Error) => void>
>(true);
`)
  )
})
