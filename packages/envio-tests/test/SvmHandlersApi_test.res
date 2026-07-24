open Vitest

let configYaml = `
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

let check = handlers => InternalTestIndexer.fromUserApi(~schema=ApiTypesFixtures.schema, ~handlers, ~configYaml)->ignore

describe("SVM API types", () => {
  it("resolves config-bound SVM chain name and id unions", _ =>
    check(`
import type { SvmChainId, SvmChainName } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<SvmChainId, 0>>(true);
expectType<TypeEqual<SvmChainName, "0">>(true);
`)
  )

  it("shapes the onSlot surface", _ =>
    check(`
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
expectType<
  TypeEqual<
    SvmOnSlotContext["Account"]["get"],
    (id: string) => Promise<Account | undefined>
  >
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
    check(`
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
expectType<TypeEqual<SvmInstruction["instructionAddress"], readonly number[]>>(true);
expectType<TypeEqual<SvmInstruction["d1"], string | undefined>>(true);
expectType<TypeEqual<SvmInstruction["d8"], string | undefined>>(true);
expectType<TypeEqual<SvmInstruction["logs"], readonly SvmLog[] | undefined>>(true);
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
    check(`
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

// The configured instruction selects the signatures transaction field;
// unselected fields carry the FieldNotSelected sentinel.
type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;
expectType<TypeEqual<SvmTransaction["signatures"], readonly string[]>>(true);
expectType<IsNotSelected<SvmTransaction["feePayer"]>>(true);
`)
  )

  it("guards the SVM indexer registration surface", _ =>
    check(`
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
    // @ts-expect-error - "badInstr" is not an instruction of Swapper
    { program: "Swapper", instruction: "badInstr" },
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

  it("binds schema entities and enums under an SVM config", _ =>
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
