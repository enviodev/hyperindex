open Vitest

let files = Dict.fromArray([("abis/greeter-abi.json", FuelAbiFixtures.greeter)])

let configYaml = `
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

let check = handlers => InternalTestIndexer.fromUserApi(~schema=ApiTypesFixtures.schema, ~files, ~handlers, ~configYaml)->ignore

describe("Fuel API types", () => {
  it("resolves config-bound Fuel chain/contract name and id unions", _ =>
    check(`
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
    check(`
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

// Log params decode to the ABI's Sway struct shapes.
expectType<TypeEqual<NewGreeting["params"]["user"]["bits"], string>>(true);
expectType<TypeEqual<NewGreeting["params"]["greeting"]["value"], string>>(true);

type ClearGreeting = FuelEvent<"Greeter", "ClearGreeting">;
expectType<TypeEqual<ClearGreeting["eventName"], "ClearGreeting">>(true);
expectType<TypeEqual<ClearGreeting["params"]["user"]["bits"], string>>(true);
`)
  )

  it("shapes Fuel onEvent / contractRegister options, handlers and contexts", _ =>
    check(`
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

// contractRegister context exposes no entity operations.
// @ts-expect-error - Account ops are not on the Fuel contractRegister context
type _accountOnCr = FuelContractRegisterContext["Account"];
`)
  )

  it("keys the Fuel onBlock / where surface on block.height", _ =>
    check(`
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

// The dynamic callback form returns a filter or a boolean.
const _whereCb: FuelOnEventWhere<{}, "Greeter"> = ({ chain }) =>
  chain.id === 0 ? true : { block: { height: { _gte: 1 } } };
expectType<FuelOnEventWhere<{}, "Greeter">>(_whereCb);
`)
  )

  it("guards the Fuel indexer registration surface", _ =>
    check(`
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

  it("binds schema entities and enums under a Fuel config", _ =>
    check(`
import type { Account, Entity, EntityName, Enum, EnumName } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const _entity: EntityName = "Account";
// @ts-expect-error - "NotAnEntity" is not in the schema
const _badEntity: EntityName = "NotAnEntity";
expectType<TypeEqual<Entity<"Account">, Account>>(true);
expectType<TypeEqual<Entity<"Account">["accountType"], "ADMIN" | "USER">>(true);

const _enum: EnumName = "AccountType";
// @ts-expect-error - "NotAnEnum" is not in the schema
const _badEnum: EnumName = "NotAnEnum";
expectType<TypeEqual<Enum<"GravatarSize">, "SMALL" | "MEDIUM" | "LARGE">>(true);
`)
  )
})
