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
`

let check = handlers =>
  InternalTestIndexer.fromUserApi(~schema=ApiTypesFixtures.schema, ~handlers, ~configYaml)->ignore

let yamlWithFieldSelection = `
name: svm-yaml-field-selection
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
              field_selection:
                transaction_fields: [signature]
`

InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~configYaml,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    fields: {
      instruction: ["args", "accounts", "accountArguments", "discriminator"],
      transaction: ["signature", "accountKeys"],
      accountActivity: ["transactionAccountIndex", "lamports.post", "token.mint"],
      block: ["hash", "time"],
      log: ["kind", "message"],
    },
  },
  async ({ instruction }) => {
    instruction.args;
    instruction.accounts.source.address;
    instruction.accountArguments;
    instruction.discriminator;
    instruction.transaction.signature;
    instruction.transaction.accountKeys;
    instruction.transaction.accountActivities;
    instruction.accounts.source.activity;
    instruction.logs;
    instruction.block.hash;
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

describe("SVM handler fields", () => {
  it("rejects an empty accountActivity list", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", fields: { accountActivity: [] } },
        async () => {},
      ),
    ).toThrowError(
      \`The fields.accountActivity option of the "swap" event registration on contract "Swapper" must list at least one field.\`,
    );
  });

  it("rejects an empty log list", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", fields: { log: [] } },
        async () => {},
      ),
    ).toThrowError(
      \`The fields.log option of the "swap" event registration on contract "Swapper" must list at least one field.\`,
    );
  });

  it("rejects a misspelled selection key", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", fields: { logs: ["kind"] } as never },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "logs" key in the fields option of the "swap" event registration on contract "Swapper". Valid keys: instruction, transaction, accountActivity, block, log.\`,
    );
  });

  it("rejects listing accountActivities under transaction", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "swap",
          fields: { transaction: ["accountActivities" as never] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "accountActivities" field in the fields.transaction option of the "swap" event registration on contract "Swapper". Valid transaction fields: transactionIndex, signature, feePayer, success, err, fee, computeUnitsConsumed, accountKeys, recentBlockhash, version, allSignatures.\`,
    );
  });

  it("rejects an unknown instruction field", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "swap",
          fields: { instruction: ["params" as never] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "params" field in the fields.instruction option of the "swap" event registration on contract "Swapper". Valid instruction fields: args, accounts, accountArguments, discriminator.\`,
    );
  });
});
`,
)->ignore

describe("SVM YAML field_selection", () => {
  it("rejects field_selection on an instruction", t => {
    let actual = try {
      InternalTestIndexer.fromUserApi(~configYaml=yamlWithFieldSelection)->ignore
      "the parse to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(actual->String.includes("field_selection")).toBe(true)
  })
})

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

  it("shapes the config-independent instruction types", _ =>
    check(`
import type {
  SvmAccountActivity,
  SvmInstruction,
  SvmInstructionAccount,
  SvmInstructionBlock,
  SvmLog,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<TypeEqual<SvmInstruction["programName"], string>>(true);
expectType<TypeEqual<SvmInstruction["instructionName"], string>>(true);
expectType<TypeEqual<SvmInstruction["programId"], string>>(true);
expectType<TypeEqual<SvmInstruction["data"], string>>(true);
expectType<TypeEqual<SvmInstruction["isInner"], boolean>>(true);
expectType<TypeEqual<SvmInstruction["instructionAddress"], readonly number[]>>(true);

expectType<TypeEqual<SvmInstructionBlock["slot"], number>>(true);

expectType<
  TypeEqual<
    SvmLog["kind"],
    "invoke" | "success" | "failed" | "consumed" | "log" | "data" | (string & {})
  >
>(true);
expectType<TypeEqual<SvmLog["message"], string>>(true);

expectType<
  TypeEqual<
    SvmAccountActivity,
    {
      readonly address: string;
      readonly transactionAccountIndex: number;
      readonly isSigner: boolean;
      readonly isWritable: boolean;
      readonly lamports: { readonly pre: bigint; readonly post: bigint } | undefined;
      readonly token: {
        readonly mint: string;
        readonly owner: string;
        readonly decimals: number;
        readonly preAmount: bigint | undefined;
        readonly postAmount: bigint | undefined;
      } | undefined;
    }
  >
>(true);

expectType<
  TypeEqual<
    SvmInstructionAccount,
    {
      readonly address: string;
      readonly accountName: string;
      readonly instructionAccountIndex: number;
      readonly activity: SvmAccountActivity | undefined;
    }
  >
>(true);

const _openKind: SvmLog["kind"] = "other";
expectType<SvmLog["kind"]>(_openKind);
`)
  )

  it("does not export removed payload names", _ =>
    check(`
import type { SvmInstruction } from "envio";

// @ts-expect-error - params is gone
type _Params = SvmInstruction["params"];
// @ts-expect-error - extraAccounts is gone
type _Extra = import("envio").SvmInstructionParams;
// @ts-expect-error - SvmTokenBalance is gone
type _Tb = import("envio").SvmTokenBalance;
// @ts-expect-error - SvmAccount left-join type is gone
type _Acc = import("envio").SvmAccount;
`)
  )

  it("unselected fields are FieldNotSelected when fields is omitted", _ =>
    check(`
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

if (0) {
  indexer.onInstruction(
    { program: "Swapper", instruction: "swap" },
    async ({ instruction }) => {
      expectType<IsNotSelected<typeof instruction.args>>(true);
      expectType<IsNotSelected<typeof instruction.accounts>>(true);
      expectType<IsNotSelected<typeof instruction.accountArguments>>(true);
      expectType<IsNotSelected<typeof instruction.discriminator>>(true);
      expectType<IsNotSelected<typeof instruction.logs>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.signature>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.accountActivities>>(true);
      expectType<IsNotSelected<typeof instruction.block.hash>>(true);
      expectType<TypeEqual<typeof instruction.block.slot, number>>(true);
      expectType<TypeEqual<typeof instruction.programName, string>>(true);
      // @ts-expect-error - d1 is gone from the payload
      instruction.d1;
    },
  );
}
`)
  )

  it("narrows selected handler fields to the spec shapes", _ =>
    check(`
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

if (0) {
  indexer.onInstruction(
    {
      program: "Swapper",
      instruction: "swap",
      fields: {
        instruction: ["args", "accounts", "accountArguments", "discriminator"],
        transaction: ["signature", "accountKeys"],
        accountActivity: ["transactionAccountIndex", "lamports.post", "token.mint"],
        block: ["hash", "time"],
        log: ["kind", "message"],
      },
    },
    async ({ instruction }) => {
      expectType<TypeEqual<typeof instruction.args, { readonly amountIn: string; readonly minAmountOut: string } | undefined>>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.address, string>>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.accountName, "source">>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.instructionAccountIndex, number>>(true);
      expectType<TypeEqual<typeof instruction.accountArguments, readonly string[]>>(true);
      expectType<TypeEqual<typeof instruction.discriminator, string>>(true);
      expectType<TypeEqual<typeof instruction.transaction.signature, string>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountKeys, readonly string[]>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["address"], string>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["transactionAccountIndex"], number>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.accountActivities[number]["isSigner"]>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["lamports"], { readonly post: bigint } | undefined>>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.activity, typeof instruction.transaction.accountActivities[number] | undefined>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["token"], { readonly mint: string } | undefined>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.feePayer>>(true);
      expectType<TypeEqual<typeof instruction.logs[number]["kind"], "invoke" | "success" | "failed" | "consumed" | "log" | "data" | (string & {})>>(true);
      expectType<TypeEqual<typeof instruction.logs[number]["message"], string>>(true);
      expectType<TypeEqual<typeof instruction.block.hash, string>>(true);
      expectType<TypeEqual<typeof instruction.block.time, number | undefined>>(true);
      expectType<TypeEqual<typeof instruction.block.slot, number>>(true);
      expectType<IsNotSelected<typeof instruction.block.height>>(true);
    },
  );
}
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
