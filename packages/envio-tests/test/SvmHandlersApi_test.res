open Vitest

let configYaml = `
name: svm-api-types
ecosystem: svm
chains:
  - id: solana
    start_block: 0
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
  - id: solana
    start_block: 0
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
      instruction: ["args", "accounts", "accountArguments", "programId", "data", "path", "isInner"],
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
    instruction.path;
    instruction.programId;
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
      \`Invalid "logs" key in the fields option of the "swap" event registration on contract "Swapper". Valid keys: "instruction", "transaction", "accountActivity", "block", "log".\`,
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
      \`Invalid "accountActivities" field in the fields.transaction option of the "swap" event registration on contract "Swapper". Valid transaction fields: "transactionIndex", "signature", "feePayer", "success", "err", "fee", "computeUnitsConsumed", "accountKeys", "recentBlockhash", "version", "allSignatures".\`,
    );
  });

  it("rejects a parent name in place of its subfields", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "swap",
          fields: { accountActivity: ["token" as never] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "token" field in the fields.accountActivity option of the "swap" event registration on contract "Swapper". Valid accountActivity fields: "address", "transactionAccountIndex", "isSigner", "isWritable", "lamports.pre", "lamports.post", "token.mint", "token.owner", "token.decimals", "token.preAmount", "token.postAmount".\`,
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
      \`Invalid "params" field in the fields.instruction option of the "swap" event registration on contract "Swapper". Valid instruction fields: "args", "accounts", "accountArguments", "programId", "data", "path", "isInner".\`,
    );
  });

  it("rejects discriminator as a selectable instruction field", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "swap",
          fields: { instruction: ["discriminator" as never] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "discriminator" field in the fields.instruction option of the "swap" event registration on contract "Swapper". Valid instruction fields: "args", "accounts", "accountArguments", "programId", "data", "path", "isInner".\`,
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

expectType<TypeEqual<SvmChainId, 7565164>>(true);
expectType<TypeEqual<SvmChainName, "7565164">>(true);
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
  where: ({ chain }) => (chain.id === 7565164 ? true : false),
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
  SvmAllAccountActivityFields,
  SvmAllAccountLamportsFields,
  SvmAllAccountTokenActivityFields,
  SvmAllBlockFields,
  SvmAllFieldsSelection,
  SvmAllLogFields,
  SvmBlockFieldName,
  SvmInstruction,
  SvmInstructionAccount,
  SvmTransactionFieldName,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

type NoneSelected = SvmInstruction<{}>;
expectType<TypeEqual<NoneSelected["programName"], string>>(true);
expectType<TypeEqual<NoneSelected["instructionName"], string>>(true);
expectType<TypeEqual<NoneSelected["discriminator"], string>>(true);
expectType<IsNotSelected<NoneSelected["programId"]>>(true);
expectType<IsNotSelected<NoneSelected["data"]>>(true);
expectType<IsNotSelected<NoneSelected["path"]>>(true);
expectType<IsNotSelected<NoneSelected["isInner"]>>(true);

expectType<TypeEqual<SvmAllBlockFields["slot"], number>>(true);
expectType<TypeEqual<SvmAllBlockFields["time"], number>>(true);
expectType<TypeEqual<SvmAllAccountTokenActivityFields["mint"], string>>(true);
expectType<
  TypeEqual<
    SvmTransactionFieldName,
    | "transactionIndex"
    | "signature"
    | "feePayer"
    | "success"
    | "err"
    | "fee"
    | "computeUnitsConsumed"
    | "accountKeys"
    | "recentBlockhash"
    | "version"
    | "allSignatures"
  >
>(true);
expectType<
  TypeEqual<SvmBlockFieldName, "slot" | "time" | "hash" | "height" | "parentSlot" | "parentHash">
>(true);

expectType<
  TypeEqual<
    SvmAllLogFields["kind"],
    "invoke" | "success" | "failed" | "consumed" | "log" | "data" | (string & {})
  >
>(true);
expectType<TypeEqual<SvmAllLogFields["message"], string>>(true);

expectType<
  TypeEqual<
    SvmAllAccountActivityFields,
    {
      readonly address: string;
      readonly transactionAccountIndex: number;
      readonly isSigner: boolean;
      readonly isWritable: boolean;
      readonly lamports: SvmAllAccountLamportsFields | undefined;
      readonly token: SvmAllAccountTokenActivityFields | undefined;
    }
  >
>(true);

expectType<
  TypeEqual<
    SvmInstructionAccount<SvmAllFieldsSelection>,
    {
      readonly address: string;
      readonly accountName: string;
      readonly instructionAccountIndex: number;
      readonly activity: SvmAllAccountActivityFields | undefined;
    }
  >
>(true);

const _openKind: SvmAllLogFields["kind"] = "other";
expectType<SvmAllLogFields["kind"]>(_openKind);
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
// @ts-expect-error - instructionAddress was renamed to path
type _Addr = SvmInstruction["instructionAddress"];
// @ts-expect-error - SvmInstructionWithFields is gone
type _With = import("envio").SvmInstructionWithFields;
// @ts-expect-error - SvmInstructionBlock is gone
type _OldBlock = import("envio").SvmInstructionBlock;
// @ts-expect-error - SvmTokenAll is gone
type _TokenAll = import("envio").SvmTokenAll;
// @ts-expect-error - SvmBlockWithoutInstruction is gone
type _Without = import("envio").SvmBlockWithoutInstruction;
`)
  )

  it("generated program table carries only schema args and accounts", _ =>
    check(`
import type { Global, SvmAllTransactionFields } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type Programs = Global extends { config: { svm: { programs: infer P } } } ? P : never;
type Swap = Programs["Swapper"]["swap"];

expectType<TypeEqual<keyof Swap, "args" | "accounts">>(true);
expectType<TypeEqual<Swap["args"], { readonly amountIn: string; readonly minAmountOut: string }>>(true);
expectType<TypeEqual<Swap["accounts"], { readonly source: string; readonly destination: string }>>(true);
// @ts-expect-error - transaction is not config-bound; handler fields.transaction selects it
type _Tx = Swap["transaction"];
// @ts-expect-error - block is not config-bound; handler fields.block selects it
type _Block = Swap["block"];

expectType<TypeEqual<SvmAllTransactionFields["signature"], string>>(true);
expectType<TypeEqual<keyof SvmAllTransactionFields, "transactionIndex" | "signature" | "feePayer" | "success" | "err" | "fee" | "computeUnitsConsumed" | "accountKeys" | "recentBlockhash" | "version" | "allSignatures">>(true);
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
      expectType<IsNotSelected<typeof instruction.programId>>(true);
      expectType<IsNotSelected<typeof instruction.data>>(true);
      expectType<IsNotSelected<typeof instruction.path>>(true);
      expectType<IsNotSelected<typeof instruction.isInner>>(true);
      expectType<IsNotSelected<typeof instruction.logs>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.signature>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.accountActivities>>(true);
      expectType<IsNotSelected<typeof instruction.block.hash>>(true);
      expectType<TypeEqual<typeof instruction.block.slot, number>>(true);
      expectType<TypeEqual<typeof instruction.programName, string>>(true);
      expectType<TypeEqual<typeof instruction.instructionName, string>>(true);
      expectType<TypeEqual<typeof instruction.discriminator, string>>(true);
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
import type { FieldNotSelected } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

type NotSelectedActivity<Name extends string> = FieldNotSelected<
  \`Field '\${Name}' is not selected for this handler. Add it to fields.accountActivity in the registration options.\`
>;

if (0) {
  indexer.onInstruction(
    {
      program: "Swapper",
      instruction: "swap",
      fields: {
        instruction: ["args", "accounts", "accountArguments", "programId", "data", "path", "isInner"],
        transaction: ["signature", "accountKeys"],
        accountActivity: ["transactionAccountIndex", "lamports.post", "token.mint"],
        block: ["hash", "time"],
        log: ["kind", "message"],
      },
    },
    async ({ instruction }) => {
      expectType<TypeEqual<typeof instruction.args, { readonly amountIn: string; readonly minAmountOut: string }>>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.address, string>>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.accountName, "source">>(true);
      expectType<TypeEqual<typeof instruction.accounts.source.instructionAccountIndex, number>>(true);
      expectType<TypeEqual<typeof instruction.accountArguments, readonly string[]>>(true);
      expectType<TypeEqual<typeof instruction.discriminator, string>>(true);
      expectType<TypeEqual<typeof instruction.programId, string>>(true);
      expectType<TypeEqual<typeof instruction.data, string>>(true);
      expectType<TypeEqual<typeof instruction.path, readonly number[]>>(true);
      expectType<TypeEqual<typeof instruction.isInner, boolean>>(true);
      expectType<TypeEqual<typeof instruction.transaction.signature, string>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountKeys, readonly string[]>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["address"], string>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["transactionAccountIndex"], number>>(true);
      expectType<IsNotSelected<typeof instruction.transaction.accountActivities[number]["isSigner"]>>(true);
      expectType<
        TypeEqual<
          typeof instruction.transaction.accountActivities[number]["lamports"],
          { readonly pre: NotSelectedActivity<"lamports.pre">; readonly post: bigint } | undefined
        >
      >(true);
      expectType<TypeEqual<typeof instruction.accounts.source.activity, typeof instruction.transaction.accountActivities[number] | undefined>>(true);
      expectType<
        TypeEqual<
          typeof instruction.transaction.accountActivities[number]["token"],
          {
            readonly mint: string;
            readonly owner: NotSelectedActivity<"token.owner">;
            readonly decimals: NotSelectedActivity<"token.decimals">;
            readonly preAmount: NotSelectedActivity<"token.preAmount">;
            readonly postAmount: NotSelectedActivity<"token.postAmount">;
          } | undefined
        >
      >(true);
      expectType<IsNotSelected<typeof instruction.transaction.feePayer>>(true);
      expectType<TypeEqual<typeof instruction.logs[number]["kind"], "invoke" | "success" | "failed" | "consumed" | "log" | "data" | (string & {})>>(true);
      expectType<TypeEqual<typeof instruction.logs[number]["message"], string>>(true);
      expectType<TypeEqual<typeof instruction.block.hash, string>>(true);
      expectType<TypeEqual<typeof instruction.block.time, number>>(true);
      expectType<TypeEqual<typeof instruction.block.slot, number>>(true);
      expectType<IsNotSelected<typeof instruction.block.height>>(true);
    },
  );
}
`)
  )

  it("types standalone handler helpers via required fields selection", _ =>
    check(`
import { indexer } from "envio";
import type {
  SvmAllBlockFields,
  SvmAllFieldsSelection,
  SvmAllTransactionFields,
  SvmFieldsSelection,
  SvmInstruction,
  SvmOnInstructionHandler,
  SvmOnInstructionHandlerArgs,
  SvmTransaction,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

type IsNotSelected<T> = T extends { readonly __fieldNotSelected: string }
  ? true
  : false;

const fields = {
  instruction: ["args", "programId"],
  transaction: ["signature"],
  log: ["message"],
} as const satisfies SvmFieldsSelection;

const handle = async (
  instruction: SvmInstruction<typeof fields, "Swapper", "swap">,
) => {
  expectType<TypeEqual<typeof instruction.args, { readonly amountIn: string; readonly minAmountOut: string }>>(true);
  expectType<TypeEqual<typeof instruction.programId, string>>(true);
  expectType<TypeEqual<typeof instruction.transaction.signature, string>>(true);
  expectType<TypeEqual<typeof instruction.logs[number]["message"], string>>(true);
  expectType<IsNotSelected<typeof instruction.logs[number]["kind"]>>(true);
  expectType<IsNotSelected<typeof instruction.accounts>>(true);
  expectType<IsNotSelected<typeof instruction.transaction.fee>>(true);
};

const handleSwap: SvmOnInstructionHandler<typeof fields, "Swapper", "swap"> =
  async ({ instruction, context }) => {
    expectType<TypeEqual<typeof instruction.args, { readonly amountIn: string; readonly minAmountOut: string }>>(true);
    expectType<TypeEqual<typeof context.isPreload, boolean>>(true);
    await handle(instruction);
  };

expectType<
  TypeEqual<
    Parameters<typeof handleSwap>[0],
    SvmOnInstructionHandlerArgs<typeof fields, "Swapper", "swap">
  >
>(true);

if (0) {
  indexer.onInstruction(
    { program: "Swapper", instruction: "swap", fields },
    handleSwap,
  );
  indexer.onInstruction(
    { program: "Swapper", instruction: "swap", fields },
    async ({ instruction }) => handle(instruction),
  );
}

// Without program/instruction names, args stay unknown and accounts unnamed.
type Unbound = SvmInstruction<typeof fields>;
expectType<TypeEqual<Unbound["args"], unknown>>(true);

type AllInstr = SvmInstruction<SvmAllFieldsSelection, "Swapper", "swap">;
expectType<TypeEqual<AllInstr["data"], string>>(true);
expectType<TypeEqual<AllInstr["isInner"], boolean>>(true);
expectType<TypeEqual<AllInstr["transaction"]["fee"], bigint>>(true);
expectType<TypeEqual<AllInstr["block"]["height"], number>>(true);
expectType<TypeEqual<AllInstr["accounts"]["source"]["accountName"], "source">>(true);
expectType<TypeEqual<AllInstr["transaction"]["accountActivities"][number]["lamports"], { readonly pre: bigint; readonly post: bigint } | undefined>>(true);
expectType<TypeEqual<AllInstr["transaction"]["accountActivities"][number]["token"], { readonly mint: string; readonly owner: string; readonly decimals: number; readonly preAmount: bigint | undefined; readonly postAmount: bigint | undefined } | undefined>>(true);

type Tx = SvmTransaction<{ transaction: ["signature"] }>;
expectType<TypeEqual<Tx["signature"], string>>(true);
expectType<IsNotSelected<Tx["feePayer"]>>(true);

expectType<TypeEqual<SvmAllTransactionFields["fee"], bigint>>(true);
expectType<TypeEqual<SvmAllBlockFields["parentHash"], string>>(true);

// @ts-expect-error - fields selection is required
type _bare = SvmInstruction;
// @ts-expect-error - unknown program name
type _badProg = SvmInstruction<typeof fields, "Nope", "swap">;
// @ts-expect-error - unknown instruction name
type _badInstr = SvmInstruction<typeof fields, "Swapper", "nope">;
`)
  )

  it("exposes payload types that match the inferred handler payload", _ =>
    check(`
import { indexer } from "envio";
import type {
  SvmAccountActivity,
  SvmAccountLamports,
  SvmAccountTokenActivity,
  SvmAllAccountActivityFields,
  SvmAllAccountLamportsFields,
  SvmAllAccountTokenActivityFields,
  SvmAllBlockFields,
  SvmAllFieldsSelection,
  SvmAllLogFields,
  SvmBlock,
  SvmFieldsSelection,
  FieldNotSelected,
  SvmInstruction,
  SvmInstructionAccount,
  SvmLog,
  SvmTransaction,
} from "envio";
import { expectType, type TypeEqual } from "ts-expect";

const fields = {
  instruction: ["args", "accounts"],
  transaction: ["signature"],
  accountActivity: ["isSigner", "lamports.post", "token.mint"],
  block: ["hash"],
  log: ["message"],
} as const satisfies SvmFieldsSelection;

type NotSelectedActivity<Name extends string> = FieldNotSelected<
  \`Field '\${Name}' is not selected for this handler. Add it to fields.accountActivity in the registration options.\`
>;

if (0) {
  indexer.onInstruction(
    { program: "Swapper", instruction: "swap", fields },
    async ({ instruction }) => {
      expectType<TypeEqual<typeof instruction, SvmInstruction<typeof fields, "Swapper", "swap">>>(true);
      expectType<TypeEqual<typeof instruction.transaction, SvmTransaction<typeof fields>>>(true);
      expectType<TypeEqual<typeof instruction.block, SvmBlock<typeof fields>>>(true);
      expectType<TypeEqual<typeof instruction.logs[number], SvmLog<typeof fields>>>(true);
      expectType<TypeEqual<typeof instruction.accounts.source, SvmInstructionAccount<typeof fields, "source">>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number], SvmAccountActivity<typeof fields>>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["lamports"], SvmAccountLamports<typeof fields>>>(true);
      expectType<TypeEqual<typeof instruction.transaction.accountActivities[number]["token"], SvmAccountTokenActivity<typeof fields>>>(true);
    },
  );
}

// SvmAllFieldsSelection selects every field, so each narrowed view widens back
// to its full record.
expectType<TypeEqual<SvmAccountActivity<SvmAllFieldsSelection>, SvmAllAccountActivityFields>>(true);
expectType<TypeEqual<SvmAccountLamports<SvmAllFieldsSelection>, SvmAllAccountLamportsFields | undefined>>(true);
expectType<TypeEqual<SvmAccountTokenActivity<SvmAllFieldsSelection>, SvmAllAccountTokenActivityFields | undefined>>(true);
expectType<TypeEqual<SvmBlock<SvmAllFieldsSelection>, SvmAllBlockFields>>(true);
expectType<TypeEqual<SvmLog<SvmAllFieldsSelection>, SvmAllLogFields>>(true);
expectType<TypeEqual<SvmTransaction<SvmAllFieldsSelection>["fee"], bigint>>(true);

// lamports and token narrow the same way: each subfield is named in full,
// unlisted ones carry the brand naming them, and listing them all rebuilds the
// record.
expectType<
  TypeEqual<
    SvmAccountLamports<{ accountActivity: ["lamports.post"] }>,
    { readonly pre: NotSelectedActivity<"lamports.pre">; readonly post: bigint } | undefined
  >
>(true);
expectType<TypeEqual<SvmAccountLamports<{ accountActivity: ["lamports.pre", "lamports.post"] }>, SvmAllAccountLamportsFields | undefined>>(true);
expectType<
  TypeEqual<
    SvmAccountTokenActivity<{ accountActivity: ["token.mint"] }>,
    {
      readonly mint: string;
      readonly owner: NotSelectedActivity<"token.owner">;
      readonly decimals: NotSelectedActivity<"token.decimals">;
      readonly preAmount: NotSelectedActivity<"token.preAmount">;
      readonly postAmount: NotSelectedActivity<"token.postAmount">;
    } | undefined
  >
>(true);
expectType<
  TypeEqual<
    SvmAccountTokenActivity<{
      accountActivity: ["token.mint", "token.owner", "token.decimals", "token.preAmount", "token.postAmount"];
    }>,
    SvmAllAccountTokenActivityFields | undefined
  >
>(true);

// An account with no accountActivity selection still names its account.
expectType<
  TypeEqual<
    SvmInstructionAccount<{ instruction: ["accounts"] }, "source">,
    {
      readonly address: string;
      readonly accountName: "source";
      readonly instructionAccountIndex: number;
      readonly activity:
        | FieldNotSelected<"Field 'activity' is not selected for this handler. Add fields.accountActivity in the registration options.">
        | undefined;
    }
  >
>(true);

// @ts-expect-error - fields selection is required
type _bareAccount = SvmInstructionAccount;
// @ts-expect-error - fields selection is required
type _bareLamports = SvmAccountLamports;
`)
  )

  it("shapes the selection vocabulary and registration options", _ =>
    check(`
import type {
  SvmAccountActivityFieldName,
  SvmAllFieldsSelection,
  SvmAllLogFields,
  SvmFieldsSelection,
  SvmInstructionFieldName,
  SvmLogFieldName,
  SvmLogKind,
  SvmOnInstructionOptions,
} from "envio";
import { indexer } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

expectType<
  TypeEqual<
    SvmInstructionFieldName,
    "args" | "accounts" | "accountArguments" | "programId" | "data" | "path" | "isInner"
  >
>(true);
expectType<
  TypeEqual<
    SvmAccountActivityFieldName,
    | "address"
    | "transactionAccountIndex"
    | "isSigner"
    | "isWritable"
    | "lamports.pre"
    | "lamports.post"
    | "token.mint"
    | "token.owner"
    | "token.decimals"
    | "token.preAmount"
    | "token.postAmount"
  >
>(true);
expectType<TypeEqual<SvmLogFieldName, "kind" | "message">>(true);
expectType<TypeEqual<SvmAllLogFields["kind"], SvmLogKind>>(true);

const _opts: SvmOnInstructionOptions<"Swapper", "swap", { instruction: ["args"] }> = {
  program: "Swapper",
  instruction: "swap",
  fields: { instruction: ["args"] },
};
expectType<SvmOnInstructionOptions<"Swapper", "swap", { instruction: ["args"] }>>(_opts);

// SvmAllFieldsSelection is a type-level escape hatch: its knobs are field-name
// arrays rather than literals, so it can't stand in for a fields value.
declare const everyField: SvmAllFieldsSelection;
if (0) {
  indexer.onInstruction(
    // @ts-expect-error - fields must be a literal, so the runtime knows what to fetch
    { program: "Swapper", instruction: "swap", fields: everyField },
    async () => {},
  );
}

// Sub-records are selected field by field; the parent name is not a field.
if (0) {
  indexer.onInstruction(
    {
      program: "Swapper",
      instruction: "swap",
      // @ts-expect-error - select token.mint / token.owner / ... explicitly
      fields: { accountActivity: ["token"] },
    },
    async () => {},
  );
  indexer.onInstruction(
    {
      program: "Swapper",
      instruction: "swap",
      // @ts-expect-error - select lamports.pre / lamports.post explicitly
      fields: { accountActivity: ["lamports"] },
    },
    async () => {},
  );
}

// A widened selection is rejected the same way.
const widened: SvmFieldsSelection = { instruction: ["args"] };
if (0) {
  indexer.onInstruction(
    // @ts-expect-error - not written as a literal
    { program: "Swapper", instruction: "swap", fields: widened },
    async () => {},
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
    { name: "everySlot", where: ({ chain }) => (chain.id === 7565164 ? true : false) },
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
