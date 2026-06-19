type hyperSyncPage<'item> = {
  items: array<'item>,
  nextBlock: int,
  archiveHeight: int,
}

type block = {
  id: string,
  time: int,
  height: int,
}

type item = {
  transactionId: string,
  contractId: Address.t,
  receipt: FuelSDK.Receipt.t,
  receiptIndex: int,
  block: block,
}

type logsQueryPage = hyperSyncPage<item>

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

  let makeRequestBody = (
    ~fromBlock,
    ~toBlockInclusive,
    ~recieptsSelection,
  ): HyperFuelClient.QueryTypes.query => {
    {
      fromBlock,
      toBlockExclusive: ?switch toBlockInclusive {
      | Some(toBlockInclusive) => Some(toBlockInclusive + 1)
      | None => None
      },
      receipts: recieptsSelection,
      fieldSelection: {
        receipt: [
          TxId,
          BlockHeight,
          RootContractId,
          Data,
          ReceiptIndex,
          ReceiptType,
          Rb,
          // TODO: Include them only when there's a mint/burn/transferOut receipt selection
          SubId,
          Val,
          Amount,
          ToAddress,
          AssetId,
          To,
        ],
        block: [Id, Height, Time],
      },
    }
  }

  let getParam = (param, name) => {
    switch param {
    | Some(v) => v
    | None =>
      throw(
        Error(
          UnexpectedMissingParams({
            missingParams: [name],
          }),
        ),
      )
    }
  }

  //Note this function can throw an error
  let decodeLogQueryPageItems = (response_data: HyperFuelClient.queryResponseDataTyped): array<
    item,
  > => {
    let {receipts, blocks} = response_data

    let blocksDict = Dict.make()
    blocks->Array.forEach(block => {
      blocksDict->Dict.set(block.height->(Utils.magic: int => string), block)
    })

    let items = []

    receipts->Array.forEach(receipt => {
      switch receipt.rootContractId {
      | None => ()
      | Some(contractId) => {
          let block =
            blocksDict
            ->Utils.Dict.dangerouslyGetNonOption(receipt.blockHeight->(Utils.magic: int => string))
            ->getParam("Failed to find block associated to receipt")
          items
          ->Array.push({
            transactionId: receipt.txId,
            block: {
              height: block.height,
              id: block.id,
              time: block.time,
            },
            contractId,
            receipt: receipt->(Utils.magic: HyperFuelClient.FuelTypes.receipt => FuelSDK.Receipt.t),
            receiptIndex: receipt.receiptIndex,
          })
          ->ignore
        }
      }
    })
    items
  }

  let convertResponse = (res: HyperFuelClient.queryResponseTyped): logsQueryPage => {
    let {nextBlock, ?archiveHeight} = res
    let page: logsQueryPage = {
      items: res.data->decodeLogQueryPageItems,
      nextBlock,
      archiveHeight: archiveHeight->Option.getOr(0), // TODO: FIXME: Shouldn't have a default here
    }
    page
  }

  let query = async (
    ~client: HyperFuelClient.t,
    ~fromBlock,
    ~toBlock,
    ~recieptsSelection,
  ): logsQueryPage => {
    let query: HyperFuelClient.QueryTypes.query = makeRequestBody(
      ~fromBlock,
      ~toBlockInclusive=toBlock,
      ~recieptsSelection,
    )

    let res = switch await client->HyperFuelClient.getSelectedData(query) {
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
    res->convertResponse
  }
}
