// Delivers committed `context.sidecar` calls to the sidecar's internal server
// (wiki/06-api-v0.md 6.1, 6.2; wiki/09-reliability.md 3). One ordered queue
// per indexer process and a single sender draining it, so a rollback notice
// is never overtaken by calls committed after it. Handing calls over is
// synchronous: the write loop never waits for the sidecar.

type rollbackTarget = {chainId: ChainId.t, rollbackToBlock: int}

type item = Rollback(rollbackTarget) | Call(SidecarCall.t)

type stats = {
  queued: int,
  sent: int,
  rollbacksSent: int,
  dropped: dict<int>,
}

type t = {
  url: string,
  queueMax: int,
  callsTimeoutMs: int,
  rollbackTimeoutMs: int,
  backoffBaseMs: int,
  backoffCapMs: int,
  // Bound by the indexer state that owns the sender, which turns them into the
  // built-in `sidecar.ack` and `sidecar.dropped` webhooks.
  mutable onAcked: array<SidecarCall.t> => unit,
  mutable onDropped: (array<SidecarCall.t>, ~reason: string) => unit,
  queue: array<item>,
  // Taken off the queue for the POST under way, and resent as they are while
  // it keeps failing. Still counted against the bound.
  mutable inFlight: array<SidecarCall.t>,
  mutable sent: int,
  mutable rollbacksSent: int,
  dropped: dict<int>,
  mutable draining: bool,
  mutable stopped: bool,
  mutable batchCount: int,
  mutable idleWaiters: array<unit => unit>,
}

// What the runtime accepts in one POST is bounded by its 10 MB body limit, not
// a count; 500 keeps a body well under it.
let maxCallsPerPost = 500

let pid: int = %raw(`process.pid`)

// Unref'd, so a sender waiting out a backoff never keeps the process alive.
let sleep: int => promise<
  unit,
> = %raw(`ms => new Promise(resolve => setTimeout(resolve, ms).unref())`)

type response
type signal
type fetchInit = {method: string, headers: dict<string>, body: string, signal: signal}
@val external fetch: (string, fetchInit) => promise<response> = "fetch"
@get external status: response => int = "status"
@send external json: response => promise<JSON.t> = "json"
@val @scope("AbortSignal") external timeoutSignal: int => signal = "timeout"

type outcome =
  | Delivered(JSON.t)
  // Connection refused, timeout, 5xx (the runtime's 503 while closing
  // included) or 429: the sidecar can take it later.
  | Retry(string)
  // Any other non-2xx: the payload itself is wrong, resending won't help.
  | Refused(int)

let post = async (t, ~path, ~body: JSON.t, ~timeoutMs) =>
  switch await fetch(
    t.url ++ path,
    {
      method: "POST",
      headers: dict{"content-type": "application/json"},
      body: body->JSON.stringify,
      signal: timeoutSignal(timeoutMs),
    },
  ) {
  | response =>
    switch response->status {
    | code if code >= 200 && code < 300 =>
      Delivered(
        switch await response->json {
        | body => body
        | exception _ => JSON.Null
        },
      )
    | code if code >= 500 || code === 429 => Retry(`HTTP ${code->Int.toString}`)
    | code => Refused(code)
    }
  | exception exn =>
    Retry((exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"])
  }

let make = (
  ~url,
  ~queueMax=10_000,
  ~callsTimeoutMs=2_000,
  // The runtime answers a rollback only after the user's `onRollback` ran.
  ~rollbackTimeoutMs=30_000,
  ~backoffBaseMs=250,
  ~backoffCapMs=5_000,
  ~onAcked=_ => (),
  ~onDropped=(_, ~reason as _) => (),
) => {
  url,
  queueMax,
  callsTimeoutMs,
  rollbackTimeoutMs,
  backoffBaseMs,
  backoffCapMs,
  onAcked,
  onDropped,
  queue: [],
  inFlight: [],
  sent: 0,
  rollbacksSent: 0,
  dropped: Dict.make(),
  draining: false,
  stopped: false,
  batchCount: 0,
  idleWaiters: [],
}

let queuedCalls = t =>
  t.inFlight->Array.length +
    t.queue->Array.reduce(0, (count, item) =>
      switch item {
      | Call(_) => count + 1
      | Rollback(_) => count
      }
    )

let stats = (t): stats => {
  queued: t->queuedCalls,
  sent: t.sent,
  rollbacksSent: t.rollbacksSent,
  dropped: t.dropped->Dict.copy,
}

let drop = (t, calls: array<SidecarCall.t>, ~reason, ~detail=reason) =>
  if calls->Utils.Array.notEmpty {
    t.dropped->Dict.set(reason, t.dropped->Dict.get(reason)->Option.getOr(0) + calls->Array.length)
    t.onDropped(calls, ~reason=detail)
    let log = {
      "msg": `Dropped sidecar calls: ${detail}`,
      "count": calls->Array.length,
      "firstId": (calls->Array.getUnsafe(0)).id,
    }
    switch reason {
    | "rolled_back" => Logging.debug(log)
    | _ => Logging.warn(log)
    }
  }

let backoffMs = (t, ~attempt) => {
  let capped = Math.min(
    t.backoffCapMs->Int.toFloat,
    t.backoffBaseMs->Int.toFloat *. Math.pow(2., ~exp=attempt->Int.toFloat),
  )
  // Jitter, so several workers coming back at once don't retry in lockstep.
  (capped *. (0.5 +. Math.random() /. 2.))->Float.toInt
}

let toWire = (call: SidecarCall.t): JSON.t => {
  let wire = dict{
    "id": call.id->JSON.Encode.string,
    "fn": call.fn->JSON.Encode.string,
    "chainId": call.chainId->ChainId.toInt->JSON.Encode.int,
    "blockNumber": call.blockNumber->JSON.Encode.int,
    "input": call.input,
  }
  call.blockTimestamp->Option.forEach(timestamp =>
    wire->Dict.set("blockTimestamp", timestamp->JSON.Encode.int)
  )
  wire->JSON.Encode.object
}

type callsReply = {accepted?: array<string>, rejected?: array<{"id": string, "reason": string}>}

let settleCalls = (t, ~calls: array<SidecarCall.t>, ~reply: JSON.t) => {
  let {?accepted, ?rejected} = reply->(Utils.magic: JSON.t => callsReply)
  let accepted = accepted->Option.getOr([])
  t.sent = t.sent + accepted->Array.length
  if accepted->Utils.Array.notEmpty {
    let acceptedIds = accepted->Utils.Set.fromArray
    t.onAcked(calls->Array.filter(call => acceptedIds->Utils.Set.has(call.id)))
  }
  rejected
  ->Option.getOr([])
  ->Array.forEach(rejection =>
    t->drop(
      calls->Array.filter(call => call.id === rejection["id"]),
      ~reason="rejected",
      ~detail=`rejected by the sidecar: ${rejection["reason"]}`,
    )
  )
}

// Sends `send` until it lands, it is refused, or the sender stops.
let rec deliver = async (t, ~send, ~attempt=0) =>
  switch await send() {
  | Retry(_) if t.stopped => None
  | Retry(reason) =>
    if attempt === 0 {
      Logging.warn({"msg": "The sidecar is unreachable; retrying", "url": t.url, "reason": reason})
    }
    await sleep(t->backoffMs(~attempt))
    t.stopped ? None : await t->deliver(~send, ~attempt=attempt + 1)
  | outcome => Some(outcome)
  }

let sendCalls = async t => {
  t.batchCount = t.batchCount + 1
  let batchId = `b-${pid->Int.toString}-${t.batchCount->Int.toString}`
  // Re-read on every attempt: a rollback or the bound may have pruned the batch.
  let send = () =>
    t.inFlight->Utils.Array.isEmpty
      ? Promise.resolve(Delivered(JSON.Null))
      : t->post(
          ~path="/envio/calls",
          ~body={"batchId": batchId, "calls": t.inFlight->Array.map(toWire)}->Utils.magic,
          ~timeoutMs=t.callsTimeoutMs,
        )
  let outcome = await t->deliver(~send)
  let calls = t.inFlight
  t.inFlight = []
  switch outcome {
  | Some(Delivered(reply)) => t->settleCalls(~calls, ~reply)
  | Some(Refused(code)) =>
    Logging.error({
      "msg": "The sidecar refused a batch of calls; dropped. Its contract likely doesn't match the indexer's.",
      "status": code,
      "batchId": batchId,
    })
    t->drop(calls, ~reason="rejected", ~detail=`refused with HTTP ${code->Int.toString}`)
  | Some(Retry(_)) | None => ()
  }
}

let sendRollback = async (t, target: rollbackTarget) => {
  let body = {"chainId": target.chainId->ChainId.toInt, "rollbackToBlock": target.rollbackToBlock}
  switch await t->deliver(~send=() =>
    t->post(~path="/envio/rollback", ~body=body->Utils.magic, ~timeoutMs=t.rollbackTimeoutMs)
  ) {
  | Some(Delivered(_)) => t.rollbacksSent = t.rollbacksSent + 1
  | Some(Refused(code)) =>
    Logging.error({"msg": "The sidecar refused a rollback notice", "status": code, "notice": body})
  | Some(Retry(_)) | None => ()
  }
}

let notifyIdle = t => {
  let waiters = t.idleWaiters
  t.idleWaiters = []
  waiters->Array.forEach(resolve => resolve())
}

let drain = async t => {
  while t.queue->Utils.Array.notEmpty && !t.stopped {
    switch t.queue->Array.shift {
    | Some(Rollback(target)) => await t->sendRollback(target)
    | Some(Call(call)) =>
      // Consecutive calls go in one POST; a rollback ends the run.
      let calls = [call]
      let rec take = () =>
        switch t.queue->Array.get(0) {
        | Some(Call(next)) if calls->Array.length < maxCallsPerPost =>
          let _ = t.queue->Array.shift
          calls->Array.push(next)->ignore
          take()
        | _ => ()
        }
      take()
      t.inFlight = calls
      await t->sendCalls
    | None => ()
    }
  }
  t.draining = false
  t->notifyIdle
}

let startDraining = t =>
  if !t.draining && !t.stopped {
    t.draining = true
    let _ =
      t
      ->drain
      ->Promise.catch(exn => {
        t.draining = false
        Logging.errorWithExn(exn->Utils.prettifyExn, "The sidecar sender stopped unexpectedly")
        Promise.resolve()
      })
  }

let isAbove = (call: SidecarCall.t, target: rollbackTarget) =>
  call.chainId === target.chainId && call.blockNumber > target.rollbackToBlock

// Calls for blocks the rollback undid are never sent; the replayed blocks
// make their own.
let purge = (t, target: rollbackTarget) => {
  let purged = []
  let kept = t.queue->Array.filter(item =>
    switch item {
    | Call(call) if call->isAbove(target) =>
      purged->Array.push(call)->ignore
      false
    | _ => true
    }
  )
  t.queue->Utils.Array.clearInPlace
  t.queue->Array.pushMany(kept)
  let (rolledBack, inFlight) =
    t.inFlight->Array.reduce(([], []), ((rolledBack, kept), call) =>
      call->isAbove(target)
        ? (rolledBack->Array.concat([call]), kept)
        : (rolledBack, kept->Array.concat([call]))
    )
  t.inFlight = inFlight
  t->drop(
    purged->Array.concat(rolledBack),
    ~reason="rolled_back",
    ~detail="their blocks were rolled back",
  )
}

// Past the bound the oldest calls go: at the head the newest matter most.
// Rollback notices are never dropped.
let enforceBound = t => {
  let excess = t->queuedCalls - t.queueMax
  if excess > 0 {
    let fromInFlight = t.inFlight->Array.slice(~start=0, ~end=excess)
    t.inFlight = t.inFlight->Array.slice(~start=fromInFlight->Array.length)
    let remaining = ref(excess - fromInFlight->Array.length)
    let fromQueue = []
    let kept = t.queue->Array.filter(item =>
      switch item {
      | Call(call) if remaining.contents > 0 =>
        remaining := remaining.contents - 1
        fromQueue->Array.push(call)->ignore
        false
      | _ => true
      }
    )
    t.queue->Utils.Array.clearInPlace
    t.queue->Array.pushMany(kept)
    t->drop(
      fromInFlight->Array.concat(fromQueue),
      ~reason="overflow",
      ~detail=`the queue is over its bound of ${t.queueMax->Int.toString} calls (ENVIO_SIDECAR_QUEUE_MAX)`,
    )
  }
}

// One committed write: its rollback notices first, then its calls.
let enqueueCommitted = (t, ~rollbackTargets: array<rollbackTarget>, ~calls: array<SidecarCall.t>) =>
  if !t.stopped && (rollbackTargets->Utils.Array.notEmpty || calls->Utils.Array.notEmpty) {
    rollbackTargets->Array.forEach(target => {
      t->purge(target)
      t.queue->Array.push(Rollback(target))->ignore
    })
    calls->Array.forEach(call => t.queue->Array.push(Call(call))->ignore)
    t->enforceBound
    t->startDraining
  }

// Resolves once everything queued is sent, or after `timeoutMs`.
let flush = (t, ~timeoutMs) =>
  if !t.draining {
    Promise.resolve()
  } else {
    Promise.race([
      Promise.make((resolve, _) => t.idleWaiters->Array.push(() => resolve())->ignore),
      sleep(timeoutMs),
    ])
  }

let stop = t => {
  t.stopped = true
  t->notifyIdle
}
