open Vitest

// T-028 scenario 2 under `envio dev` (2026-10-14): with the sidecar down past
// ENVIO_SIDECAR_QUEUE_MAX, the bound dropped the whole batch that was retrying.
// The retry then "delivered" the empty batch without a POST, settling a null
// reply threw, and the sender stopped until the next commit restarted it.

let call = (n): SidecarCall.t => {
  id: `1:${n->Int.toString}:0:0`,
  fn: "ping",
  chainId: ChainId.fromInt(1),
  blockNumber: n,
  blockTimestamp: None,
  checkpointId: n->BigInt.fromInt,
  input: {"n": n}->(Utils.magic: {"n": int} => JSON.t),
}

let callIds = (request: FakeSidecar.request) =>
  (
    request.body->(Utils.magic: JSON.t => {"calls": array<{"id": string}>})
  )["calls"]->Array.map(call => call["id"])

let rec waitFor = async (check, ~attempts=200) =>
  if !check() && attempts > 0 {
    await Utils.delay(10)
    await waitFor(check, ~attempts=attempts - 1)
  }

describe("Sidecar sender bound", () => {
  Async.it("keeps sending after the bound drops the whole batch under way", async t => {
    let answered = ref(0)
    let sidecar = await FakeSidecar.start(
      ~respond=async request =>
        switch request.path {
        | "/envio/calls" =>
          answered := answered.contents + 1
          answered.contents === 1
            ? {
                FakeSidecar.status: 503,
                body: {"error": "starting"}->(Utils.magic: {"error": string} => JSON.t),
              }
            : await FakeSidecar.runtimeReply(request)
        | _ => await FakeSidecar.runtimeReply(request)
        },
    )
    let sender = SidecarSender.make(
      ~url=sidecar.url,
      ~queueMax=1,
      ~backoffBaseMs=1,
      ~backoffCapMs=5,
    )

    // 101 goes out at once and meets the 503; 102 is over the bound, so the
    // retrying batch loses 101 and is empty when it is retried.
    sender->SidecarSender.enqueueCommitted(~rollbackTargets=[], ~calls=[call(101)])
    sender->SidecarSender.enqueueCommitted(~rollbackTargets=[], ~calls=[call(102)])
    await waitFor(() => (sender->SidecarSender.stats).sent > 0)
    let stats = sender->SidecarSender.stats
    sender->SidecarSender.stop
    await sidecar.close()

    t.expect((
      sidecar.requests
      ->Array.filter(request => request.path === "/envio/calls")
      ->Array.map(callIds),
      stats.sent,
      stats.queued,
      stats.dropped,
    )).toEqual(([["1:101:0:0"], ["1:102:0:0"]], 1, 0, dict{"overflow": 1}))
  })
})
