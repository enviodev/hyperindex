// The exponent stops growing once the cap is reached, so an outage of any
// length never overflows the delay.
let retryDelayMillis = (~attempt) =>
  Math.Int.min(500 * Math.Int.pow(2, ~exp=Math.Int.min(attempt, 4)), 5_000)

// Long enough for a restart, a failover or a pooler blip. Past it the outage is
// for an operator to look at, and a process that exits is what a supervisor
// and its alerting notice.
let deadlineSeconds = 60

let retryTimerLabel = "Storage retry"

let lostConnectionMsg = "Lost the connection to the database. Retrying until it answers."

let unreachableMsg = `The database has been unreachable for ${deadlineSeconds->Int.toString} seconds. The "Lost the connection to the database" warnings above show the error behind it. Check that Postgres is running and that ENVIO_PG_HOST and ENVIO_PG_PORT point at it. Once the issue is resolved and the indexer is restarted, it resumes from the last block it saved.`

// Only for work storage raises `ConnectionLost` from, which is work that is
// safe to send again. The deadline counts from this call's own first failure,
// and the last attempt is made at it; if that fails too, the indexer stops with
// `unreachableMsg`. None once the indexer has stopped, for that or any other
// reason. A call that fails after another one stopped the indexer says
// nothing: a warning that it is retrying would contradict the error before it.
let retryUntilReachable = async (state: IndexerState.t, ~operation, work) => {
  let clock = state->IndexerState.clock
  let deadlineMillis = deadlineSeconds * 1000
  let rec attemptFrom = async (attempt, ~firstFailedAt) =>
    switch await work() {
    | value => Some(value)
    | exception Persistence.ConnectionLost(_) if state->IndexerState.isStopped => None
    | exception Persistence.ConnectionLost(message) =>
      let firstFailedAt = firstFailedAt->Option.getOr(clock.now())
      let leftMillis = deadlineMillis - (clock.now() -. firstFailedAt)->Float.toInt
      if leftMillis <= 0 {
        state->IndexerState.errorExit(
          Utils.Error.make(message)->ErrorHandling.make(
            ~logger=state->IndexerState.logger,
            ~msg=unreachableMsg,
          ),
        )
        None
      } else {
        let delayMillis = Math.Int.min(clock->Clock.jitter(retryDelayMillis(~attempt)), leftMillis)
        state
        ->IndexerState.logger
        ->Logger.warn(
          lostConnectionMsg,
          ~params={
            "operation": operation,
            "err": message,
            "attempt": attempt + 1,
            "retryInMillis": delayMillis,
            "stopsInSeconds": (leftMillis + 999) / 1000,
          },
        )
        await clock->Clock.delay(~label=retryTimerLabel, delayMillis)
        state->IndexerState.isStopped
          ? None
          : await attemptFrom(attempt + 1, ~firstFailedAt=Some(firstFailedAt))
      }
    }
  await attemptFrom(0, ~firstFailedAt=None)
}
