open Vitest

let json = (s: string): JSON.t => s->JSON.parseOrThrow

describe("Config.stripSensitiveData", () => {
  it("removes rpcs, rpc, and hypersync from chains across evm/fuel/svm", t => {
    let input = json(`{
      "name": "demo",
      "evm": {
        "chains": {
          "1": {"id": 1, "rpcs": [{"url": "https://secret"}], "hypersync": "https://eth.hypersync.xyz"},
          "10": {"id": 10, "rpc": "https://other-secret"}
        }
      },
      "fuel": {
        "chains": {
          "0": {"id": 0, "hypersync": "https://fuel.hypersync.xyz"}
        }
      },
      "svm": {
        "chains": {
          "mainnet": {"id": 101, "rpc": "https://svm-secret"}
        }
      }
    }`)

    let expected = json(`{
      "name": "demo",
      "evm": {
        "chains": {
          "1": {"id": 1},
          "10": {"id": 10}
        }
      },
      "fuel": {
        "chains": {
          "0": {"id": 0}
        }
      },
      "svm": {
        "chains": {
          "mainnet": {"id": 101}
        }
      }
    }`)

    t.expect(
      Config.stripSensitiveData(input),
      ~message="strips rpcs, rpc, and hypersync",
    ).toEqual(expected)
  })

  it("does not mutate the input JSON", t => {
    let input = json(`{"evm": {"chains": {"1": {"rpcs": [{"url": "x"}]}}}}`)
    let _ = Config.stripSensitiveData(input)
    let chain1 =
      input
      ->JSON.Decode.object
      ->Option.flatMap(o => o->Dict.get("evm"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("chains"))
      ->Option.flatMap(JSON.Decode.object)
      ->Option.flatMap(o => o->Dict.get("1"))
      ->Option.flatMap(JSON.Decode.object)
    t.expect(
      chain1->Option.flatMap(o => o->Dict.get("rpcs"))->Option.isSome,
      ~message="rpcs still on the original",
    ).toBe(true)
  })

  it("is a no-op on configs without ecosystems", t => {
    let input = json(`{"name": "demo", "entities": []}`)
    t.expect(Config.stripSensitiveData(input), ~message="passthrough").toEqual(input)
  })
})

describe("Config.diffPaths", () => {
  it("returns [] for structurally equal JSON regardless of key order", t => {
    let stored = json(`{"a": {"x": 1, "y": 2}, "b": [1, 2, 3]}`)
    let current = json(`{"b": [1, 2, 3], "a": {"y": 2, "x": 1}}`)
    t.expect(
      Config.diffPaths(~stored, ~current),
      ~message="key-order independent",
    ).toEqual([])
  })

  it("reports the dotted path of a single changed leaf", t => {
    let stored = json(`{"name": "old", "evm": {"chains": {"1": {"id": 1}}}}`)
    let current = json(`{"name": "new", "evm": {"chains": {"1": {"id": 1}}}}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="single field").toEqual(["name"])
  })

  it("drills into nested objects to the actual leaf path", t => {
    let stored = json(`{"evm": {"chains": {"1": {"startBlock": 0}}}}`)
    let current = json(`{"evm": {"chains": {"1": {"startBlock": 100}}}}`)
    t.expect(
      Config.diffPaths(~stored, ~current),
      ~message="nested leaf, not 'evm'",
    ).toEqual(["evm.chains.1.startBlock"])
  })

  it("uses [i] notation for array index changes", t => {
    let stored = json(`{"contracts": [{"name": "A"}, {"name": "B"}]}`)
    let current = json(`{"contracts": [{"name": "A"}, {"name": "C"}]}`)
    t.expect(
      Config.diffPaths(~stored, ~current),
      ~message="array index path",
    ).toEqual(["contracts[1].name"])
  })

  it("reports an array element that exists on only one side", t => {
    let stored = json(`{"contracts": [{"name": "A"}]}`)
    let current = json(`{"contracts": [{"name": "A"}, {"name": "B"}]}`)
    t.expect(
      Config.diffPaths(~stored, ~current),
      ~message="missing array slot",
    ).toEqual(["contracts[1]"])
  })

  it("reports keys present on only one side", t => {
    let stored = json(`{"a": 1, "b": 2}`)
    let current = json(`{"a": 1, "c": 3}`)
    t.expect(
      Config.diffPaths(~stored, ~current),
      ~message="added/removed keys",
    ).toEqual(["b", "c"])
  })

  it("collects multiple diffs in deterministic key order", t => {
    let stored = json(`{"z": {"q": 0}, "a": 0, "m": 0}`)
    let current = json(`{"z": {"q": 1}, "a": 1, "m": 0}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="sorted").toEqual(["a", "z.q"])
  })

  it("ignores rpcs entirely when both sides come from stripSensitiveData", t => {
    // Mimics the user-reported scenario: only RPC fields edited; after
    // stripping, both sides should be identical and the diff empty.
    let storedRaw = json(`{
      "evm": {
        "chains": {
          "1": {"id": 1, "rpcs": [{"url": "u1", "pollingInterval": 1000}]}
        }
      }
    }`)
    let currentRaw = json(`{
      "evm": {
        "chains": {
          "1": {"id": 1, "rpcs": [{"url": "u1", "pollingInterval": 5000}]}
        }
      }
    }`)
    t.expect(
      Config.diffPaths(
        ~stored=Config.stripSensitiveData(storedRaw),
        ~current=Config.stripSensitiveData(currentRaw),
      ),
      ~message="rpc-only edits should produce no diff after stripping",
    ).toEqual([])
  })

  it("ignores data-source flips that drop hypersync alongside rpcs edits", t => {
    // When a user marks an RPC `for: sync`, the public config drops
    // `chains.<id>.hypersync` (since `main` flips to Rpc). Stripping
    // hypersync alongside rpcs makes that cascade invisible too.
    let storedRaw = json(`{
      "evm": {
        "chains": {
          "1": {
            "id": 1,
            "hypersync": "https://eth.hypersync.xyz",
            "rpcs": [{"url": "u1", "for": "fallback"}]
          }
        }
      }
    }`)
    let currentRaw = json(`{
      "evm": {
        "chains": {
          "1": {
            "id": 1,
            "rpcs": [{"url": "u1", "for": "sync"}]
          }
        }
      }
    }`)
    t.expect(
      Config.diffPaths(
        ~stored=Config.stripSensitiveData(storedRaw),
        ~current=Config.stripSensitiveData(currentRaw),
      ),
      ~message="hypersync drop on data-source flip should not register as a diff",
    ).toEqual([])
  })
})
