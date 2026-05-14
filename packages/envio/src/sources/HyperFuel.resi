module GetLogs: {
  exception WrongInstance

  let query: (
    ~client: HyperFuelClient.t,
    ~fromBlock: int,
    ~toBlock: option<int>,
    ~recieptsSelection: array<HyperFuelClient.receiptSelection>,
  ) => promise<HyperFuelClient.logsQueryPage>
}

let queryBlockData: (
  ~client: HyperFuelClient.t,
  ~blockNumber: int,
) => promise<option<ReorgDetection.blockDataWithTimestamp>>

let heightRoute: Rest.route<unit, int>
