type logsQueryPage = {
  items: array<FuelHyperSyncClient.EventItems.item>,
  // Blocks referenced by `items`, one per height.
  blocks: array<FuelHyperSyncClient.EventItems.block>,
  nextBlock: int,
  archiveHeight: int,
}

module GetLogs = {
  type error =
    | UnexpectedMissingParams({missingParams: array<string>})
    | WrongInstance

  exception Error(error)

  // Rust encodes structured failures as a JSON payload in the napi error's
  // message: `{"kind":"MissingFields","fields":["receipt.txId", ...]}`.
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
    ~client: FuelHyperSyncClient.t,
    ~fromBlock,
    ~toBlock,
    ~registrationIndexes,
    ~addressesByContractName,
  ): logsQueryPage => {
    let query: FuelHyperSyncClient.EventItems.query = {
      fromBlock,
      toBlock,
      registrationIndexes,
      addressesByContractName,
    }

    let res = switch await client->FuelHyperSyncClient.getEventItems(query) {
    | res => res
    | exception exn =>
      switch exn->extractMissingParams {
      | Some(missingParams) => throw(Error(UnexpectedMissingParams({missingParams: missingParams})))
      | None => throw(exn)
      }
    }
    if res.nextBlock <= fromBlock {
      // Might happen when /height response was from another instance of HyperFuel
      throw(Error(WrongInstance))
    }
    {
      items: res.items,
      blocks: res.blocks,
      nextBlock: res.nextBlock,
      archiveHeight: res.archiveHeight->Option.getOr(0), // TODO: FIXME: Shouldn't have a default here
    }
  }
}
