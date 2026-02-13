type rpcError = {code: int, message: string}
exception JsonRpcError(rpcError)

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

let jsonRpcFetcher: Rest.ApiFetcher.t = async args => {
  let response = await Rest.ApiFetcher.default(args)
  let data: {..} = response.data->Obj.magic
  switch data["error"]->Js.Nullable.toOption {
  | Some(error) =>
    raise(
      JsonRpcError({
        code: error["code"],
        message: error["message"],
      }),
    )
  | None => response
  }
}

let makeClient = url => Rest.client(url, ~fetcher=jsonRpcFetcher)

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

external parseFloat: string => float = "Number"
let decimalFloatSchema: S.schema<float> = S.string->S.transform(s => {
  parser: str => {
    let v = parseFloat(str)
    if Js.Float.isNaN(v) {
      s.fail("The string is not a valid decimal number")
    } else {
      v
    }
  },
})

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
    address?: array<Address.t>,
    topics: topicQuery,
    // blockHash?: string,
  }

  let paramsSchema = S.object((s): param => {
    fromBlock: s.field("fromBlock", hexIntSchema),
    toBlock: s.field("toBlock", hexIntSchema),
    address: ?s.field("address", S.option(S.array(Address.schema))),
    topics: s.field("topics", topicQuerySchema),
    // blockHash: ?s.field("blockHash", S.option(S.string)),
  })

  let fullParamsSchema = S.tuple1(paramsSchema)

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

  let resultSchema = S.array(logSchema)

  let route = makeRpcRoute("eth_getLogs", fullParamsSchema, resultSchema)
}

module GetBlockByNumber = {
  type block = {
    difficulty: option<bigint>,
    extraData: hex,
    gasLimit: bigint,
    gasUsed: bigint,
    hash: hex,
    logsBloom: hex,
    mutable miner: Address.t,
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

  let paramsSchema = S.tuple(s =>
    {
      "blockNumber": s.item(0, hexIntSchema),
      "includeTransactions": s.item(1, S.bool),
    }
  )

  let resultSchema = S.null(blockSchema)

  let route = makeRpcRoute(
    "eth_getBlockByNumber",
    paramsSchema,
    resultSchema,
  )
}

module GetBlockHeight = {
  let route = makeRpcRoute("eth_blockNumber", S.tuple(_ => ()), hexIntSchema)
}

module GetTransactionByHash = {
  let transactionSchema = S.object((s): Internal.evmTransactionFields => {
    // We already know the data so ignore the fields
    // blockHash: ?s.field("blockHash", S.nullable(S.string)),
    // blockNumber: ?s.field("blockNumber", S.nullable(hexIntSchema)),
    // chainId: ?s.field("chainId", S.nullable(hexIntSchema)),
    from: ?s.field("from", S.nullable(S.string->(Utils.magic: S.t<string> => S.t<Address.t>))),
    to: ?s.field("to", S.nullable(S.string->(Utils.magic: S.t<string> => S.t<Address.t>))),
    gas: ?s.field("gas", S.nullable(hexBigintSchema)),
    gasPrice: ?s.field("gasPrice", S.nullable(hexBigintSchema)),
    hash: ?s.field("hash", S.nullable(S.string)),
    input: ?s.field("input", S.nullable(S.string)),
    nonce: ?s.field("nonce", S.nullable(hexBigintSchema)),
    transactionIndex: ?s.field("transactionIndex", S.nullable(hexIntSchema)),
    value: ?s.field("value", S.nullable(hexBigintSchema)),
    type_: ?s.field("type", S.nullable(hexIntSchema)),
    // Signature fields - optional for ZKSync EIP-712 compatibility
    v: ?s.field("v", S.nullable(S.string)),
    r: ?s.field("r", S.nullable(S.string)),
    s: ?s.field("s", S.nullable(S.string)),
    yParity: ?s.field("yParity", S.nullable(S.string)),
    // EIP-1559 fields
    maxPriorityFeePerGas: ?s.field("maxPriorityFeePerGas", S.nullable(hexBigintSchema)),
    maxFeePerGas: ?s.field("maxFeePerGas", S.nullable(hexBigintSchema)),
    // EIP-4844 blob fields
    maxFeePerBlobGas: ?s.field("maxFeePerBlobGas", S.nullable(hexBigintSchema)),
    blobVersionedHashes: ?s.field("blobVersionedHashes", S.nullable(S.array(S.string))),
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

module GetTransactionReceipt = {
  // Parses receipt-only fields into evmTransactionFields.
  // Only receipt-specific fields are included; other fields in the receipt JSON are ignored.
  let receiptSchema = S.object((s): Internal.evmTransactionFields => {
    gasUsed: ?s.field("gasUsed", S.nullable(hexBigintSchema)),
    cumulativeGasUsed: ?s.field("cumulativeGasUsed", S.nullable(hexBigintSchema)),
    effectiveGasPrice: ?s.field("effectiveGasPrice", S.nullable(hexBigintSchema)),
    contractAddress: ?s.field("contractAddress", S.nullable(S.string)),
    logsBloom: ?s.field("logsBloom", S.nullable(S.string)),
    root: ?s.field("root", S.nullable(S.string)),
    status: ?s.field("status", S.nullable(hexIntSchema)),
    l1Fee: ?s.field("l1Fee", S.nullable(hexBigintSchema)),
    l1GasPrice: ?s.field("l1GasPrice", S.nullable(hexBigintSchema)),
    l1GasUsed: ?s.field("l1GasUsed", S.nullable(hexBigintSchema)),
    l1FeeScalar: ?s.field("l1FeeScalar", S.nullable(decimalFloatSchema)),
    gasUsedForL1: ?s.field("gasUsedForL1", S.nullable(hexBigintSchema)),
  })

  let route = makeRpcRoute(
    "eth_getTransactionReceipt",
    S.tuple1(S.string),
    S.null(receiptSchema),
  )
}

let getLogs = async (~client: Rest.client, ~param: GetLogs.param) => {
  await GetLogs.route->Rest.fetch(param, ~client)
}

let getBlock = async (~client: Rest.client, ~blockNumber: int) => {
  await GetBlockByNumber.route->Rest.fetch(
    {"blockNumber": blockNumber, "includeTransactions": false},
    ~client,
  )
}
