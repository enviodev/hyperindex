open Vitest

// `field_selection` on an RPC-synced chain is validated at config parse, while
// the fields an RPC source can actually deliver are decided by the parsers in
// `RpcSource`. This pins the two together: every field the source can parse
// must be accepted by the config, and every field it can't must be rejected.

// `number`/`timestamp`/`hash` are always on the block, so they aren't
// selectable through `block_fields` — the config enum has no variant for them,
// and the RPC block registry has no parser for them either.
let selectableBlockFields =
  Evm.blockFields->Array.filter(name =>
    switch name {
    | "number" | "timestamp" | "hash" => false
    | _ => true
    }
  )

let hasRpcBlockParser = (name: string) =>
  RpcSource.blockFieldRegistryChecksum
  ->Utils.Record.get(name->(Utils.magic: string => Internal.evmBlockField))
  ->Option.isSome

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
      ~blockFields=selectableBlockFields,
      ~transactionFields=selectableTransactionFields->Array.filter(RpcSource.isRpcTransactionField),
    )
    t.expect((
      selectableBlockFields->Array.filter(f => !hasRpcBlockParser(f)),
      parseError(yaml),
    )).toEqual(([], None))
  })

  it("rejects every field the RPC source can't parse", t => {
    let unsupported =
      selectableTransactionFields->Array.filter(f => !RpcSource.isRpcTransactionField(f))
    let errors =
      unsupported->Array.map(field => parseError(rpcChainConfig(~transactionFields=[field])))
    t.expect((unsupported, errors)).toEqual((
      ["accessList", "authorizationList"],
      [
        Some(
          "The following selected transaction_fields are unavailable for indexing via RPC: accessList",
        ),
        Some(
          "The following selected transaction_fields are unavailable for indexing via RPC: authorizationList",
        ),
      ],
    ))
  })

  // The chain syncs over HyperSync here — but its fallback RPC would serve the
  // same events with the same parsers, so the limit still applies.
  it("holds a chain to the RPC limits when it only falls back to one", t => {
    t.expect(
      parseError(`
name: rpc-fallback-field-selection
field_selection:
  transaction_fields: [accessList]
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: fallback
    start_block: 0
`),
    ).toBe(
      Some(
        "The following selected transaction_fields are unavailable for indexing via RPC: accessList",
      ),
    )
  })
})
