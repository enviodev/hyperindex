open Vitest

// Built the way the client produces one, so the shape under test is the shape
// the sources actually catch.
let raised = message =>
  try JsError.throwWithMessage(message) catch {
  | exn => exn
  }

let unauthorized = () => raised("Failed to execute http request: 401 Unauthorized")
let somethingElse = () => raised("connection reset")

let rethrown = (exn, ~warned) =>
  try {
    let _ = exn->HyperSyncAuth.rethrowLoggingUnauthorized(~warned, ~product="HyperSync")
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("HyperSyncAuth.rethrowLoggingUnauthorized", () => {
  it("rethrows a 401 rather than swallowing it, and only reports it once", t => {
    let warned = ref(false)

    let first = unauthorized()->rethrown(~warned)
    let warnedAfterFirst = warned.contents
    let second = unauthorized()->rethrown(~warned)

    // A token can be replaced without restarting, so the caller has to keep
    // retrying - which it only does if the failure reaches it every time.
    t.expect((first, warnedAfterFirst, second, warned.contents)).toEqual((
      Some("Failed to execute http request: 401 Unauthorized"),
      true,
      Some("Failed to execute http request: 401 Unauthorized"),
      true,
    ))
  })

  it("passes an unrelated failure through untouched", t => {
    let warned = ref(false)

    let message = somethingElse()->rethrown(~warned)

    t.expect((message, warned.contents)).toEqual((Some("connection reset"), false))
  })
})
