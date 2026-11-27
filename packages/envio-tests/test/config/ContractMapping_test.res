open Vitest

describe("ContractMapping", () => {
  it("assigns ids by canonical order, whatever order the config declares", t => {
    let mapping = ContractMapping.make(~names=["B", "A"])
    t.expect({
      "names": mapping->ContractMapping.names,
      "idOfA": mapping->ContractMapping.idOfOrThrow("A"),
      "idOfB": mapping->ContractMapping.idOfOrThrow("B"),
      "nameOf0": mapping->ContractMapping.nameOfOrThrow(0),
      // Declaration order must not reach the ids: both orders map identically.
      "matchesReversedDeclaration": mapping->ContractMapping.isEqual(
        ContractMapping.make(~names=["A", "B"]),
      ),
    }).toEqual({
      "names": ["A", "B"],
      "idOfA": 0,
      "idOfB": 1,
      "nameOf0": "A",
      "matchesReversedDeclaration": true,
    })
  })

  it("throws for a name no contract claims", t =>
    t->toThrowErrorEqual(
      () => ContractMapping.make(~names=["A"])->ContractMapping.idOfOrThrow("B"),
      `Contract "B" is missing from the indexer's contract list.`,
    )
  )

  it("throws for a name no contract claims, naming what asked", t =>
    t->toThrowErrorEqual(
      () =>
        ContractMapping.make(~names=["A"])->ContractMapping.idOfOrThrow(
          "B",
          ~context=" has event registrations but",
        ),
      `Contract "B" has event registrations but is missing from the indexer's contract list.`,
    )
  )

  it("throws for an id outside the list", t =>
    t->toThrowErrorEqual(
      () => ContractMapping.make(~names=["A"])->ContractMapping.nameOfOrThrow(1),
      `Contract id 1 is outside the indexer's contract list.`,
    )
  )

  // A comma-bearing name is unreachable from a real config.yaml, so the mapping
  // is the only rung this can be tested from.
  it("compares mappings elementwise, not as a joined string", t =>
    t.expect({
      "commaBearingNameVsTwoNames": ContractMapping.fromStoredNames([
        "A,B",
      ])->ContractMapping.isEqual(ContractMapping.fromStoredNames(["A", "B"])),
      "same": ContractMapping.fromStoredNames(["A", "B"])->ContractMapping.isEqual(
        ContractMapping.fromStoredNames(["A", "B"]),
      ),
      "reordered": ContractMapping.fromStoredNames(["A", "B"])->ContractMapping.isEqual(
        ContractMapping.fromStoredNames(["B", "A"]),
      ),
      "shorter": ContractMapping.fromStoredNames(["A"])->ContractMapping.isEqual(
        ContractMapping.fromStoredNames(["A", "B"]),
      ),
    }).toEqual({
      "commaBearingNameVsTwoNames": false,
      "same": true,
      "reordered": false,
      "shorter": false,
    })
  )

  it("keeps a stored mapping in the order it was stored", t =>
    t.expect(ContractMapping.fromStoredNames(["B", "A"])->ContractMapping.names).toEqual(["B", "A"])
  )

  it("refuses more contracts than a smallint id can hold", t =>
    t->toThrowErrorEqual(
      () =>
        ContractMapping.make(
          ~names=Array.make(~length=ContractMapping.maxContracts + 1, "")->Array.mapWithIndex(
            (_, i) => `C${i->Int.toString}`,
          ),
        ),
      `The indexer declares 32769 contracts, more than the 32768 a smallint contract id can hold.`,
    )
  )
})
