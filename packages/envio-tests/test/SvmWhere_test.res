open Vitest

let sourcePk = "So11111111111111111111111111111111111111112"
let destPk = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"

let configYaml = `
name: svm-where
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
              accounts:
                - source
                - destination
`

let parsed = InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~registerHandlers=true,
  ~configYaml,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction({ program: "Swapper", instruction: "swap" }, async () => {});

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    where: {
      isInner: false,
      accounts: { source: "${sourcePk}", destination: ["${destPk}", "${sourcePk}"] },
    },
  },
  async () => {},
);

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    where: { accounts: [{ source: ["${sourcePk}"] }, { destination: ["${destPk}"] }] },
  },
  async () => {},
);

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    where: { isInner: true, block: { slot: { _gte: 250000000 } } },
  },
  async () => {},
);

indexer.onInstruction(
  {
    program: "Swapper",
    instruction: "swap",
    where: { accounts: [{}, { source: ["${sourcePk}"] }] },
  },
  async () => {},
);
`,
)

let chainId = "7565164"

let whereOf = index => {
  let registrations =
    parsed.registrations()
    ->Utils.Dict.dangerouslyGetNonOption(chainId)
    ->Option.getOrThrow
    ->((r: HandlerRegister.chainRegistrations) => r.onEventRegistrations)
  let reg =
    registrations
    ->Array.getUnsafe(index)
    ->(Utils.magic: Internal.onEventRegistration => Internal.svmOnEventRegistration)
  {
    "accountFilters": reg.accountFilters->Array.map(group =>
      group->Array.map(filter => {
        "position": filter.position,
        "values": filter.values->SvmTypes.Pubkey.toStrings,
      })
    ),
    "isInner": reg.isInner,
    "startBlock": reg.startBlock,
  }
}

describe("SVM onInstruction where", () => {
  it("leaves the registration unfiltered without a where", t => {
    t.expect(whereOf(0)).toEqual({
      "accountFilters": [],
      "isInner": None,
      "startBlock": None,
    })
  })

  it("resolves named accounts to positions, accepting a single pubkey or a list", t => {
    t.expect(whereOf(1)).toEqual({
      "accountFilters": [
        [
          {"position": 0, "values": [sourcePk]},
          {"position": 1, "values": [destPk, sourcePk]},
        ],
      ],
      "isInner": Some(false),
      "startBlock": None,
    })
  })

  it("turns an array of groups into OR of AND-groups", t => {
    t.expect(whereOf(2)).toEqual({
      "accountFilters": [
        [{"position": 0, "values": [sourcePk]}],
        [{"position": 1, "values": [destPk]}],
      ],
      "isInner": None,
      "startBlock": None,
    })
  })

  it("promotes block.slot._gte to the registration start block", t => {
    t.expect(whereOf(3)).toEqual({
      "accountFilters": [],
      "isInner": Some(true),
      "startBlock": Some(250000000),
    })
  })

  it("collapses a vacuous group to no account filter", t => {
    t.expect(whereOf(4)).toEqual({
      "accountFilters": [],
      "isInner": None,
      "startBlock": None,
    })
  })
})
