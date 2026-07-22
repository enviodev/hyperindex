open Vitest

// Covers `HandlerRegister.validateEventIdOrThrow`, the per-chain dispatch-id
// guard `finishRegistration` runs so a single log/receipt/instruction can't fan
// out to two events on one contract, or to two wildcards sharing a signature —
// Rust-side routing dispatches by these ids, so a collision double-delivers.

describe("HandlerRegister.validateEventIdOrThrow", () => {
  let add = (validator, ~eventId, ~contractName, ~isWildcard) =>
    validator->HandlerRegister.validateEventIdOrThrow(
      ~eventId,
      ~contractName,
      ~eventName="Event1",
      ~isWildcard,
      ~chainId=1,
    )

  it("accepts the same eventId across different contracts", t => {
    let validator = HandlerRegister.makeEventIdValidator()
    validator->add(~eventId="0xsig", ~contractName="Contract1", ~isWildcard=false)
    t.expect(
      () => validator->add(~eventId="0xsig", ~contractName="Contract2", ~isWildcard=false),
    ).not.toThrow()
  })

  it("throws on a duplicate event for the same contract", t => {
    let validator = HandlerRegister.makeEventIdValidator()
    validator->add(~eventId="0xsig", ~contractName="Contract1", ~isWildcard=false)
    t.expect(
      () => validator->add(~eventId="0xsig", ~contractName="Contract1", ~isWildcard=false),
    ).toThrowError("Duplicate event detected: Event1 for contract Contract1 on chain 1")
  })

  it("throws when a second wildcard claims the same eventId", t => {
    let validator = HandlerRegister.makeEventIdValidator()
    validator->add(~eventId="0xsig", ~contractName="Contract1", ~isWildcard=true)
    t.expect(
      () => validator->add(~eventId="0xsig", ~contractName="Contract2", ~isWildcard=true),
    ).toThrowError(
      "Another event is already registered with the same signature that would interfere with wildcard filtering: Event1 for contract Contract2 on chain 1",
    )
  })

  it("accepts two wildcards whose eventIds differ (e.g. SVM program-scoped ids)", t => {
    // finishRegistration scopes the SVM key by programId (`${programId}_${id}`),
    // so two wildcard instructions sharing a discriminator on different programs
    // reach the validator as distinct eventIds and must not collide.
    let validator = HandlerRegister.makeEventIdValidator()
    validator->add(~eventId="progA_0x0f", ~contractName="ProgA", ~isWildcard=true)
    t.expect(
      () => validator->add(~eventId="progB_0x0f", ~contractName="ProgB", ~isWildcard=true),
    ).not.toThrow()
  })
})
