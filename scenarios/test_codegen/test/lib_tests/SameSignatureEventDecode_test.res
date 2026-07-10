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

let makeReg = (~name, ~params): Internal.evmOnEventRegistration =>
  EventConfigBuilder.buildEvmOnEventRegistration(
    ~eventConfig=EventConfigBuilder.buildEvmEventConfig(
      ~contractName=name,
      ~eventName="Transfer",
      ~sighash=transferSighash,
      ~params,
    ),
    ~isWildcard=false,
    ~handler=None,
    ~contractRegister=None,
    ~where=None,
    ~chainId=1,
    ~onEventBlockFilterSchema=Evm.make(~logger=Logging.getLogger()).onEventBlockFilterSchema,
  )

let tokenA = makeReg(
  ~name="TokenA",
  ~params=([
    {name: "from", abiType: "address", indexed: true},
    {name: "to", abiType: "address", indexed: true},
    {name: "value", abiType: "uint256", indexed: false},
  ]: array<Internal.paramMeta>),
)

let tokenB = makeReg(
  ~name="TokenB",
  ~params=([
    {name: "src", abiType: "address", indexed: true},
    {name: "dst", abiType: "address", indexed: true},
    {name: "wad", abiType: "uint256", indexed: false},
  ]: array<Internal.paramMeta>),
)

let fromAddr = "0x000000000000000000000000000000000000aaaa"
let toAddr = "0x000000000000000000000000000000000000bbbb"
let value = 42n

let transferLog = (
  [transferSighash, fromAddr->pad, toAddr->pad],
  encodeAbiParameters(%raw(`[{"type":"uint256"}]`), %raw(`[42n]`)),
)

describe("Same-signature event across contracts with different param names", () => {
  Async.it("decodes the shared Transfer under each contract's own param names", async t => {
    // Full production path: collect the decoder inputs for both contracts and
    // route+decode the shared Transfer log through EvmRpcClient. Routing picks
    // the owning contract's registration, so each contract's params come back
    // under its own names instead of the first-registered contract's.
    let tokenA = {...tokenA, index: 0}
    let tokenB = {...tokenB, index: 1}
    let allEventRegistrations = HyperSyncClient.Registration.fromOnEventRegistrations([tokenA, tokenB])

    let decodeAs = async contractName => {
      let decoded = await NativeDecoder.decodeLogs(
        ~eventRegistrations=allEventRegistrations,
        ~logs=[transferLog],
        ~contractNameByAddress=Dict.fromArray([(NativeDecoder.mockAddress, contractName)]),
      )
      let item = decoded[0]->Option.getUnsafe
      (item.onEventRegistrationIndex, item.params)
    }

    t
    .expect((await decodeAs("TokenA"), await decodeAs("TokenB")))
    .toEqual((
      (0, {"from": fromAddr, "to": toAddr, "value": value}->Utils.magic),
      (1, {"src": fromAddr, "dst": toAddr, "wad": value}->Utils.magic),
    ))
  })
})
