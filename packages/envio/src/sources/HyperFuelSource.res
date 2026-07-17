open Source

let isUnauthorizedError = (message: string) => message->String.includes("401 Unauthorized")

type options = {
  chain: ChainMap.Chain.t,
  endpointUrl: string,
  apiToken: option<string>,
  // The chain's registrations, indexed by their sequential `index`.
  onEventRegistrations: array<Internal.fuelOnEventRegistration>,
}

let make = ({chain, endpointUrl, apiToken, onEventRegistrations}: options): t => {
  let name = "HyperFuel"

  let apiToken = switch apiToken {
  | Some(token) => token
  | None =>
    JsError.throwWithMessage(`An Envio API token is required for using HyperFuel as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`)
  }

  let client = switch HyperFuelClient.make(
    {url: endpointUrl, apiToken},
    ~eventRegistrations=HyperFuelClient.Registration.fromOnEventRegistrations(onEventRegistrations),
  ) {
  | client => client
  | exception exn =>
    exn->ErrorHandling.mkLogAndRaise(~msg="Failed to instantiate the HyperFuel client")
  }

  let getItemsOrThrow = async (
    ~fromBlock,
    ~toBlock,
    ~addressesByContractName,
    ~contractNameByAddress as _,
    ~knownHeight,
    ~partitionId as _,
    ~selection: FetchState.selection,
    ~itemsTarget as _,
    ~retry,
    ~logger,
  ) => {
    let totalTimeRef = Performance.now()

    let startFetchingBatchTimeRef = Performance.now()

    //fetch batch
    let pageUnsafe = try await HyperFuel.GetLogs.query(
      ~client,
      ~fromBlock,
      ~toBlock,
      ~registrationIndexes=selection.onEventRegistrations->Array.map(reg => reg.index),
      ~addressesByContractName,
    ) catch {
    | HyperFuel.GetLogs.Error(error) =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn: %raw(`null`),
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: switch error {
            | WrongInstance =>
              let backoffMillis = switch retry {
              | 0 => 100
              | _ => 500 * retry
              }
              WithBackoff({
                message: `Block #${fromBlock->Int.toString} not found in HyperFuel. HyperFuel has multiple instances and it's possible that they drift independently slightly from the head. Indexing should continue correctly after retrying the query in ${backoffMillis->Int.toString}ms.`,
                backoffMillis,
              })
            | UnexpectedMissingParams({missingParams}) =>
              ImpossibleForTheQuery({
                message: `Source returned invalid data with missing required fields: ${missingParams->Array.joinUnsafe(
                    ", ",
                  )}`,
              })
            },
          }),
        ),
      )
    | exn =>
      throw(
        Source.GetItemsError(
          Source.FailedGettingItems({
            exn,
            attemptedToBlock: toBlock->Option.getOr(knownHeight),
            retry: WithBackoff({
              message: `Unexpected issue while fetching events from HyperFuel client. Attempt a retry.`,
              backoffMillis: switch retry {
              | 0 => 500
              | _ => 1000 * retry
              },
            }),
          }),
        ),
      )
    }

    let pageFetchTime = startFetchingBatchTimeRef->Performance.secondsSince
    let requestStats = [{Source.method: "getLogs", seconds: pageFetchTime}]

    //set height and next from block
    let knownHeight = pageUnsafe.archiveHeight

    //The heighest (biggest) blocknumber that was accounted for in
    //Our query. Not necessarily the blocknumber of the last log returned
    //In the query
    let heighestBlockQueried = pageUnsafe.nextBlock - 1

    let parsingTimeRef = Performance.now()

    // Blocks are returned once per height; items reference them by blockHeight.
    let blocksByHeight = Utils.Map.make()
    pageUnsafe.blocks->Array.forEach(block => {
      blocksByHeight->Utils.Map.set(block.height, block)->ignore
    })

    let chainId = chain->ChainMap.Chain.toChainId

    let parsedQueueItems = pageUnsafe.items->Array.map(item => {
      // Routing happened in Rust; the item references its registration by
      // chain-scoped index.
      let onEventRegistration = onEventRegistrations->Array.getUnsafe(item.onEventRegistrationIndex)
      let eventConfig =
        onEventRegistration.eventConfig->(
          Utils.magic: Internal.eventConfig => Internal.fuelEventConfig
        )
      // Presence of every routed item's block is validated in Rust.
      let block = blocksByHeight->Utils.Map.unsafeGet(item.blockHeight)

      let params = switch eventConfig.kind {
      | LogData({decode}) =>
        // Kind-required columns are validated present in Rust before the item
        // crosses the boundary.
        let data = item.data->Option.getOr("")
        try decode(data) catch {
        | exn => {
            let params = {
              "chainId": chainId,
              "blockNumber": item.blockHeight,
              "logIndex": item.receiptIndex,
            }
            let logger = Logging.createChildFrom(~logger, ~params)
            exn->ErrorHandling.mkLogAndRaise(
              ~msg="Failed to decode Fuel LogData receipt, please double check your ABI.",
              ~logger,
            )
          }
        }
      | Mint | Burn =>
        (
          {
            subId: item.subId->Option.getOr(""),
            amount: item.val->Option.getOr(0n),
          }: Internal.fuelSupplyParams
        )->Obj.magic
      | Transfer | Call =>
        (
          {
            to: item.to->Option.getOr("")->Address.unsafeFromString,
            assetId: item.assetId->Option.getOr(""),
            amount: item.amount->Option.getOr(0n),
          }: Internal.fuelTransferParams
        )->Obj.magic
      }

      Internal.Event({
        onEventRegistration,
        chain,
        blockNumber: item.blockHeight,
        logIndex: item.receiptIndex,
        // Fuel carries the transaction inline on the payload; the store key is
        // unused (Fuel identifies transactions by hash, kept on the payload).
        transactionIndex: 0,
        payload: {
          contractName: eventConfig.contractName,
          eventName: eventConfig.name,
          chainId,
          params,
          transaction: {
            "id": item.txId,
          }->Obj.magic, // TODO: Obj.magic needed until the field selection types are not configurable for Fuel and Evm separately
          block: block->Obj.magic,
          srcAddress: item.srcAddress,
          logIndex: item.receiptIndex,
        }->Fuel.fromPayload,
      })
    })

    let parsingTimeElapsed = parsingTimeRef->Performance.secondsSince

    // Fuel never rolls back on reorg, so block hashes here are purely informational
    // for detect-only logging via ReorgDetection.
    let blockHashes = pageUnsafe.blocks->Array.map(block => {
      ReorgDetection.blockNumber: block.height,
      blockHash: block.id,
    })

    let latestFetchedBlockTimestamp = switch blocksByHeight->Utils.Map.get(heighestBlockQueried) {
    | Some(block) => block.time
    | None => 0
    }

    let totalTimeElapsed = totalTimeRef->Performance.secondsSince

    let stats = {
      totalTimeElapsed,
      parsingTimeElapsed,
      pageFetchTime,
    }

    {
      latestFetchedBlockTimestamp,
      parsedQueueItems,
      // Fuel keeps transaction and block on the payload; no store pages.
      transactionStore: None,
      blockStore: None,
      latestFetchedBlockNumber: heighestBlockQueried,
      stats,
      knownHeight,
      blockHashes,
      fromBlockQueried: fromBlock,
      requestStats,
    }
  }

  let getBlockHashes = (~blockNumbers as _, ~logger as _) =>
    JsError.throwWithMessage("HyperFuel does not support getting block hashes")

  {
    name,
    sourceFor: Sync,
    chain,
    getBlockHashes,
    pollingInterval: 100,
    poweredByHyperSync: true,
    getHeightOrThrow: async () => {
      let timerRef = Performance.now()
      let height = try await client->HyperFuelClient.getHeight catch {
      | JsExn(e) =>
        switch e->JsExn.message {
        | Some(message) if message->isUnauthorizedError =>
          Logging.error(`Your ENVIO_API_TOKEN was rejected by HyperFuel (401 Unauthorized). The indexer will not be able to fetch events. Update the token and try again using 'envio start' or 'envio dev'. For more info: https://docs.envio.dev/docs/HyperSync/api-tokens`)
          // Retrying an unauthorized request can never succeed, so block forever
          let _ = await Promise.make((_, _) => ())
          0
        | _ => throw(JsExn(e))
        }
      }
      let seconds = timerRef->Performance.secondsSince
      {height, requestStats: [{method: "getHeight", seconds}]}
    },
    getItemsOrThrow,
  }
}
