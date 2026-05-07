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

// Minimal field selection for bulk ERC20 Transfer. Drops Topic3 (always
// empty for Transfer) and the entire transaction sub-object (we no longer
// store tx_hash). Address has to stay because HyperSync.convertEvent
// asserts it's present on every page item; we ignore the value at runtime
// (single-contract assumption stamps `contract` from workerData) but the
// SDK still ships it. Topic0..Topic2 stay so positional indexing into
// `topics[]` matches our `topics[1]`/`topics[2]` reads.
let buildFieldSelection = (): HyperSyncClient.QueryTypes.fieldSelection => {
  block: [Number, Timestamp],
  log: [LogIndex, Address, Topic0, Topic1, Topic2, Data],
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

  // Bounded queue of in-flight CH inserts. With streamEvents firing batches
  // very fast, allowing only one in-flight POST stalls the fetch/decode path
  // behind ClickHouse. We let up to N inserts overlap; the (N+1)th waits for
  // the oldest to drain. Tunable via ENVIO_BULK_CH_INFLIGHT.
  let chInFlightLimit = switch %raw(`process.env.ENVIO_BULK_CH_INFLIGHT`)->Nullable.toOption {
  | Some(s) =>
    switch Belt.Int.fromString(s) {
    | Some(n) if n > 0 => n
    | _ => 4
    }
  | None => 4
  }
  let inFlightInserts: array<promise<unit>> = []

  // Per-phase timing accumulators in milliseconds. Reported at drain so we
  // can see where the worker is spending its time without per-iteration log
  // overhead.
  let tFetch = ref(0.)
  let tDecode = ref(0.)
  let tBuild = ref(0.)
  let tEncode = ref(0.)
  let tInsertWait = ref(0.)
  let bytesPosted = ref(0.)

  // Per-worker server-side concurrency for HyperSync. With an unlimited
  // token the cap is server CPU + per-worker decode CPU rather than the
  // token's per-second rate. Default 16 (above the SDK default of 10) so
  // the firehose stays full; tune via env var when contending across many
  // workers on the same token.
  let serverConcurrency = switch %raw(`process.env.ENVIO_BULK_HS_CONCURRENCY`)->Nullable.toOption {
  | Some(s) =>
    switch Belt.Int.fromString(s) {
    | Some(n) => n
    | None => 16
    }
  | None => 16
  }

  let _ = serverConcurrency // streamEvents disabled in this build

  // Single-contract assumption: the contract column on every row is just
  // the address we filtered on, so we can stamp it from workerData and skip
  // both the per-row Address field on the wire and the runtime decoder.
  let contractFixed = data.contractAddresses->Belt.Array.get(0)->Belt.Option.getWithDefault("0x")

  // BigInt(value-hex).toString() for the uint256 `value` column. JS BigInt
  // accepts "0x..." directly. Cheaper than HyperSync's full ABI decoder
  // because we know the wire format up-front: one 32-byte word, no dynamic
  // types, no signature lookup.
  let hexDataToDecimalString: string => string = %raw(`function(data) {
    if (!data || data.length < 3) return "0";
    try { return BigInt(data).toString(); }
    catch (_) { return "0"; }
  }`)

  // Process one HyperSync response: extract columns inline (no ABI decoder
  // call), encode RowBinary, queue CH POST. Mutates `inFlightInserts`,
  // `lifetimeEvents`, and the per-phase timing refs from the enclosing scope.
  let processPage = async (~page: HyperSync.logsQueryPage) => {
    let pageItemCount = page.items->Array.length
    if pageItemCount > 0 {
      // The decoder phase is now a no-op — Transfer's wire layout is fixed,
      // so we extract from/to/value directly from the log topics + data
      // without paying the per-event ABI decode cost. Keep the timing label
      // so traces stay comparable across versions.
      let tDecodeStart = Date.now()
      tDecode := tDecode.contents +. (Date.now() -. tDecodeStart)
      let tBuildStart = Date.now()

      let chainIds = Uint32Array.fromLength(pageItemCount)
      let blockNumbers = Uint32Array.fromLength(pageItemCount)
      let blockTimestampsMs = Float64Array.fromLength(pageItemCount)
      let logIndices = Uint32Array.fromLength(pageItemCount)
      let contractsHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
      let fromsHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
      let tosHex = Belt.Array.makeUninitializedUnsafe(pageItemCount)
      let valuesDec = Belt.Array.makeUninitializedUnsafe(pageItemCount)

      let written = ref(0)
      for idx in 0 to pageItemCount - 1 {
        let item: HyperSync.logsQueryPageItem = page.items->Array.getUnsafe(idx)
        switch (item.block.number, item.block.timestamp) {
        | (Some(blockNumber), Some(blockTs)) =>
          let from = switch item.log.topics->Belt.Array.get(1) {
          | Some(t) => t->EvmTypes.Hex.toString->topicToAddress
          | None => ""
          }
          let to_ = switch item.log.topics->Belt.Array.get(2) {
          | Some(t) => t->EvmTypes.Hex.toString->topicToAddress
          | None => ""
          }
          let value = hexDataToDecimalString(item.log.data)
          let w = written.contents
          chainIds->u32Set(w, data.chainId)
          blockNumbers->u32Set(w, blockNumber)
          blockTimestampsMs->f64Set(w, (blockTs * 1000)->Int.toFloat)
          logIndices->u32Set(w, item.log.logIndex)
          contractsHex->Belt.Array.setUnsafe(w, contractFixed)
          fromsHex->Belt.Array.setUnsafe(w, from)
          tosHex->Belt.Array.setUnsafe(w, to_)
          valuesDec->Belt.Array.setUnsafe(w, value)
          written := w + 1
        | _ => ()
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
          ~contractsHex,
          ~fromsHex,
          ~tosHex,
          ~valuesDec,
          ~rowCount,
        )
        tEncode := tEncode.contents +. (Date.now() -. tEncodeStart)
        let bufLen: 'a => float = %raw(`(b) => b.length`)
        bytesPosted := bytesPosted.contents +. bufLen(buf)
        let tWaitStart = Date.now()
        if inFlightInserts->Array.length >= chInFlightLimit {
          let oldest = inFlightInserts->Array.shift->Belt.Option.getUnsafe
          await oldest
        }
        tInsertWait := tInsertWait.contents +. (Date.now() -. tWaitStart)
        let next = BulkRowBinary.insertRowBinary(
          ~url=data.clickhouseUrl,
          ~database=data.clickhouseDatabase,
          ~table=data.tableName,
          ~username=data.clickhouseUsername,
          ~password=data.clickhousePassword,
          ~body=buf,
        )
        inFlightInserts->Array.push(next)
        lifetimeEvents := lifetimeEvents.contents +. rowCount->Int.toFloat
      }
    }
  }

  let streamConfig: HyperSyncClient.streamConfig = {concurrency: serverConcurrency}

  // Process one block range with `collectEvents` — the SDK runs `concurrency`
  // parallel sub-queries server-side and returns one combined response per
  // round trip. Cursor advances by `nextBlock`, looping if the response was
  // capped. The in-flight CH pipeline keeps the upload side from stalling
  // fetch/decode.
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
        ~streamConfig,
        ~nonOptionalBlockFieldNames=["number", "timestamp"],
        ~nonOptionalTransactionFieldNames=[],
      )
      tFetch := tFetch.contents +. (Date.now() -. tFetchStart)
      cursor := page.nextBlock
      await processPage(~page)
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
      // Drain all in-flight CH inserts before signalling done so the parent
      // never exits while bytes are still on the way to ClickHouse.
      let tWaitStart = Date.now()
      while inFlightInserts->Array.length > 0 {
        let oldest = inFlightInserts->Array.shift->Belt.Option.getUnsafe
        await oldest
      }
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
