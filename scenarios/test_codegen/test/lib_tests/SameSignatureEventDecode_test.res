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
  Async.it("decodes TokenB's Transfer under TokenB's own param names", async t => {
    // Full production path: collect the decoder inputs for both contracts,
    // build the native decoder, decode a Transfer log emitted by TokenB.
    let allEventParams = EvmChain.collectEventParams([tokenA, tokenB])
    let decoder = HyperSyncClient.Decoder.fromParams(allEventParams)

    let decoded = await decoder.decodeLogs([transferLog])
    let params = decoded[0]->Option.getUnsafe->Nullable.toOption->Option.getUnsafe

    // TokenB's handler reads `src`/`dst`/`wad`. `collectEventParams` dedupes by
    // (sighash, topicCount) first-contract-wins, so only TokenA's metadata
    // reaches the native decoder and TokenB's params decode as `from/to/value`,
    // leaving the handler's reads undefined.
    t.expect(params).toEqual({"src": fromAddr, "dst": toAddr, "wad": value}->Utils.magic)
  })
})
