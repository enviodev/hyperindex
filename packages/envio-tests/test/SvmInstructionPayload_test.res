open Vitest

let configYaml = `
name: svm-payload
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

let chainId = "0"
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
      instructionAddress: [0],
      programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
      accounts: ["Src111111111111111111111111111111111111111", "Dst111111111111111111111111111111111111111"],
      data: "0x09",
      isInner: false,
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
      "args": None,
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

  it("sets args from a successful decode and leaves them undefined when decode failed", t => {
    let reg = registrations()->Array.getUnsafe(0)
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    let base: SvmHyperSyncClient.EventItems.item = {
      onEventRegistrationIndex: 0,
      slot: 10,
      transactionIndex: 1,
      instructionAddress: [0],
      programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
      accounts: [],
      data: "0x09",
      isInner: false,
    }
    let decoded = SvmHyperSyncSource.toSvmInstruction(
      {...base, decoded: {name: "swap", argsJson: `{"amountIn":"1"}`, accountsJson: "{}", extraAccounts: []}},
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    let failed = SvmHyperSyncSource.toSvmInstruction(
      base,
      ~programName="Swapper",
      ~instructionName="swap",
      ~eventConfig,
      ~fieldSelection=reg.fieldSelection,
    )
    t.expect((decoded.args, failed.args)).toEqual((Some(%raw(`{"amountIn":"1"}`)), None))
  })

  it("emits an empty logs array when log fields are selected and none are scoped", t => {
    let reg = registrations()->Array.getUnsafe(0)
    let eventConfig =
      reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
    let instruction = SvmHyperSyncSource.toSvmInstruction(
      {
        onEventRegistrationIndex: 0,
        slot: 10,
        transactionIndex: 1,
        instructionAddress: [0],
        programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
        accounts: [],
        data: "0x09",
        isInner: false,
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
        instructionAddress: [0],
        programId: "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8",
        accounts: [],
        data: "0x09",
        isInner: false,
        logs: [{kind: "data", message: "hello"}],
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

let sourceAddr = "So11111111111111111111111111111111111111112"
let destAddr = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
let closedAddr = "9n4nbM75f5Ui33ZbPYXn59EwSgE8CGsHtAeTH5YFeJ9E"
let mintAddr = "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
let ownerAddr = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let programId = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"
let slot = 5

describe("SVM activity join through the store", () => {
  Async.it(
    "materializes activity rows and shares them onto named accounts",
    async t => {
      let reg = registrations()->Array.getUnsafe(0)
      let eventConfig =
        reg.eventConfig->(Utils.magic: Internal.eventConfig => Internal.svmInstructionEventConfig)
      let store = TransactionStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false)
      store->TransactionStore.insertSvmTestPage(
        [{slot, transactionIndex: 0}],
        [
          {
            slot,
            transactionIndex: 0,
            account: sourceAddr,
            accountIndex: 0,
            mint: mintAddr,
            owner: ownerAddr,
            decimals: 6,
            postAmount: 500,
          },
          {
            slot,
            transactionIndex: 0,
            account: closedAddr,
            accountIndex: 2,
            mint: mintAddr,
            owner: ownerAddr,
            decimals: 9,
            preAmount: 700,
          },
        ],
      )

      let instruction = SvmHyperSyncSource.toSvmInstruction(
        {
          onEventRegistrationIndex: 0,
          slot,
          transactionIndex: 0,
          instructionAddress: [0],
          programId,
          accounts: [sourceAddr, destAddr],
          data: "0x09",
          isInner: false,
        },
        ~programName="Swapper",
        ~instructionName="swap",
        ~eventConfig,
        ~fieldSelection=reg.fieldSelection,
      )
      let item = Internal.Event({
        onEventRegistration: reg,
        chainId: 0->ChainId.fromInt,
        blockNumber: slot,
        logIndex: 0,
        orderPath: [0],
        transactionIndex: 0,
        payload: instruction->(Utils.magic: Envio.svmInstruction => Internal.eventPayload),
      })
      let blockStore = BlockStore.fromJs(
        [{blockNumber: slot, blockTimestamp: 1_700_000_000}],
        ~ecosystem=Ecosystem.Svm,
        ~shouldChecksum=false,
      )
      await ChainState.materializePageItems(
        ~items=[item],
        ~transactionStore=Some(store),
        ~blockStore,
      )

      let accounts = instruction.accounts->Option.getOrThrow
      let source = accounts->Dict.getUnsafe("source")
      let destination = accounts->Dict.getUnsafe("destination")
      let activities = instruction.transaction->Option.flatMap(tx => tx.accountActivities)
      let opened = activities->Option.flatMap(rows =>
        rows->Array.find(a => a.address->SvmTypes.Pubkey.toString === sourceAddr)
      )
      let closed = activities->Option.flatMap(rows =>
        rows->Array.find(a => a.address->SvmTypes.Pubkey.toString === closedAddr)
      )
      t.expect({
        "namedWithoutRow": destination.activity,
        "sourceSameObject": source.activity === opened,
        "lamportsUnchanged": opened->Option.flatMap(a => a.lamports),
        "openedPreAmount": opened->Option.flatMap(a => a.token)->Option.flatMap(t => t.preAmount),
        "openedPostAmount": opened->Option.flatMap(a => a.token)->Option.flatMap(t => t.postAmount),
        "closedPreAmount": closed->Option.flatMap(a => a.token)->Option.flatMap(t => t.preAmount),
        "closedPostAmount": closed->Option.flatMap(a => a.token)->Option.flatMap(t => t.postAmount),
        "activityCount": activities->Option.map(Array.length),
        "logs": instruction.logs,
        "path": instruction.path,
        "discriminator": instruction.discriminator,
        "time": instruction.block->Option.flatMap(b => b.time),
      }).toEqual({
        "namedWithoutRow": None,
        "sourceSameObject": true,
        "lamportsUnchanged": None,
        "openedPreAmount": None,
        "openedPostAmount": Some(500n),
        "closedPreAmount": Some(700n),
        "closedPostAmount": None,
        "activityCount": Some(2),
        "logs": Some([]),
        "path": Some([0]),
        "discriminator": "0x09",
        "time": Some(1_700_000_000),
      })
    },
  )
})
