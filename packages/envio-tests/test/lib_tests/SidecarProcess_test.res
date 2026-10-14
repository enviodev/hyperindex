open Vitest

describe("SidecarProcess.closeCapMs", () => {
  // The pod's termination grace is 30 s, so whatever ENVIO_SIDECAR_GRACE_MS
  // says, `envio sidecar` exits by 28 s.
  it("waits the runtime's grace plus 2 s, defaults to 22 s and caps at 28 s", t => {
    t.expect(
      [
        None,
        Some(""),
        Some("abc"),
        Some("-1"),
        Some("0"),
        Some("500"),
        Some("20000"),
        Some("26001"),
        Some("2147483647"),
      ]->Array.map(graceMs => SidecarProcess.closeCapMs(~graceMs)),
    ).toEqual([22_000, 22_000, 22_000, 22_000, 2_000, 2_500, 22_000, 28_000, 28_000])
  })
})
