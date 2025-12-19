let makeRpcRoute = (method: string, paramsSchema, resultSchema) => {
  let idSchema = S.literal(1)
  let versionSchema = S.literal("2.0")
  Rest.route(() => {
    method: Post,
    path: "",
    input: s => {
      let _ = s.field("method", S.literal(method))
      let _ = s.field("id", idSchema)
      let _ = s.field("jsonrpc", versionSchema)
      s.field("params", paramsSchema)
    },
    responses: [
      s => {
        let _ = s.field("jsonrpc", versionSchema)
        let _ = s.field("id", idSchema)
        s.field("result", resultSchema)
      },
    ],
  })
}

type hex = string
let makeHexSchema = fromStr =>
  S.string->S.transform(s => {
    parser: str =>
      switch str->fromStr {
      | Some(v) => v
      | None => s.fail("The string is not valid hex")
      },
    serializer: value => value->Viem.toHex->Utils.magic,
  })

let hexBigintSchema: S.schema<bigint> = makeHexSchema(BigInt.fromString)
external number: string => int = "Number"
let hexIntSchema: S.schema<int> = makeHexSchema(v => v->number->Some)

module GetLogs = {
  @unboxed
  type topicFilter = Single(hex) | Multiple(array<hex>) | @as(null) Null
  let topicFilterSchema = S.union([
    S.literal(Null),
    S.schema(s => Multiple(s.matches(S.array(S.string)))),
    S.schema(s => Single(s.matches(S.string))),
  ])
  type topicQuery = array<topicFilter>
  let topicQuerySchema = S.array(topicFilterSchema)

  let makeTopicQuery = (~topic0=[], ~topic1=[], ~topic2=[], ~topic3=[]) => {
    let topics = [topic0, topic1, topic2, topic3]

    let isLastTopicEmpty = () =>
      switch topics->Utils.Array.last {
      | Some([]) => true
      | _ => false
      }

    //Remove all empty topics from the end of the array
    while isLastTopicEmpty() {
      topics->Js.Array2.pop->ignore
    }

    let toTopicFilter = topic => {
      switch topic {
      | [] => Null
      | [single] => Single(single->EvmTypes.Hex.toString)
      | multiple => Multiple(multiple->EvmTypes.Hex.toStrings)
      }
    }

    topics->Belt.Array.map(toTopicFilter)
  }

  let mapTopicQuery = ({topic0, topic1, topic2, topic3}: Internal.topicSelection): topicQuery =>
    makeTopicQuery(~topic0, ~topic1, ~topic2, ~topic3)

  type param = {
    fromBlock: int,
    toBlock: int,
    address: array<Address.t>,
    topics: topicQuery,
    // blockHash?: string,
  }

  let paramsSchema = S.object((s): param => {
    fromBlock: s.field("fromBlock", hexIntSchema),
    toBlock: s.field("toBlock", hexIntSchema),
    address: s.field("address", S.array(Address.schema)),
    topics: s.field("topics", topicQuerySchema),
    // blockHash: ?s.field("blockHash", S.option(S.string)),
  })

  type log = {
    address: Address.t,
    topics: array<hex>,
    data: hex,
    blockNumber: int,
    transactionHash: hex,
    transactionIndex: int,
    blockHash: hex,
    logIndex: int,
    removed: bool,
  }

  let logSchema = S.object((s): log => {
    address: s.field("address", Address.schema),
    topics: s.field("topics", S.array(S.string)),
    data: s.field("data", S.string),
    blockNumber: s.field("blockNumber", hexIntSchema),
    transactionHash: s.field("transactionHash", S.string),
    transactionIndex: s.field("transactionIndex", hexIntSchema),
    blockHash: s.field("blockHash", S.string),
    logIndex: s.field("logIndex", hexIntSchema),
    removed: s.field("removed", S.bool),
  })

  let route = makeRpcRoute("eth_getLogs", S.tuple1(paramsSchema), S.array(logSchema))
}

module GetBlockByNumber = {
  type block = {
    difficulty: option<bigint>,
    extraData: hex,
    gasLimit: bigint,
    gasUsed: bigint,
    hash: hex,
    logsBloom: hex,
    miner: Address.t,
    mixHash: option<hex>,
    nonce: option<bigint>,
    number: int,
    parentHash: hex,
    receiptsRoot: hex,
    sha3Uncles: hex,
    size: bigint,
    stateRoot: hex,
    timestamp: int,
    totalDifficulty: option<bigint>,
    transactions: array<Js.Json.t>,
    transactionsRoot: hex,
    uncles: option<array<hex>>,
  }

  let blockSchema = S.object((s): block => {
    difficulty: s.field("difficulty", S.null(hexBigintSchema)),
    extraData: s.field("extraData", S.string),
    gasLimit: s.field("gasLimit", hexBigintSchema),
    gasUsed: s.field("gasUsed", hexBigintSchema),
    hash: s.field("hash", S.string),
    logsBloom: s.field("logsBloom", S.string),
    miner: s.field("miner", Address.schema),
    mixHash: s.field("mixHash", S.null(S.string)),
    nonce: s.field("nonce", S.null(hexBigintSchema)),
    number: s.field("number", hexIntSchema),
    parentHash: s.field("parentHash", S.string),
    receiptsRoot: s.field("receiptsRoot", S.string),
    sha3Uncles: s.field("sha3Uncles", S.string),
    size: s.field("size", hexBigintSchema),
    stateRoot: s.field("stateRoot", S.string),
    timestamp: s.field("timestamp", hexIntSchema),
    totalDifficulty: s.field("totalDifficulty", S.null(hexBigintSchema)),
    transactions: s.field("transactions", S.array(S.json(~validate=false))),
    transactionsRoot: s.field("transactionsRoot", S.string),
    uncles: s.field("uncles", S.null(S.array(S.string))),
  })

  let route = makeRpcRoute(
    "eth_getBlockByNumber",
    S.tuple(s =>
      {
        "blockNumber": s.item(0, hexIntSchema),
        "includeTransactions": s.item(1, S.bool),
      }
    ),
    S.null(blockSchema),
  )
}

module GetBlockHeight = {
  let route = makeRpcRoute("eth_blockNumber", S.tuple(_ => ()), hexIntSchema)
}

module GetTransactionByHash = {
  let transactionSchema = S.object((s): Internal.evmTransactionFields => {
    // We already know the data so ignore the fields
    // blockHash: ?s.field("blockHash", S.option(S.string)),
    // blockNumber: ?s.field("blockNumber", S.option(hexIntSchema)),
    // chainId: ?s.field("chainId", S.option(hexIntSchema)),
    from: ?s.field("from", S.option(S.string->(Utils.magic: S.t<string> => S.t<Address.t>))),
    to: ?s.field("to", S.option(S.string->(Utils.magic: S.t<string> => S.t<Address.t>))),
    gas: ?s.field("gas", S.option(hexBigintSchema)),
    gasPrice: ?s.field("gasPrice", S.option(hexBigintSchema)),
    hash: ?s.field("hash", S.option(S.string)),
    input: ?s.field("input", S.option(S.string)),
    nonce: ?s.field("nonce", S.option(hexBigintSchema)),
    transactionIndex: ?s.field("transactionIndex", S.option(hexIntSchema)),
    value: ?s.field("value", S.option(hexBigintSchema)),
    type_: ?s.field("type", S.option(hexIntSchema)),
    // Signature fields - optional for ZKSync EIP-712 compatibility
    v: ?s.field("v", S.option(S.string)),
    r: ?s.field("r", S.option(S.string)),
    s: ?s.field("s", S.option(S.string)),
    yParity: ?s.field("yParity", S.option(S.string)),
    // EIP-1559 fields
    maxPriorityFeePerGas: ?s.field("maxPriorityFeePerGas", S.option(hexBigintSchema)),
    maxFeePerGas: ?s.field("maxFeePerGas", S.option(hexBigintSchema)),
    // EIP-4844 blob fields
    maxFeePerBlobGas: ?s.field("maxFeePerBlobGas", S.option(hexBigintSchema)),
    blobVersionedHashes: ?s.field("blobVersionedHashes", S.option(S.array(S.string))),
    // TODO: Fields to add:
    // pub access_list: Option<Vec<AccessList>>,
    // pub authorization_list: Option<Vec<Authorization>>,
    // // OP stack fields
    // pub deposit_receipt_version: Option<Quantity>,
    // pub mint: Option<Quantity>,
    // pub source_hash: Option<Hash>,
  })

  let route = makeRpcRoute(
    "eth_getTransactionByHash",
    S.tuple1(S.string),
    S.null(transactionSchema),
  )
}
