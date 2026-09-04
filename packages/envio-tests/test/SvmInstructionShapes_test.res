open Vitest

// Instruction shapes the ecosystem actually ships: SPL Memo has no
// discriminator and its whole data is the args; Serum v3 dispatches on a
// version byte plus a 4-byte tag, a 5-byte prefix; an Anchor program upgrade
// keeps the discriminator (a hash of the name) while changing the args, so
// two layouts share one prefix. Each is a separate instruction with its own
// registrations, and none of them is a config error.
let parsed = InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~registerHandlers=true,
  ~configYaml=`
name: svm-instruction-shapes
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Memo
          program_id: MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr
          instructions:
            - name: memo
              accounts: []
              args:
                - { name: text, type: string }
        - name: Serum
          program_id: 9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin
          instructions:
            - name: newOrderV3
              discriminator: "0x000a000000"
              accounts:
                - market
              args:
                - { name: side, type: u32 }
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          instructions:
            - name: swapV1
              discriminator: "0x09"
              accounts:
                - source
              args:
                - { name: amountIn, type: u64 }
            - name: swapV2
              discriminator: "0x09"
              accounts:
                - source
              args:
                - { name: amountIn, type: u64 }
                - { name: minAmountOut, type: u64 }
            - name: any
            - name: anyAgain
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  { program: "Memo", instruction: "memo", fields: { instruction: ["args"] } },
  async ({ instruction }) => {
    instruction.args.text satisfies string;
  },
);
indexer.onInstruction(
  { program: "Serum", instruction: "newOrderV3", fields: { instruction: ["args"] } },
  async ({ instruction }) => {
    instruction.args.side satisfies number;
  },
);
indexer.onInstruction(
  { program: "Swapper", instruction: "swapV1", fields: { instruction: ["args"] } },
  async ({ instruction }) => {
    instruction.args.amountIn satisfies bigint;
  },
);
indexer.onInstruction(
  { program: "Swapper", instruction: "swapV2", fields: { instruction: ["args"] } },
  async ({ instruction }) => {
    instruction.args.minAmountOut satisfies bigint;
  },
);
indexer.onInstruction({ program: "Swapper", instruction: "any" }, async () => {});
indexer.onInstruction({ program: "Swapper", instruction: "anyAgain" }, async () => {});
`,
)

describe("SVM instruction shapes", () => {
  it("registers every instruction, whatever its prefix", t => {
    let {HandlerRegister.onEventRegistrations: onEventRegistrations} =
      parsed.registrations()->Dict.valuesToArray->Array.getUnsafe(0)
    let shapes = onEventRegistrations->Array.map(
      reg => {
        let eventConfig =
          reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
        (eventConfig.contractName, eventConfig.name, eventConfig.discriminator)
      },
    )
    t.expect(shapes).toEqual([
      ("Memo", "memo", None),
      ("Serum", "newOrderV3", Some("0x000a000000")),
      ("Swapper", "swapV1", Some("0x09")),
      ("Swapper", "swapV2", Some("0x09")),
      ("Swapper", "any", None),
      ("Swapper", "anyAgain", None),
    ])
  })
})
