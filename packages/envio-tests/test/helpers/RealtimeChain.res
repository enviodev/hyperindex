// Steps that take a single-chain scenario to its realtime wait, where height
// streams open, so the height tests can start from a known state.

let streaming: array<MockSource.method> = [
  #getHeightOrThrow,
  #getItemsOrThrow,
  #createHeightSubscription,
]

let polls = (mock: MockSource.t) => mock.getHeightOrThrowCalls->Array.length

let upTo = toBlock => MockSource.Respond({items: [], latestFetchedBlockNumber: toBlock})

// Answers the query a new head starts, which puts the chain back to waiting.
let answerQuery = async (mock: MockSource.t, ~fromBlock, ~toBlock) =>
  await mock.expectItemsQueries([{fromBlock, reply: upTo(toBlock)}])

// Backfills to `head` on `sync`, after which the chain's realtime wait
// subscribes `mock`. The poll the last backfill wait left in flight is still
// out, and the realtime wait takes it over rather than asking again.
let reach = async (~sync: MockSource.t, ~mock=sync, ~head=100) => {
  sync.resolveGetHeightOrThrow(head)
  await sync->answerQuery(~fromBlock=1, ~toBlock=head)
  await Scenario.waitUntil(
    () => mock.heightSubscriptionCalls->Array.length > 0,
    ~message="the height subscription",
  )
}

// Takes a freshly subscribed source to a live stream that has delivered: the
// catch-up poll its connect fires is answered, the stream pushes `head + 1`,
// and the query for it is answered. The chain is left waiting above `head + 1`
// with no poll in flight, the stream carrying the wait on its own.
let goLive = async (mock: MockSource.t, ~head=100) => {
  mock.resolveGetHeightOrThrow(head)
  let pollsBeforeLive = mock->polls
  mock.setHeightSubscriptionStatus(Live)
  await mock.expectHeightCalls(pollsBeforeLive + 1)
  mock.resolveGetHeightOrThrow(head)
  mock.triggerHeightSubscription(head + 1)
  await mock->answerQuery(~fromBlock=head + 1, ~toBlock=head + 1)
}

// The intervals the height polling logged it would back off for, in order.
let heightRetryIntervals = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()->Array.filterMap(line =>
    switch line->Dict.get("msg") {
    | Some(String(msg)) =>
      msg
      ->String.match(/^Height retrieval from MockSource source .*Retrying in (\d+)ms\.$/)
      ->Option.flatMap(match => match->Array.get(1)->Option.flatMap(x => x))
    | _ => None
    }
  )
