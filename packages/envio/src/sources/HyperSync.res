let mapRateLimitedExn = exn => {
  let failure = exn->Source.unpackNativeRequestFailure
  switch failure.message {
  | Some(msg) if msg->String.startsWith("RATE_LIMITED:") =>
      let resetMs =
        msg
        ->String.slice(~start=13, ~end=msg->String.length)
        ->Int.fromString
        ->Option.getOr(1000)
    Source.RateLimited({resetMs: resetMs})
  | _ => failure.cause
  }
}

let reraiseIfRateLimited = exn =>
  switch exn->mapRateLimitedExn {
  | Source.RateLimited(_) as exn => throw(exn)
  | _ => ()
  }

type logsQueryPage = {
  items: array<HyperSyncClient.EventItems.item>,
  // Block headers referenced by `items`, deduplicated by block number.
  blocks: array<HyperSyncClient.EventItems.blockHeader>,
  nextBlock: int,
  archiveHeight: int,
  rollbackGuard: option<HyperSyncClient.ResponseTypes.rollbackGuard>,
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
    ~addressesByContractName,
  ): logsQueryPage => {
    let query: HyperSyncClient.EventItems.query = {
      fromBlock,
      toBlock,
      maxNumLogs,
      registrationIndexes,
      addressesByContractName,
    }

    let (res, transactionStore, blockStore) = switch await client.getEventItems(~query) {
    | res => res
    | exception exn =>
      reraiseIfRateLimited(exn)
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
      blocks: res.blocks,
      nextBlock: res.nextBlock,
      archiveHeight: res.archiveHeight->Option.getOr(0), //Archive Height is only None if height is 0
      rollbackGuard: res.rollbackGuard,
      transactionStore,
      blockStore,
    }
  }
}
