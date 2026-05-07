// Bulk-mode worker. Owns one block range for one chain. Pulls events from
// HyperSync, decodes them, and streams rows to ClickHouse using
// JSONCompactEachRow. Reports progress to the parent thread.
//
// One worker = one CPU + one HyperSync TCP connection + one CH connection.
// Workers never read from the database — bulk mode is write-only by design.

type workerData = {
  shardId: int,
  chainId: int,
  fromBlock: int,
  toBlock: int,
  hypersyncUrl: string,
  hypersyncToken: string,
  contractAddresses: array<string>,
  eventSignature: string,
  topic0: string,
  clickhouseUrl: string,
  clickhouseDatabase: string,
  clickhouseUsername: string,
  clickhousePassword: string,
  tableName: string,
}

@tag("kind")
type workerMessage =
  | @as("progress") Progress({shardId: int, lastBlock: int, eventsWritten: float})
  | @as("done") Done({shardId: int, totalEvents: float, durationMs: float})
  | @as("error") WorkerError({shardId: int, message: string})

// HyperSync field selection — keep it minimal. Anything not requested is not
// sent over the wire, which directly cuts decode + bandwidth time. We need
// transaction.hash for the tx_hash column, but skip the rest.
let buildFieldSelection = (): HyperSyncClient.QueryTypes.fieldSelection => {
  block: [Number, Timestamp],
  transaction: [Hash],
  log: [LogIndex, Address, Topic0, Topic1, Topic2, Topic3, Data],
}

// Transaction objects come back as Internal.eventTransaction which is an
// opaque/magic type — at runtime it's a JS object whose keys match the
// field names we requested. Pull `hash` via a raw lookup; fall back to "" if
// HyperSync didn't return it.
let getTxHash = (txn: Internal.eventTransaction): string => {
  let dict = txn->(Utils.magic: Internal.eventTransaction => dict<unknown>)
  switch dict->Utils.Dict.dangerouslyGetNonOption("hash") {
  | Some(v) => v->(Utils.magic: unknown => string)
  | None => ""
  }
}

// Build the HyperSync log selection: addresses + topic0 filter.
let buildLogSelection = (data: workerData): array<LogSelection.t> => {
  let addresses = data.contractAddresses->Array.map(Address.unsafeFromString)
  let topic0 = data.topic0->EvmTypes.Hex.fromStringUnsafe
  let topicSelection = switch LogSelection.makeTopicSelection(~topic0=[topic0]) {
  | Ok(ts) => ts
  | Error(_) => JsError.throwWithMessage("Bulk mode: failed to build topic0 selection")
  }
  [LogSelection.make(~addresses, ~topicSelections=[topicSelection])]
}

// Decoded transfer args come back as bigints/strings/etc. Keep it lazy and
// just call the HyperSync decoder on a batch — it returns the indexed and
// non-indexed args separated, which is convenient for ERC20 Transfer where
// from/to are indexed and value is in data.
let decodeBatch = async (
  decoder: HyperSyncClient.Decoder.t,
  events: array<HyperSyncClient.ResponseTypes.event>,
): array<Nullable.t<HyperSyncClient.Decoder.decodedEvent>> => {
  await decoder.decodeEvents(events)
}

// Convert a ReScript bigint to a string ClickHouse can ingest as a numeric.
// Plain `BigInt.toString` works; this wrapper exists so the call site reads
// well even when the underlying decode produces a plain JS BigInt via the
// HyperSync client.
let bigIntToString = (b: bigint): string => b->BigInt.toString

// Strip an indexed address topic ("0x" + 24 zero hex chars + 20-byte address)
// down to a plain "0x..." address string. HyperSync gives topics as hex
// strings so this is just a substring slice.
let topicToAddress = (topic: string): string => {
  let len = topic->String.length
  if len < 42 {
    topic
  } else {
    "0x" ++ topic->String.slice(~start=len - 40, ~end=len)
  }
}

// Encode one Transfer event into a JSONCompactEachRow row — a JS array in the
// schema's column order. Numbers fit in JSON; uint256 value goes as a string
// because ClickHouse parses string→UInt256 fine and JS bigints would be lost
// through JSON.stringify otherwise.
let encodeRow = (
  ~chainId: int,
  ~blockNumber: int,
  ~blockTimestampMs: float,
  ~logIndex: int,
  ~txHash: string,
  ~contract: string,
  ~from: string,
  ~to: string,
  ~value: string,
): array<unknown> => {
  [
    chainId->(Utils.magic: int => unknown),
    blockNumber->(Utils.magic: int => unknown),
    blockTimestampMs->(Utils.magic: float => unknown),
    logIndex->(Utils.magic: int => unknown),
    txHash->(Utils.magic: string => unknown),
    contract->(Utils.magic: string => unknown),
    from->(Utils.magic: string => unknown),
    to->(Utils.magic: string => unknown),
    value->(Utils.magic: string => unknown),
  ]
}

// Pull the value out of a decoded event. ERC20 Transfer puts `value` as the
// only non-indexed arg, so it lands at decoded.body[0].
let extractTransferValue = (decoded: HyperSyncClient.Decoder.decodedEvent): string => {
  switch decoded.body->Belt.Array.get(0) {
  | Some(DecodedNum(n)) => n->bigIntToString
  | Some(DecodedVal({val: DecodedNum(n)})) => n->bigIntToString
  | _ => "0"
  }
}

let postProgress = (port: NodeJs.WorkerThreads.messagePort, msg: workerMessage) => {
  port->NodeJs.WorkerThreads.postMessage(msg)
}

let runWorker = async (~data: workerData, ~port: NodeJs.WorkerThreads.messagePort) => {
  let started = Date.now()

  // 1. Init HyperSync client + decoder
  let client = HyperSyncClient.make(
    ~url=data.hypersyncUrl,
    ~apiToken=data.hypersyncToken,
    ~maxNumRetries=3,
    ~httpReqTimeoutMillis=120_000,
    ~enableChecksumAddresses=false,
    ~serializationFormat=CapnProto,
    ~enableQueryCaching=true,
  )
  let decoder = HyperSyncClient.Decoder.fromSignatures([data.eventSignature])
  decoder.disableChecksummedAddresses()

  // 2. Init ClickHouse client. Each worker has its own connection so they
  // don't contend on a shared agent.
  let chClient = ClickHouse.createClient({
    url: data.clickhouseUrl,
    database: data.clickhouseDatabase,
    username: data.clickhouseUsername,
    password: data.clickhousePassword,
  })

  let fieldSelection = buildFieldSelection()
  let logSelections = buildLogSelection(data)

  let totalEvents = ref(0.)
  let lastReportedAt = ref(Date.now())

  let cursor = ref(data.fromBlock)
  let toBlockInclusive = data.toBlock

  while cursor.contents <= toBlockInclusive {
    // HyperSync.GetLogs.query handles pagination internally up to the next
    // archive-height boundary and returns a logsQueryPage. We then decode
    // once for the page and stream rows to ClickHouse.
    let page = await HyperSync.GetLogs.query(
      ~client,
      ~fromBlock=cursor.contents,
      ~toBlock=Some(toBlockInclusive),
      ~logSelections,
      ~fieldSelection,
      ~nonOptionalBlockFieldNames=["number", "timestamp"],
      ~nonOptionalTransactionFieldNames=[],
    )

    let decoded = await decodeBatch(decoder, page.events)

    let rows = []
    for idx in 0 to page.items->Array.length - 1 {
      let item: HyperSync.logsQueryPageItem = page.items->Array.getUnsafe(idx)
      let decodedNullable = decoded->Array.getUnsafe(idx)
      switch decodedNullable->Nullable.toOption {
      | None => () // log didn't decode — skip (e.g. malformed Transfer)
      | Some(d) =>
        let blockNumber = item.block.number->Belt.Option.getUnsafe
        let blockTs = item.block.timestamp->Belt.Option.getUnsafe
        let txHash = getTxHash(item.transaction)
        let from = switch d.indexed->Belt.Array.get(0) {
        | Some(DecodedStr(s)) => s
        | Some(DecodedVal({val: DecodedStr(s)})) => s
        | _ =>
          // Fall back to topic-derived address
          switch item.log.topics->Belt.Array.get(1) {
          | Some(t) => t->EvmTypes.Hex.toString->topicToAddress
          | None => ""
          }
        }
        let to_ = switch d.indexed->Belt.Array.get(1) {
        | Some(DecodedStr(s)) => s
        | Some(DecodedVal({val: DecodedStr(s)})) => s
        | _ =>
          switch item.log.topics->Belt.Array.get(2) {
          | Some(t) => t->EvmTypes.Hex.toString->topicToAddress
          | None => ""
          }
        }
        let value = extractTransferValue(d)
        let row = encodeRow(
          ~chainId=data.chainId,
          ~blockNumber,
          ~blockTimestampMs=(blockTs * 1000)->Int.toFloat,
          ~logIndex=item.log.logIndex,
          ~txHash,
          ~contract=item.log.address->Address.toString,
          ~from,
          ~to=to_,
          ~value,
        )
        rows->Array.push(row)->ignore
      }
    }

    if rows->Array.length > 0 {
      // Streaming insert via the ClickHouse client. JSONCompactEachRow is
      // about 2× the speed of JSONEachRow because it skips field names per
      // row. Native protocol would be another 3× on top — Phase 2.
      try {
        await chClient->ClickHouse.insert({
          table: data.tableName,
          values: rows->(Utils.magic: array<array<unknown>> => array<'a>),
          format: "JSONCompactEachRow",
        })
      } catch {
      | exn =>
        port->postProgress(
          WorkerError({
            shardId: data.shardId,
            message: `ClickHouse insert failed: ${exn->Utils.prettifyExn->String.make}`,
          }),
        )
        throw(exn)
      }

      totalEvents := totalEvents.contents +. rows->Array.length->Int.toFloat
    }

    // HyperSync's `nextBlock` is the exclusive upper bound of what was
    // returned. If response was truncated (page limit), nextBlock <= toBlock
    // and we re-query from there. If it covered the whole range, nextBlock
    // > toBlockInclusive and the loop exits.
    cursor := page.nextBlock

    // Throttle progress messages to ~1/sec to avoid flooding the parent.
    let now = Date.now()
    if now -. lastReportedAt.contents > 1000. {
      lastReportedAt := now
      port->postProgress(
        Progress({
          shardId: data.shardId,
          lastBlock: cursor.contents - 1,
          eventsWritten: totalEvents.contents,
        }),
      )
    }
  }

  // Final progress before done so the coordinator's last-block view is up to date.
  port->postProgress(
    Progress({
      shardId: data.shardId,
      lastBlock: toBlockInclusive,
      eventsWritten: totalEvents.contents,
    }),
  )
  port->postProgress(
    Done({
      shardId: data.shardId,
      totalEvents: totalEvents.contents,
      durationMs: Date.now() -. started,
    }),
  )

  await chClient->ClickHouse.close
}

// Entry point used by the worker shim. Reads workerData from the worker
// thread context, runs the worker loop, and exits on completion or error.
let runFromWorkerThread = async () => {
  if NodeJs.WorkerThreads.isMainThread {
    JsError.throwWithMessage("BulkWorker.runFromWorkerThread must be called from a worker thread")
  }
  let port = switch NodeJs.WorkerThreads.parentPort->Nullable.toOption {
  | Some(p) => p
  | None => JsError.throwWithMessage("BulkWorker missing parentPort")
  }
  let data = switch NodeJs.WorkerThreads.workerData->Nullable.toOption {
  | Some(d) => d->(Utils.magic: 'a => workerData)
  | None => JsError.throwWithMessage("BulkWorker missing workerData")
  }

  try {
    await runWorker(~data, ~port)
  } catch {
  | exn =>
    port->postProgress(
      WorkerError({
        shardId: data.shardId,
        message: exn->Utils.prettifyExn->String.make,
      }),
    )
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
