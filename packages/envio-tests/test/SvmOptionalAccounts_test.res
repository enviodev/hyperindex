open Vitest

let programId = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let payerPk = "So11111111111111111111111111111111111111112"
let authorityPk = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
let skippedPk = "Sysvar1nstructions1111111111111111111111111"
let mintPk = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"

let configYaml = `
name: svm-optional-accounts
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    hypersync_config:
      url: https://solana.hypersync.xyz
programs:
  - name: Swapper
    program_id: ${programId}
    instructions:
      - name: swap
        discriminator: "0x09"
        args: []
        accounts:
          - payer
          - ?authority
          - _
          - mint
`

let parsed = InternalTestIndexer.fromUserApi(
  ~schema=`
type Swap {
  id: ID!
  payer: String!
  authority: String!
  mint: String!
}
`,
  ~registerHandlers=true,
  ~configYaml,
  ~handlers=`
import { indexer } from "envio";
import type { SvmAllFieldsSelection, SvmInstruction, SvmInstructionAccount } from "envio";
import { expectType, type TypeEqual } from "ts-expect";

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    fields: { instruction: ["accounts"] },
  },
  async ({ instruction, context }) => {
    context.Swap.set({
      id: instruction.block.slot.toString(),
      payer: instruction.accounts.payer.address,
      authority: instruction.accounts.authority?.address ?? "absent",
      mint: instruction.accounts.mint.address,
    });
  },
);

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    where: { accounts: { authority: "${authorityPk}", mint: "${mintPk}" } },
  },
  async () => {},
);

type Fields = SvmAllFieldsSelection;
type Accounts = SvmInstruction<Fields, "Swapper", "swap">["accounts"];

expectType<TypeEqual<Accounts["payer"], SvmInstructionAccount<Fields, "payer">>>(true);
expectType<
  TypeEqual<Accounts["authority"], SvmInstructionAccount<Fields, "authority"> | undefined>
>(true);
// @ts-expect-error - an unnamed slot holds a position and surfaces nothing
type _Unnamed = Accounts["_"];
`,
)

let chainId = "7565164"

let registrations = () =>
  parsed.registrations()
  ->Utils.Dict.dangerouslyGetNonOption(chainId)
  ->Option.getOrThrow
  ->((r: HandlerRegister.chainRegistrations) => r.onEventRegistrations)

let namedAccountsOf = accounts => {
  let reg = registrations()->Array.getUnsafe(0)
  let eventConfig =
    reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
  let instruction = SvmHyperSyncSource.toSvmInstruction(
    {
      onEventRegistrationIndex: 0,
      slot: 10,
      transactionIndex: 1,
      path: [0],
      programId,
      accounts,
      data: Uint8Array.fromArray([0x09]),
      isInner: false,
      args: %raw(`{}`),
      logs: Null.null,
    },
    ~programName="Swapper",
    ~instructionName="swap",
    ~eventConfig,
    ~fieldSelection=reg.fieldSelection,
  )
  instruction.accounts
  ->Option.getOrThrow
  ->Dict.toArray
  ->Array.map(((name, account)) => (
    name,
    account.address->SvmTypes.Pubkey.toString,
    account.instructionAccountIndex,
  ))
}

describe("SVM optional and unnamed account slots", () => {
  it("names every declared slot but the unnamed one", t => {
    t.expect(namedAccountsOf([payerPk, authorityPk, skippedPk, mintPk])).toEqual([
      ("payer", payerPk, 0),
      ("authority", authorityPk, 1),
      ("mint", mintPk, 3),
    ])
  })

  // Anchor's convention for an absent optional account: the slot carries the
  // id of the program being invoked.
  it("reads the program id in an optional slot as an absent account", t => {
    t.expect(namedAccountsOf([payerPk, programId, skippedPk, mintPk])).toEqual([
      ("payer", payerPk, 0),
      ("mint", mintPk, 3),
    ])
  })

  it("keeps the program id in a required slot", t => {
    t.expect(namedAccountsOf([programId, authorityPk, skippedPk, mintPk])).toEqual([
      ("payer", programId, 0),
      ("authority", authorityPk, 1),
      ("mint", mintPk, 3),
    ])
  })

  it("drops the slots a short account list never reaches", t => {
    t.expect(namedAccountsOf([payerPk, authorityPk])).toEqual([
      ("payer", payerPk, 0),
      ("authority", authorityPk, 1),
    ])
  })

  it("resolves a filter on an optional account to its declared position", t => {
    let reg =
      registrations()
      ->Array.getUnsafe(1)
      ->(Utils.magic: Internal.onEventRegistration => Internal.svmOnEventRegistration)
    t.expect(
      reg.accountFilters->Array.map(
        group =>
          group->Array.map(filter => (filter.position, filter.values->SvmTypes.Pubkey.toStrings)),
      ),
    ).toEqual([[(1, [authorityPk]), (3, [mintPk])]])
  })
})
