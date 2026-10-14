// Delivers committed `context.sidecar` calls to the sidecar's internal server
// (wiki/06-api-v0.md 6.1, 6.2; wiki/09-reliability.md 3). One ordered queue
// per indexer process and a single sender draining it, so a rollback notice
// is never overtaken by calls committed after it. Handing calls over is
// synchronous: the write loop never waits for the sidecar.

type rollbackTarget = {chainId: ChainId.t, rollbackToBlock: int}

type item = Rollback(rollbackTarget) | Call(SidecarCall.t)

// A Prometheus histogram: `counts` holds one non-cumulative count per upper
// bound in `buckets`, plus a last one for what lies above them all.
type histogram = {buckets: array<float>, counts: array<int>, mutable sum: float, mutable count: int}

// One POST to the sidecar, answer included: milliseconds over loopback, up to
// the 30 s rollback timeout (the runtime answers a rollback after `onRollback`).
let deliveryBuckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1., 2.5, 5., 10., 30.]
// From the commit to the sidecar accepting the call: queueing and retries
// while the sidecar is down included, so it reaches further.
let commitToAckBuckets = [0.01, 0.05, 0.1, 0.25, 0.5, 1., 2.5, 5., 10., 30., 60., 300.]

let makeHistogram = buckets => {
  buckets,
  counts: Array.make(~length=buckets->Array.length + 1, 0),
  sum: 0.,
  count: 0,
}

let observe = (h, value) => {
  let index = switch h.buckets->Array.findIndex(upper => value <= upper) {
  | -1 => h.buckets->Array.length
  | index => index
  }
  h.counts->Array.setUnsafe(index, h.counts->Array.getUnsafe(index) + 1)
  h.sum = h.sum +. value
  h.count = h.count + 1
}

let copyHistogram = h => {...h, counts: h.counts->Array.copy}

// Two workers' histograms of the same series; their buckets are the same.
let addHistograms = (a, b) => {
  buckets: a.buckets,
  counts: a.counts->Array.mapWithIndex((count, i) => count + b.counts->Array.getUnsafe(i)),
  sum: a.sum +. b.sum,
  count: a.count + b.count,
}

type stats = {
  queued: int,
  sent: int,
  rollbacksSent: int,
  dropped: dict<int>,
  // Whether the last answer says the sidecar can take calls. None until a
  // delivery or a readiness probe has had one.
  up: option<bool>,
  // Unix seconds of the last POST the sidecar answered with a 2xx.
  lastAckSeconds: option<float>,
  queueMax: int,
  // Keyed by the rendered labels, `kind="calls",outcome="delivered"`.
  deliverySeconds: dict<histogram>,
  commitToAckSeconds: histogram,
}

type probeTimer

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
  // 0 turns the readiness probe off.
  probeMs: int,
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
  mutable up: option<bool>,
  mutable lastAckSeconds: option<float>,
  mutable probeTimer: option<probeTimer>,
  mutable probing: bool,
  deliverySeconds: dict<histogram>,
  commitToAckSeconds: histogram,
  // When each queued call was committed, for `commitToAckSeconds`.
  committedAt: Utils.WeakMap.t<SidecarCall.t, Performance.timeRef>,
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
@send external text: response => promise<string> = "text"
@val @scope("AbortSignal") external timeoutSignal: int => signal = "timeout"
type getInit = {method: string, signal: signal}
@val external get: (string, getInit) => promise<response> = "fetch"

// Unref'd like `sleep`: the probe never keeps the process alive.
let startTimer: (
  int,
  unit => unit,
) => probeTimer = %raw(`(ms, tick) => setInterval(tick, ms).unref()`)
let stopTimer: probeTimer => unit = %raw(`timer => clearInterval(timer)`)

let nowSeconds = () => Date.now() /. 1000.

// Up is what the sidecar said last: a 2xx (or any 4xx other than 429, which
// is an answer about the payload) means up, while what `post` would retry
// (refused, timeout, 5xx, 429) means down from that first failed attempt.
// While nothing is being delivered the readiness probe below answers instead.
let setUp = (t, up) => {
  if t.up != Some(up) {
    Logging.debug({"msg": up ? "The sidecar is up" : "The sidecar is down", "url": t.url})
  }
  t.up = Some(up)
}

type outcome =
  | Delivered(JSON.t)
  // Connection refused, timeout, 5xx (the runtime's 503 while closing
  // included) or 429: the sidecar can take it later.
  | Retry(string)
  // Any other non-2xx: the payload itself is wrong, resending won't help.
  | Refused(int)

let outcomeLabel = outcome =>
  switch outcome {
  | Delivered(_) => "delivered"
  | Retry(_) => "retry"
  | Refused(_) => "refused"
  }

let postOnce = async (t, ~path, ~body: JSON.t, ~timeoutMs) =>
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
      t->setUp(true)
      t.lastAckSeconds = Some(nowSeconds())
      Delivered(
        switch await response->json {
        | body => body
        | exception _ => JSON.Null
        },
      )
    | code if code >= 500 || code === 429 =>
      t->setUp(false)
      Retry(`HTTP ${code->Int.toString}`)
    | code =>
      t->setUp(true)
      Refused(code)
    }
  | exception exn =>
    t->setUp(false)
    Retry((exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"])
  }

// One attempt, timed into `envio_sidecar_delivery_seconds{kind,outcome}`.
let post = async (t, ~kind, ~path, ~body, ~timeoutMs) => {
  let startedAt = Performance.now()
  let outcome = await t->postOnce(~path, ~body, ~timeoutMs)
  let key = `kind="${kind}",outcome="${outcome->outcomeLabel}"`
  let histogram = switch t.deliverySeconds->Utils.Dict.dangerouslyGetNonOption(key) {
  | Some(histogram) => histogram
  | None =>
    let histogram = makeHistogram(deliveryBuckets)
    t.deliverySeconds->Dict.set(key, histogram)
    histogram
  }
  histogram->observe(startedAt->Performance.secondsSince)
  outcome
}

// The sidecar's readiness (wiki/09-reliability.md 2): 200 when it takes calls,
// 503 `starting` or `closing` when it does not. Only asked while the sender is
// idle, as a delivery under way already says the same thing more recently.
let probe = async t =>
  if !t.draining && !t.probing && !t.stopped {
    t.probing = true
    let up = switch await get(
      t.url ++ "/readyz",
      {method: "GET", signal: timeoutSignal(t.callsTimeoutMs)},
    ) {
    | response =>
      // Read the body, so the connection goes back to the pool.
      let _ = switch await response->text {
      | _ => ()
      | exception _ => ()
      }
      response->status >= 200 && response->status < 300
    | exception _ => false
    }
    t.probing = false

    // A delivery that started meanwhile has the fresher answer.
    if !t.draining && !t.stopped {
      t->setUp(up)
    }
  }

let startProbe = t =>
  if t.probeMs > 0 && t.probeTimer->Option.isNone {
    let tick = () => t->probe->Promise.ignore
    t.probeTimer = Some(startTimer(t.probeMs, tick))
    tick()
  }

// The sidecar's own Prometheus text (its internal `GET /metrics`), or None
// when it does not answer within `timeoutMs`, so the indexer's `/metrics` can
// carry it (D-008). Never rejects.
let fetchMetrics = async (~url, ~timeoutMs) => {
  let read = async () => {
    let response = await get(url ++ "/metrics", {method: "GET", signal: timeoutSignal(timeoutMs)})
    (response->status, await response->text)
  }
  switch await read() {
  | (200, body) => Some(body)
  | (code, _) =>
    Logging.trace({"msg": "The sidecar's /metrics did not answer 200", "status": code})
    None
  | exception exn =>
    Logging.trace({
      "msg": "The sidecar's /metrics did not answer",
      "reason": (exn->Utils.prettifyExn->(Utils.magic: exn => {"message": string}))["message"],
    })
    None
  }
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
  // How often to check `/readyz` while idle; 0 (the default, for tests) never
  // does. The indexer passes ENVIO_SIDECAR_PROBE_MS.
  ~probeMs=0,
) => {
  let t = {
    url,
    queueMax,
    callsTimeoutMs,
    rollbackTimeoutMs,
    backoffBaseMs,
    backoffCapMs,
    onAcked,
    onDropped,
    probeMs,
    queue: [],
    inFlight: [],
    sent: 0,
    rollbacksSent: 0,
    dropped: Dict.make(),
    draining: false,
    stopped: false,
    batchCount: 0,
    idleWaiters: [],
    up: None,
    lastAckSeconds: None,
    probeTimer: None,
    probing: false,
    deliverySeconds: Dict.make(),
    commitToAckSeconds: makeHistogram(commitToAckBuckets),
    committedAt: Utils.WeakMap.make(),
  }
  t->startProbe
  t
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
  up: t.up,
  lastAckSeconds: t.lastAckSeconds,
  queueMax: t.queueMax,
  deliverySeconds: t.deliverySeconds->Utils.Dict.mapValues(copyHistogram),
  commitToAckSeconds: t.commitToAckSeconds->copyHistogram,
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
    let acked = calls->Array.filter(call => acceptedIds->Utils.Set.has(call.id))
    acked->Array.forEach(call =>
      t.committedAt
      ->Utils.WeakMap.get(call)
      ->Option.forEach(committedAt =>
        t.commitToAckSeconds->observe(committedAt->Performance.secondsSince)
      )
    )
    t.onAcked(acked)
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
          ~kind="calls",
          ~path="/envio/calls",
          ~body={"batchId": batchId, "calls": t.inFlight->Array.map(toWire)}->Utils.magic,
          ~timeoutMs=t.callsTimeoutMs,
        )
  let outcome = await t->deliver(~send)
  let calls = t.inFlight
  t.inFlight = []
  switch outcome {
  // The bound or a rollback emptied the batch while it was retrying: `send`
  // answered for it without a POST, so there is no reply to settle.
  | Some(Delivered(_)) if calls->Utils.Array.isEmpty => ()
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
    t->post(
      ~kind="rollback",
      ~path="/envio/rollback",
      ~body=body->Utils.magic,
      ~timeoutMs=t.rollbackTimeoutMs,
    )
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
    let committedAt = Performance.now()
    calls->Array.forEach(call => {
      t.committedAt->Utils.WeakMap.set(call, committedAt)->ignore
      t.queue->Array.push(Call(call))->ignore
    })
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
  t.probeTimer->Option.forEach(stopTimer)
  t.probeTimer = None
  t->notifyIdle
}
