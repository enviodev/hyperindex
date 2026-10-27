open Vitest

describe("native request failures", () => {
  it("keeps timings and maps a wrapped HyperSync rate limit", t => {
    let exn = try {
      JsError.throwWithMessage(`ENVIO_NATIVE_FAILURE:{"message":"RATE_LIMITED:2500","requestStats":[{"method":"getBlockHashes","seconds":0.25}]}`)
    } catch {
    | exn => exn
    }
    t.expect({
      "requestStats": (exn->Source.unpackNativeRequestFailure).requestStats,
      "mapped": exn->HyperSync.mapNativeFailureExn,
    }).toEqual({
      "requestStats": [{Source.method: "getBlockHashes", seconds: 0.25}],
      "mapped": Source.RateLimited({
        resetMs: 2500,
        requestStats: [{Source.method: "getBlockHashes", seconds: 0.25}],
      }),
    })
  })
})
