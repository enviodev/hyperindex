module Query = {
  type method =
    | @as("eth_getLogs") EthGetLogs
    | @as("eth_getBlockByNumber") EthGetBlockByNumber
    | @as("eth_blockNumber") EthBlockNumber
  let methodSchema = S.union([
    S.literal(EthGetLogs),
    S.literal(EthGetBlockByNumber),
    S.literal(EthBlockNumber),
  ])
  type jsonRpcVersion = | @as("2.0") TwoPointZero
  let jsonRpcVersionSchema = S.literal(TwoPointZero)
  //use json params to be ablet to mix query types in an array for batch queries
  type t = {method: method, params: array<Js.Json.t>, mutable id: int, jsonrpc: jsonRpcVersion}
  let schema: S.schema<t> = S.object(s => {
    method: s.field("method", methodSchema),
    params: s.field("params", S.array(S.json(~validate=false))),
    id: s.field("id", S.int),
    jsonrpc: s.field("jsonrpc", jsonRpcVersionSchema),
  })

  type response<'a> = {
    jsonrpc: jsonRpcVersion,
    id: int,
    result: 'a,
  }

  let makeResponseSchema = (resultSchema: S.schema<'a>) =>
    S.object((s): response<'a> => {
      jsonrpc: s.field("jsonrpc", jsonRpcVersionSchema),
      id: s.field("id", S.int),
      result: s.field("result", resultSchema),
    })

  let make = (~method, ~params, ~id=1) => {method, params, id, jsonrpc: TwoPointZero}
}

module BatchQuery = {
  type t = array<Query.t>
}

type hex = string

let makeHexSchema = fromStr =>
  S.string->S.transform(s => {
    parser: str =>
      switch str->fromStr {
      | Some(v) => v
      | None => s.fail("The string is not valid hex")
      },
    serializer: bigint => bigint->Viem.toHex->Utils.magic,
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

  let mapTopicQuery = ({topic0, topic1, topic2, topic3}: LogSelection.topicSelection): topicQuery =>
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

  let responseSchema = Query.makeResponseSchema(S.array(logSchema))

  let make = (~fromBlock, ~toBlock, ~address, ~topics) => {
    let params = {
      fromBlock,
      toBlock,
      address,
      topics,
    }->S.reverseConvertToJsonWith(paramsSchema)
    Query.make(~method=EthGetLogs, ~params=[params])
  }
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

  let responseSchema: S.t<Query.response<option<block>>> = Query.makeResponseSchema(
    S.null(blockSchema),
  )

  let make = (~blockNumber, ~includeTransactions=false) => {
    let blockNumber = blockNumber->Viem.toHex->Utils.magic
    let transactionDetailFlag = includeTransactions->(Utils.magic: bool => Js.Json.t)
    Query.make(~method=EthGetBlockByNumber, ~params=[blockNumber, transactionDetailFlag])
  }
}

module GetBlockHeight = {
  type response = int
  let responseSchema = Query.makeResponseSchema(hexIntSchema)

  let make = () => Query.make(~method=EthBlockNumber, ~params=[])
}
