open Vitest

@module("viem")
external encodeAbiParameters: (JSON.t, JSON.t) => string = "encodeAbiParameters"

@module("viem")
external toEventSelector: string => string = "toEventSelector"

// Reproduces https://github.com/enviodev/hyperindex/issues/1285
// An event given a `name:` that differs from its on-chain name must still
// decode over HyperSync. The native decoder rebuilds the inner signature from
// the display `name:` (`reconstruct_signature` in decode.rs), so its topic0
// becomes keccak256("ApprovalRenamed(address,uint256)") and never matches the
// real log's keccak256("Approval(address,uint256)"); the log decodes as null.
let onChainSighash = toEventSelector("event Approval(address owner, uint256 value)")

let owner = "0x000000000000000000000000000000000000aaaa"
let value = 42n

let makeEvent = (~topics: array<string>, ~data: string): HyperSyncClient.ResponseTypes.event =>
  {"log": {"topics": topics, "data": data}}->(
    Utils.magic: {..} => HyperSyncClient.ResponseTypes.event
  )

let approvalLog = makeEvent(
  ~topics=[onChainSighash],
  ~data=encodeAbiParameters(
    %raw(`[{"type":"address"},{"type":"uint256"}]`),
    %raw(`["0x000000000000000000000000000000000000aaaa",42n]`),
  ),
)

describe("Renamed event decoding over HyperSync (issue #1285)", () => {
  Async.it("decodes a renamed event under its real on-chain signature", async t => {
    let decoder = HyperSyncClient.Decoder.fromParams([
      {
        sighash: onChainSighash,
        topicCount: 1,
        eventName: "ApprovalRenamed",
        contractName: "TestContract",
        params: [
          {name: "owner", abiType: "address", indexed: false},
          {name: "value", abiType: "uint256", indexed: false},
        ],
      },
    ])

    let decoded = await decoder.decodeLogs([approvalLog])
    let paramsByContractName = decoded[0]->Option.getUnsafe->Nullable.toOption

    t
    .expect(paramsByContractName)
    .toEqual(
      Some(
        {"TestContract": {"owner": owner, "value": value}}->(
          Utils.magic: {..} => dict<Internal.eventParams>
        ),
      ),
    )
  })
})
