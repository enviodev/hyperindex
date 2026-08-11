// A napi error carries nothing but a message, so the native clients signal the
// recoverable conditions SourceManager knows how to retry as a `PREFIX:<int>`
// marker. Keep in sync with `request_stats.rs`.
let rateLimitedPrefix = "RATE_LIMITED:"
let behindHeadPrefix = "SOURCE_BEHIND_HEAD:"

let markerValue = (msg, ~prefix) =>
  msg->String.slice(~start=prefix->String.length, ~end=msg->String.length)->Int.fromString

let mapNativeFailure = (failure: Source.nativeRequestFailure) => {
  switch failure.message {
  | Some(msg) if msg->String.startsWith(rateLimitedPrefix) =>
    Source.RateLimited({
      resetMs: msg->markerValue(~prefix=rateLimitedPrefix)->Option.getOr(1000),
      requestStats: failure.requestStats,
    })
  | Some(msg) if msg->String.startsWith(behindHeadPrefix) =>
    Source.SourceBehindHead({
      blockNumber: msg->markerValue(~prefix=behindHeadPrefix)->Option.getOr(0),
      requestStats: failure.requestStats,
    })
  | _ => failure.cause
  }
}

let mapNativeFailureExn = exn => exn->Source.unpackNativeRequestFailure->mapNativeFailure

// Every HyperSync client paginates block hashes in Rust and returns the page
// store with the timings of the requests it took. A failure arrives as the
// native envelope, which carries those same timings, so the caller records them
// either way.
let makeGetBlockHashes = (
  ~query: (~blockNumbers: array<int>) => promise<(BlockStore.t, array<Source.requestStat>)>,
) =>
  async (~blockNumbers, ~logger as _) => {
    let (result, requestStats) = try {
      let (blockStore, requestStats) = await query(~blockNumbers)
      (Ok(blockStore), requestStats)
    } catch {
    | exn =>
      let failure = exn->Source.unpackNativeRequestFailure
      (Error(failure->mapNativeFailure), failure.requestStats)
    }
    {Source.result, requestStats}
  }

let reraiseIfRecoverable = exn =>
  switch exn->mapNativeFailureExn {
  | (Source.RateLimited(_) | Source.SourceBehindHead(_)) as exn => throw(exn)
  | _ => ()
  }

type logsQueryPage = {
  items: array<HyperSyncClient.EventItems.item>,
  nextBlock: int,
  archiveHeight: int,
  // Page store owning this page's raw transactions.
  transactionStore: TransactionStore.t,
  // Page store owning this page's raw blocks.
  blockStore: BlockStore.t,
}

module GetLogs = {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  // Rust encodes structured failures as a JSON payload in the napi error's
  // message: `{"kind":"MissingFields","fields":["block.timestamp", ...]}`.
  // JSON.parse + shape check is the recovery protocol — no string-grepping
  // on anyhow's Debug format.
  let extractMissingParams = (exn: exn): option<array<string>> => {
    let message = switch exn {
    | JsExn(jsExn) => jsExn->JsExn.message
    | _ => None
    }
    switch message {
    | None => None
    | Some(msg) =>
      switch msg->JSON.parseOrThrow->JSON.Decode.object {
      | exception _ => None
      | None => None
      | Some(obj) =>
        switch (obj->Dict.get("kind"), obj->Dict.get("fields")) {
        | (Some(String("MissingFields")), Some(Array(fields))) =>
          Some(fields->Array.filterMap(JSON.Decode.string))
        | _ => None
        }
      }
    }
  }

  let query = async (
    ~client: HyperSyncClient.t,
    ~fromBlock,
    ~toBlock,
    ~maxNumLogs,
    ~registrationIndexes,
    ~addressSet,
    ~clientFilteredContracts,
  ): logsQueryPage => {
    let query: HyperSyncClient.EventItems.query = {
      fromBlock,
      toBlock,
      ?maxNumLogs,
      registrationIndexes,
      clientFilteredContracts,
    }

    let (res, transactionStore, blockStore) = switch await client.getEventItems(
      ~query,
      ~addressSet,
    ) {
    | res => res
    | exception exn =>
      reraiseIfRecoverable(exn)
      switch extractMissingParams(exn) {
      | Some(missingParams) => throw(Error(UnexpectedMissingParams({missingParams: missingParams})))
      | None => throw(exn)
      }
    }
    if res.nextBlock <= fromBlock {
      // Might happen when /height response was from another instance of HyperSync
      throw(Error(WrongInstance))
    }

    {
      items: res.items,
      nextBlock: res.nextBlock,
      archiveHeight: res.archiveHeight->Option.getOr(0), //Archive Height is only None if height is 0
      transactionStore,
      blockStore,
    }
  }
}
