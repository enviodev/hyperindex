module GetLogs = {
  exception WrongInstance

  let query = async (
    ~client,
    ~fromBlock,
    ~toBlock,
    ~recieptsSelection,
  ): HyperFuelClient.logsQueryPage => {
    let res = await client->HyperFuelClient.getLogs(
      ~fromBlock,
      ~toBlockExclusive=switch toBlock {
      | Some(b) => Null.make(b + 1)
      | None => Null.null
      },
      ~receiptsSelection=recieptsSelection,
    )
    if res.nextBlock <= fromBlock {
      throw(WrongInstance)
    }
    res
  }
}

let queryBlockData = async (~client, ~blockNumber) =>
  (await client->HyperFuelClient.queryBlockData(~blockNumber))->Null.toOption

let heightRoute = Rest.route(() => {
  path: "/height",
  method: Get,
  input: _ => (),
  responses: [s => s.field("height", S.int)],
})
