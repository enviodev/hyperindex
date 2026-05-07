// Bulk-mode worker. Owns one CH + one HyperSync connection. Stateless across
// chunks: the main thread hands it (fromBlock, toBlock) ranges over the
// `parentPort` channel, the worker processes one at a time and asks for the
// next one when done. This work-stealing queue keeps every worker busy until
// the global block range is fully covered, so the wall time isn't dominated
// by whichever shard happens to land in the densest part of history.

type workerData = {
  workerId: int,
  chainId: int,
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

// worker → main
@tag("kind")
type workerMessage =
  | @as("ready") Ready({workerId: int})
  | @as("progress") Progress({workerId: int, lastBlock: int, lifetimeEvents: float})
  | @as("needNext") NeedNext({workerId: int})
  | @as("drained") Drained({workerId: int, totalEvents: float})
  | @as("error") WorkerError({workerId: int, message: string})

// main → worker
@tag("kind")
type mainMessage =
  | @as("work") Work({fromBlock: int, toBlock: int})
  | @as("drain") Drain({_dummy: bool})

let buildFieldSelection = (): HyperSyncClient.QueryTypes.fieldSelection => {
  block: [Number, Timestamp],
  transaction: [Hash],
  log: [LogIndex, Address, Topic0, Topic1, Topic2, Topic3, Data],
}

let getTxHash = (txn: Internal.eventTransaction): string => {
  let dict = txn->(Utils.magic: Internal.eventTransaction => dict<unknown>)
  switch dict->Utils.Dict.dangerouslyGetNonOption("hash") {
  | Some(v) => v->(Utils.magic: unknown => string)
  | None => ""
  }
}

let buildLogSelection = (data: workerData): array<LogSelection.t> => {
  let addresses = data.contractAddresses->Array.map(Address.unsafeFromString)
  let topic0 = data.topic0->EvmTypes.Hex.fromStringUnsafe
  let topicSelection = switch LogSelection.makeTopicSelection(~topic0=[topic0]) {
  | Ok(ts) => ts
  | Error(_) => JsError.throwWithMessage("Bulk mode: failed to build topic0 selection")
  }
  [LogSelection.make(~addresses, ~topicSelections=[topicSelection])]
}

let bigIntToString = (b: bigint): string => b->BigInt.toString

let topicToAddress = (topic: string): string => {
  let len = topic->String.length
  if len < 42 {
    topic
  } else {
    "0x" ++ topic->String.slice(~start=len - 40, ~end=len)
  }
}

let extractTransferValue = (decoded: HyperSyncClient.Decoder.decodedEvent): string => {
  switch decoded.body->Belt.Array.get(0) {
  | Some(DecodedNum(n)) => n->bigIntToString
  | Some(DecodedVal({val: DecodedNum(n)})) => n->bigIntToString
  | _ => "0"
  }
}

let postWorkerMessage = (port: NodeJs.WorkerThreads.messagePort, msg: workerMessage) => {
  port->NodeJs.WorkerThreads.postMessage(msg)
}

// TypedArray set/get — the standard Uint32Array binding doesn't expose
// element-level write, so we go through a tiny %raw shim.
let u32Set: (Uint32Array.t, int, int) => unit = %raw(`(a, i, v) => { a[i] = v; }`)
let f64Set: (Float64Array.t, int, float) => unit = %raw(`(a, i, v) => { a[i] = v; }`)

// `Promise.make` wrapper that resolves to the next message received on the
// parent port. We process one chunk at a time, so the queue depth is at most 1.
let nextMessage = (port: NodeJs.WorkerThreads.messagePort): promise<mainMessage> => {
  Promise.make((resolve, _reject) => {
    let onceListener: (
      NodeJs.WorkerThreads.messagePort,
      mainMessage => unit,
    ) => unit = %raw(`function(p, fn) { p.once("message", fn); }`)
    onceListener(port, (msg: mainMessage) => resolve(msg))
  })
}

let runWorker = async (~data: workerData, ~port: NodeJs.WorkerThreads.messagePort) => {
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

  // 2. ClickHouse — we go straight to the HTTP endpoint via fetch for
  // RowBinary inserts (the official client refuses them). Node's fetch
  // (undici) handles keep-alive across calls automatically, so we don't
  // need a long-lived client object here.
  let _ = data.clickhouseUrl // referenced via insertRowBinary below

  let fieldSelection = buildFieldSelection()
  let logSelections = buildLogSelection(data)

  let lifetimeEvents = ref(0.)
  let lastReportedAt = ref(Date.now())

  // Holds the previous CH insert so the next iteration can fire HyperSync
  // and decode while the network call is still in flight (fetch+decode and
  // CH ingest run concurrently). Worker still waits for the in-flight insert
  // before queueing the next one, so memory stays bounded.
  let pendingInsert: ref<promise<unit>> = ref(Promise.resolve())

  // Per-phase timing accumulators in milliseconds. Reported at drain so we
  // can see where the worker is spending its time without per-iteration log
  // overhead.
  let tFetch = ref(0.)
  let tDecode = ref(0.)
  let tBuild = ref(0.)
  let tEncode = ref(0.)
  let tInsertWait = ref(0.)
  let bytesPosted = ref(0.)

  // Per-worker server-side concurrency for HyperSync's collectEvents. Default
  // 10 (the lib default), tunable via env var. Each worker × concurrency =
  // total in-flight server queries from the token, so balance worker count
  // against this for the rate limit.
  let serverConcurrency = switch %raw(`process.env.ENVIO_BULK_HS_CONCURRENCY`)->Nullable.toOption {
  | Some(s) =>
    switch Belt.Int.fromString(s) {
    | Some(n) => n
    | None => 10
    }
  | None => 10
  }

  // Process one block range. Returns when [fromBlock, toBlock] is fully
  // covered. Uses HyperSync's `collectEvents` API which spawns server-side
  // concurrent sub-queries — much faster than a single getEvents call for
  // large block ranges, and bounded only by the server token's overall rate
  // limit instead of the per-call latency floor.
  let processChunk = async (~fromBlock: int, ~toBlock: int) => {
    let cursor = ref(fromBlock)
    while cursor.contents <= toBlock {
      let tFetchStart = Date.now()
      let page = await HyperSync.GetLogs.collectAll(
        ~client,
        ~fromBlock=cursor.contents,
        ~toBlock=Some(toBlock),
        ~logSelections,
        ~fieldSelection,
        ~concurrency=serverConcurrency,
        ~nonOptionalBlockFieldNames=["number", "timestamp"],
        ~nonOptionalTransactionFieldNames=[],
      )
      tFetch := tFetch.contents +. (Date.now() -. tFetchStart)
      cursor := page.nextBlock

      let pageItemCount = page.items->Array.length
      if pageItemCount > 0 {
        let tDecodeStart = Date.now()
        let decoded = await decoder.decodeEvents(page.events)
        tDecode := tDecode.contents +. (Date.now() -. tDecodeStart)
        let tBuildStart = Date.now()

        // Build column arrays sized to the page. Sized once, no resizing.
        let chainIds = Uint32Array.fromLength(pageItemCount)
        let blockNumbers = Uint32Array.fromLength(pageItemCount)
        let blockTimestampsMs = Float64Array.fromLength(pageItemCount)
        let logIndices = Uint32Array.fromLength(pageItemCount)
        let txHashesHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
        let contractsHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
        let fromsHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
        let tosHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
        let valuesDec = Belt.Array.makeUninitializedUnsafe(pageItemCount)

        let written = ref(0)
        for idx in 0 to pageItemCount - 1 {
          let item: HyperSync.logsQueryPageItem = page.items->Array.getUnsafe(idx)
          let decodedNullable = decoded->Array.getUnsafe(idx)
          switch decodedNullable->Nullable.toOption {
          | None => () // log didn't decode — skip
          | Some(d) =>
            let blockNumber = item.block.number->Belt.Option.getUnsafe
            let blockTs = item.block.timestamp->Belt.Option.getUnsafe
            let txHash = getTxHash(item.transaction)
            let from = switch d.indexed->Belt.Array.get(0) {
            | Some(DecodedStr(s)) => s
            | Some(DecodedVal({val: DecodedStr(s)})) => s
            | _ =>
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

            let w = written.contents
            chainIds->u32Set(w, data.chainId)
            blockNumbers->u32Set(w, blockNumber)
            blockTimestampsMs->f64Set(w, (blockTs * 1000)->Int.toFloat)
            logIndices->u32Set(w, item.log.logIndex)
            txHashesHex->Belt.Array.setUnsafe(w, txHash)
            contractsHex->Belt.Array.setUnsafe(w, item.log.address->Address.toString)
            fromsHex->Belt.Array.setUnsafe(w, from)
            tosHex->Belt.Array.setUnsafe(w, to_)
            valuesDec->Belt.Array.setUnsafe(w, value)
            written := w + 1
          }
        }

        tBuild := tBuild.contents +. (Date.now() -. tBuildStart)
        let rowCount = written.contents
        if rowCount > 0 {
          let tEncodeStart = Date.now()
          let buf = BulkRowBinary.encodeBatch(
            ~chainIds,
            ~blockNumbers,
            ~blockTimestampsMs,
            ~logIndices,
            ~txHashesHex,
            ~contractsHex,
            ~fromsHex,
            ~tosHex,
            ~valuesDec,
            ~rowCount,
          )
          tEncode := tEncode.contents +. (Date.now() -. tEncodeStart)
          let bufLen: 'a => float = %raw(`(b) => b.length`)
          bytesPosted := bytesPosted.contents +. bufLen(buf)
          // Wait for the previous CH insert to finish so we don't pile up
          // unbounded backpressure. Then fire the next one without awaiting,
          // letting the loop body advance to the next HyperSync fetch + decode
          // while CH is still ingesting. This pipelines IO in the worker.
          let tWaitStart = Date.now()
          await pendingInsert.contents
          tInsertWait := tInsertWait.contents +. (Date.now() -. tWaitStart)
          pendingInsert :=
            BulkRowBinary.insertRowBinary(
              ~url=data.clickhouseUrl,
              ~database=data.clickhouseDatabase,
              ~table=data.tableName,
              ~username=data.clickhouseUsername,
              ~password=data.clickhousePassword,
              ~body=buf,
            )
          lifetimeEvents := lifetimeEvents.contents +. rowCount->Int.toFloat
        }
      }

      let now = Date.now()
      if now -. lastReportedAt.contents > 1000. {
        lastReportedAt := now
        port->postWorkerMessage(
          Progress({
            workerId: data.workerId,
            lastBlock: cursor.contents - 1,
            lifetimeEvents: lifetimeEvents.contents,
          }),
        )
      }
    }
  }

  // Announce readiness — main will respond with a chunk or drain.
  port->postWorkerMessage(Ready({workerId: data.workerId}))

  let running = ref(true)
  while running.contents {
    let msg = await nextMessage(port)
    switch msg {
    | Work({fromBlock, toBlock}) =>
      await processChunk(~fromBlock, ~toBlock)
      // Final progress for this chunk before requesting next.
      port->postWorkerMessage(
        Progress({
          workerId: data.workerId,
          lastBlock: toBlock,
          lifetimeEvents: lifetimeEvents.contents,
        }),
      )
      port->postWorkerMessage(NeedNext({workerId: data.workerId}))
    | Drain(_) =>
      // Make sure the in-flight CH insert from the last chunk has completed
      // before we tell main we're drained — otherwise the parent could exit
      // before bytes hit ClickHouse.
      let tWaitStart = Date.now()
      await pendingInsert.contents
      tInsertWait := tInsertWait.contents +. (Date.now() -. tWaitStart)
      let mb = bytesPosted.contents /. 1024. /. 1024.
      let log: string => unit = %raw(`(s) => process.stderr.write(s + "\n")`)
      log(
        `[bulk worker ${data.workerId->Int.toString} timing] events=${lifetimeEvents.contents->Float.toFixed(
            ~digits=0,
          )} fetch=${tFetch.contents->Float.toFixed(
            ~digits=0,
          )}ms decode=${tDecode.contents->Float.toFixed(
            ~digits=0,
          )}ms build=${tBuild.contents->Float.toFixed(
            ~digits=0,
          )}ms encode=${tEncode.contents->Float.toFixed(
            ~digits=0,
          )}ms ch_wait=${tInsertWait.contents->Float.toFixed(
            ~digits=0,
          )}ms posted=${mb->Float.toFixed(~digits=1)}MB`,
      )
      port->postWorkerMessage(
        Drained({workerId: data.workerId, totalEvents: lifetimeEvents.contents}),
      )
      running := false
    }
  }
}

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
    let dumpRaw: 'a => string = %raw(`(e) => {
      try {
        if (typeof e === "string") return e;
        if (e instanceof Error) {
          return (e.stack || e.message || String(e));
        }
        // Try to find a wrapped JS error inside a ReScript exception object.
        if (e && typeof e === "object") {
          for (const k of Object.keys(e)) {
            const v = e[k];
            if (v instanceof Error) return v.stack || v.message;
          }
          try { return JSON.stringify(e); } catch (_) {}
        }
        return String(e);
      } catch (_) { return "<unrenderable>"; }
    }`)
    let stack = dumpRaw(exn)
    let logRaw: string => unit = %raw(`(s) => {
      try { process.stderr.write("[bulk worker error] " + s + "\\n"); } catch (_) {}
    }`)
    logRaw(stack)
    port->postWorkerMessage(
      WorkerError({
        workerId: data.workerId,
        message: stack,
      }),
    )
    NodeJs.process->NodeJs.exitWithCode(Failure)
  }
}
