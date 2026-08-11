open Vitest

// `field_selection` on an RPC-synced chain is validated at config parse, while
// the fields an RPC source can actually deliver are decided by the parsers in
// `RpcSource`. This pins the two together: every field the source can parse
// must be accepted by the config, and every field it can't must be rejected.

// `number`/`timestamp`/`hash` are always on the block, so they aren't
// selectable through `block_fields` — the config enum has no variant for them.
let selectableBlockFields =
  Evm.blockFields->Array.filter(name =>
    switch name {
    | "number" | "timestamp" | "hash" => false
    | _ => true
    }
  )

let selectableTransactionFields =
  Internal.allEvmTransactionFields->(
    Utils.magic: array<Internal.evmTransactionField> => array<string>
  )

let rpcChainConfig = (~blockFields=[], ~transactionFields=[]) => `
name: rpc-field-selection
field_selection:
  block_fields: [${blockFields->Array.joinUnsafe(", ")}]
  transaction_fields: [${transactionFields->Array.joinUnsafe(", ")}]
chains:
  - id: 999999
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
`

let parseError = yaml =>
  try {
    InternalTestIndexer.fromUserApi(~configYaml=yaml)->ignore
    None
  } catch {
  | JsExn(e) => Some(e->JsExn.message->Option.getOr("an error with a message"))
  }

describe("RPC field_selection validation", () => {
  it("accepts every field the RPC source can parse", t => {
    let yaml = rpcChainConfig(
      ~blockFields=selectableBlockFields->Array.filter(RpcSource.isRpcBlockField),
      ~transactionFields=selectableTransactionFields->Array.filter(
        RpcSource.isRpcTransactionField,
      ),
    )
    t.expect(parseError(yaml)).toBe(None)
  })

  it("rejects every field the RPC source can't parse", t => {
    let unsupportedBlock = selectableBlockFields->Array.filter(f => !RpcSource.isRpcBlockField(f))
    let unsupportedTransaction =
      selectableTransactionFields->Array.filter(f => !RpcSource.isRpcTransactionField(f))
    let errors =
      unsupportedBlock
      ->Array.map(field => parseError(rpcChainConfig(~blockFields=[field])))
      ->Array.concat(
        unsupportedTransaction->Array.map(field =>
          parseError(rpcChainConfig(~transactionFields=[field]))
        ),
      )
    t.expect((unsupportedBlock, unsupportedTransaction, errors)).toEqual((
      [],
      ["accessList", "authorizationList"],
      [
        Some(
          "Config parse error: The following selected transaction_fields are unavailable for indexing via RPC: accessList",
        ),
        Some(
          "Config parse error: The following selected transaction_fields are unavailable for indexing via RPC: authorizationList",
        ),
      ],
    ))
  })
})
