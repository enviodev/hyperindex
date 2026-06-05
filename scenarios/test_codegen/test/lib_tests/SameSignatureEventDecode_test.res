open Vitest

@module("viem")
external toEventSelector: string => string = "toEventSelector"

@module("viem") external pad: string => string = "pad"

@module("viem")
external encodeAbiParameters: (JSON.t, JSON.t) => string = "encodeAbiParameters"

// Two contracts emit the very same `Transfer(address indexed, address indexed,
// uint256)` event but name the params differently (OpenZeppelin `from/to/value`
// vs WETH `src/dst/wad`). Same sighash, same topicCount.
let transferSighash = toEventSelector("event Transfer(address indexed, address indexed, uint256)")

let makeContract = (~name, ~params): Internal.evmContractConfig => {
  name,
  abi: %raw(`[]`),
  events: [
    EventConfigBuilder.buildEvmEventConfig(
      ~contractName=name,
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params,
      ~isWildcard=false,
      ~handler=None,
      ~contractRegister=None,
      ~eventFilters=None,
      ~probeChainId=1,
      ~onEventBlockFilterSchema=Evm.ecosystem.onEventBlockFilterSchema,
    ),
  ],
}

let tokenA = makeContract(
  ~name="TokenA",
  ~params=([
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]: array<Internal.paramMeta>),
)

let tokenB = makeContract(
  ~name="TokenB",
  ~params=([
    {name: "src", abiType: "address", indexed: true},
    {name: "dst", abiType: "address", indexed: true},
    {name: "wad", abiType: "uint256", indexed: false},
  ]: array<Internal.paramMeta>),
)

let makeEvent = (~topics: array<string>, ~data: string): HyperSyncClient.ResponseTypes.event =>
  {"log": {"topics": topics, "data": data}}->(
    Utils.magic: {..} => HyperSyncClient.ResponseTypes.event
  )

let fromAddr = "0x000000000000000000000000000000000000aaaa"
let toAddr = "0x000000000000000000000000000000000000bbbb"
let value = 42n

let transferLog = makeEvent(
  ~topics=[transferSighash, fromAddr->pad, toAddr->pad],
  ~data=encodeAbiParameters(%raw(`[{"type":"uint256"}]`), %raw(`[42n]`)),
)

describe("Same-signature event across contracts with different param names", () => {
  Async.it("decodes the shared Transfer under each contract's own param names", async t => {
    // Full production path: collect the decoder inputs for both contracts,
    // build the native decoder, decode the shared Transfer log. The decoder
    // returns params keyed by contract name so each contract's router can pick
    // its own names instead of the first-registered contract's.
    let allEventParams = EvmChain.collectEventParams([tokenA, tokenB])
    let decoder = HyperSyncClient.Decoder.fromParams(allEventParams)

    let decoded = await decoder.decodeLogs([transferLog])
    let paramsByContractName = decoded[0]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe

    t
    .expect(paramsByContractName)
    .toEqual(
      {
        "TokenA": {"from": fromAddr, "to": toAddr, "value": value},
        "TokenB": {"src": fromAddr, "dst": toAddr, "wad": value},
      }->Utils.magic,
    )
  })
})
