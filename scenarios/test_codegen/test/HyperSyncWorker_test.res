open RescriptMocha

module GetNextPage = {
  type queryLogsPageCall = {
    fromBlock: int,
    toBlock: int,
    logSelections: array<LogSelection.t>,
    fieldSelection: HyperSyncClient.QueryTypes.fieldSelection,
    nonOptionalBlockFieldNames: array<string>,
    nonOptionalTransactionFieldNames: array<string>,
  }

  type mock = {queryLogsPageCalls: array<queryLogsPageCall>}

  let mock = (~blockSchema=S.object(_ => ()), ~transactionSchema=S.object(_ => ())) => {
    let queryLogsPageCalls = []

    let endpointUrl = "https://hypersync.xyz"
    let queryResponse = %raw(`Symbol("queryResponse")`)
    let contracts = []
    let queryLogsPage = async (
      ~client as _,
      ~fromBlock,
      ~toBlock,
      ~logSelections,
      ~fieldSelection,
      ~nonOptionalBlockFieldNames,
      ~nonOptionalTransactionFieldNames,
      ~logger as _,
    ) => {
      queryLogsPageCalls
      ->Js.Array2.push({
        fromBlock,
        toBlock,
        logSelections,
        fieldSelection,
        nonOptionalBlockFieldNames,
        nonOptionalTransactionFieldNames,
      })
      ->ignore
      Ok(queryResponse)
    }
    let fn = HyperSyncWorker.makeGetNextPage(
      ~endpointUrl,
      ~contracts,
      ~queryLogsPage,
      ~blockSchema,
      ~transactionSchema,
    )

    (
      fn,
      {
        queryLogsPageCalls: queryLogsPageCalls,
      },
    )
  }
}

describe("HyperSyncWorker - getNextPage", () => {
  Async.it(
    "Correctly builds logs query field selection for empty block and transaction schemas",
    async () => {
      let (getNextPage, mock) = GetNextPage.mock(
        ~blockSchema=S.object(_ => ()),
        ~transactionSchema=S.object(_ => ()),
      )

      let _ = await getNextPage(
        ~fromBlock=1,
        ~toBlock=2,
        ~logger=Logging.logger,
        ~contractAddressMapping=ContractAddressingMap.make(),
        ~shouldApplyWildcards=true,
        ~isPreRegisteringDynamicContracts=false,
      )

      Assert.deepEqual(
        mock.queryLogsPageCalls,
        [
          {
            fromBlock: 1,
            toBlock: 2,
            logSelections: [],
            fieldSelection: {
              block: [],
              transaction: [],
              log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
            },
            nonOptionalBlockFieldNames: [],
            nonOptionalTransactionFieldNames: [],
          },
        ],
      )
    },
  )

  Async.it(
    "Correctly builds logs query field selection for complex block and transaction schemas",
    async () => {
      let (getNextPage, mock) = GetNextPage.mock(
        ~blockSchema=S.object(
          s => {
            let _ = s.field("hash", S.string)
            let _ = s.field("number", S.int)
            let _ = s.field("timestamp", S.int)
            let _ = s.field("nonce", S.null(BigInt.schema))
          },
        ),
        ~transactionSchema=S.object(
          s => {
            let _ = s.field("hash", S.string)
            let _ = s.field("gasPrice", S.null(S.string))
          },
        ),
      )

      let _ = await getNextPage(
        ~fromBlock=1,
        ~toBlock=2,
        ~logger=Logging.logger,
        ~contractAddressMapping=ContractAddressingMap.make(),
        ~shouldApplyWildcards=true,
        ~isPreRegisteringDynamicContracts=false,
      )

      Assert.deepEqual(
        mock.queryLogsPageCalls,
        [
          {
            fromBlock: 1,
            toBlock: 2,
            logSelections: [],
            fieldSelection: {
              block: [Hash, Number, Timestamp, Nonce],
              transaction: [Hash, GasPrice],
              log: [Address, Data, LogIndex, Topic0, Topic1, Topic2, Topic3],
            },
            nonOptionalBlockFieldNames: ["hash", "number", "timestamp"],
            nonOptionalTransactionFieldNames: ["hash"],
          },
        ],
      )
    },
  )
})
