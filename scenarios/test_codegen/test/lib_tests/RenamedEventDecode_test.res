open Vitest

@module("viem")
external encodeAbiParameters: (JSON.t, JSON.t) => string = "encodeAbiParameters"

@module("viem")
external toEventSelector: string => string = "toEventSelector"

// Reproduces https://github.com/enviodev/hyperindex/issues/1285
// An event given a `name:` that differs from its on-chain name must still
// decode. The decoder keys on the on-chain sighash, not the keccak of the
// display `name:`, so the real log still matches.
let onChainSighash = toEventSelector("event Approval(address owner, uint256 value)")

let owner = "0x000000000000000000000000000000000000aaaa"
let value = 42n

let approvalLog = (
  [onChainSighash],
  encodeAbiParameters(
    %raw(`[{"type":"address"},{"type":"uint256"}]`),
    %raw(`["0x000000000000000000000000000000000000aaaa",42n]`),
  ),
)

describe("Renamed event decoding (issue #1285)", () => {
  Async.it("decodes a renamed event under its real on-chain signature", async t => {
    let decoded = await NativeDecoder.decodeLogs(
      ~eventParams=[
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
      ],
      ~logs=[approvalLog],
    )
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
