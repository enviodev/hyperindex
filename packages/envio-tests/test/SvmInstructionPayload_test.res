open Vitest

let configYaml = `
name: svm-payload
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

let parsed = InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~registerHandlers=true,
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
      accountActivity: [
        "transactionAccountIndex",
        "lamports.pre",
        "lamports.post",
        "token.mint",
        "token.owner",
        "token.decimals",
        "token.preAmount",
        "token.postAmount",
      ],
      block: ["hash", "time"],
      log: ["kind", "message"],
    },
  },
  async () => {},
);

indexer.onInstruction(
  { program: "Swapper", instruction: "swap", fields: { log: ["kind"] } },
  async () => {},
);
`,
)

let chainId = "7565164"
let registrations = () => {
  let byChain = parsed.registrations()
  byChain
  ->Utils.Dict.dangerouslyGetNonOption(chainId)
  ->Option.getOrThrow
  ->((r: HandlerRegister.chainRegistrations) => r.onEventRegistrations)
}

describe("SVM handler fields registration", () => {
  it("records nested selection on the registration", t => {
    let reg = registrations()->Array.getUnsafe(0)
    let fs = reg.fieldSelection
    t.expect({
      "instruction": fs.instructionFields->Utils.Set.toArray->Array.toSorted(String.compare),
      "transaction": fs.transactionFields->Utils.Set.toArray->Array.toSorted(String.compare),
      "accountActivity": fs.accountActivityFields->Utils.Set.toArray->Array.toSorted(
        String.compare,
      ),
      "block": fs.blockFields->Utils.Set.toArray->Array.toSorted(String.compare),
      "log": fs.logFields->Utils.Set.toArray->Array.toSorted(String.compare),
    }).toEqual({
      "instruction": ["accountArguments", "accounts", "args", "data", "isInner", "path", "programId"],
      "transaction": ["accountActivities", "accountKeys", "signature"],
      "accountActivity": [
        "lamports.post",
        "lamports.pre",
        "token.decimals",
        "token.mint",
        "token.owner",
        "token.postAmount",
        "token.preAmount",
        "transactionAccountIndex",
      ],
      "block": ["hash", "slot", "time"],
      "log": ["kind", "message"],
    })
  })
})

describe("SVM instruction payload assembly", () => {
  it("zips IDL names onto account arguments without an activity row", t => {
    let reg = registrations()->Array.getUnsafe(0)
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    let item: SvmHyperSyncClient.EventItems.item = {
      onEventRegistrationIndex: 0,
      slot: 10,
      transactionIndex: 1,
      path: [0],
      programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
      accounts: ["Src111111111111111111111111111111111111111", "Dst111111111111111111111111111111111111111"],
      data: "0x09",
      isInner: false,
      argsJson: "{}",
      logs: Null.null,
    }
    let instruction = SvmHyperSyncSource.toSvmInstruction(
      item,
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    t.expect({
      "source": instruction.accounts->Option.getOrThrow->Dict.getUnsafe("source"),
      "destination": instruction.accounts->Option.getOrThrow->Dict.getUnsafe("destination"),
      "args": instruction.args,
      "discriminator": instruction.discriminator,
      "path": instruction.path,
      "accountArguments": instruction.accountArguments,
      "hasInstructionAddress": %raw(`Object.prototype.hasOwnProperty.call(instruction, "instructionAddress")`),
    }).toEqual({
      "source": {
        Envio.address: "Src111111111111111111111111111111111111111"->SvmTypes.Pubkey.fromStringUnsafe,
        accountName: "source",
        instructionAccountIndex: 0,
      },
      "destination": {
        Envio.address: "Dst111111111111111111111111111111111111111"->SvmTypes.Pubkey.fromStringUnsafe,
        accountName: "destination",
        instructionAccountIndex: 1,
      },
      "args": Some(%raw(`{}`)),
      "discriminator": "0x09",
      "path": Some([0]),
      "accountArguments": Some(
        [
          "Src111111111111111111111111111111111111111",
          "Dst111111111111111111111111111111111111111",
        ]->SvmTypes.Pubkey.fromStringsUnsafe,
      ),
      "hasInstructionAddress": false,
    })
  })

  it("parses args from the decoded JSON, and reads an undecoded item as empty args", t => {
    let reg = registrations()->Array.getUnsafe(0)
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    let base: SvmHyperSyncClient.EventItems.item = {
      onEventRegistrationIndex: 0,
      slot: 10,
      transactionIndex: 1,
      path: [0],
      programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
      accounts: [],
      data: "0x09",
      isInner: false,
      argsJson: "{}",
      logs: Null.null,
    }
    let decoded = SvmHyperSyncSource.toSvmInstruction(
      {...base, argsJson: `{"amountIn":"1"}`},
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    let undecoded = SvmHyperSyncSource.toSvmInstruction(
      base,
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    t.expect((decoded.args, undecoded.args)).toEqual((
      Some(%raw(`{"amountIn":"1"}`)),
      Some(%raw(`{}`)),
    ))
  })

  // NAPI sends Rust `None` as `null`: an instruction whose logs didn't attach
  // arrives with `logs: null`, not with the key missing.
  it("emits an empty logs array when log fields are selected and the logs are null", t => {
    let reg = registrations()->Array.getUnsafe(0)
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    let instruction = SvmHyperSyncSource.toSvmInstruction(
      {
        onEventRegistrationIndex: 0,
        slot: 10,
        transactionIndex: 1,
        path: [0],
        programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
        accounts: [],
        data: "0x09",
        isInner: false,
        argsJson: "{}",
        logs: Null.null,
      },
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    t.expect(instruction.logs).toEqual(Some([]))
  })

  it("omits unselected log keys on the payload", t => {
    let reg = registrations()->Array.getUnsafe(1)
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    let instruction = SvmHyperSyncSource.toSvmInstruction(
      {
        onEventRegistrationIndex: 0,
        slot: 10,
        transactionIndex: 1,
        path: [0],
        programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
        accounts: [],
        data: "0x09",
        isInner: false,
        argsJson: "{}",
        logs: Null.make([
          {SvmHyperSyncClient.EventItems.kind: Null.make("data"), message: Null.null},
        ]),
      },
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    let log = instruction.logs->Option.getOrThrow->Array.getUnsafe(0)
    t.expect({
      "kind": log.kind,
      "hasMessage": %raw(`Object.prototype.hasOwnProperty.call(log, "message")`),
      "hasKind": %raw(`Object.prototype.hasOwnProperty.call(log, "kind")`),
      "discriminator": instruction.discriminator,
      "hasPath": %raw(`Object.prototype.hasOwnProperty.call(instruction, "path")`),
      "hasProgramId": %raw(`Object.prototype.hasOwnProperty.call(instruction, "programId")`),
    }).toEqual({
      "kind": "data",
      "hasMessage": false,
      "hasKind": true,
      "discriminator": "0x09",
      "hasPath": false,
      "hasProgramId": false,
    })
  })
})

