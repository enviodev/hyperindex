// From half a second, doubling, up to five. The exponent stops growing once the
// cap is reached, so an outage of any length never overflows the delay.
let retryDelayMillis = (~attempt) =>
  Math.Int.min(500 * Math.Int.pow(2, ~exp=Math.Int.min(attempt, 4)), 5_000)

let lostConnectionMsg = "Lost the database connection. Trying again once it answers"

// Runs `work` until it gets through, running it again for as long as the
// database connection goes before it did. Only for work storage raises
// `ConnectionLost` from, which is work that is safe to send again. There is no
// deadline: the indexer waits out an outage of any length, saying so on every
// attempt. None when the indexer stopped meanwhile.
let rec untilReachable = async (state: IndexerState.t, ~operation, ~attempt=0, work) =>
  switch await work() {
  | value => Some(value)
  | exception Persistence.ConnectionLost(message) =>
    let clock = state->IndexerState.clock
    let delayMillis = clock->Clock.jitter(retryDelayMillis(~attempt))
    state
    ->IndexerState.logger
    ->Logger.warn(
      lostConnectionMsg,
      ~params={
        "operation": operation,
        "err": message,
        "attempt": attempt + 1,
        "retryInMillis": delayMillis,
      },
    )
    await clock->Clock.delay(~label="Storage retry", delayMillis)
    state->IndexerState.isStopped
      ? None
      : await untilReachable(state, ~operation, ~attempt=attempt + 1, work)
  }
