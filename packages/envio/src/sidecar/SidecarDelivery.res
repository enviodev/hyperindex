// Runs once a batch's write has committed, with that batch's calls, so a
// call is never delivered for writes that didn't land. Not awaited by the
// write loop: delivery must never hold up or fail a write.
// Posting them to `ENVIO_SIDECAR_INTERNAL_URL/envio/calls` is T-005.
let onCommitted = (calls: array<SidecarCall.t>) =>
  if calls->Utils.Array.notEmpty {
    Logging.trace({
      "msg": "Sidecar calls committed",
      "count": calls->Array.length,
      "firstId": (calls->Array.getUnsafe(0)).id,
    })
  }
