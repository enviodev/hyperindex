open Vitest

let json = (s: string): JSON.t => s->JSON.parseOrThrow

describe("Config.stripSensitiveData", () => {
  it("removes rpcs and rpc from chains across evm/fuel/svm", t => {
    let input = json(`{
      "name": "demo",
      "evm": {
        "chains": {
          "1": {"id": 1, "rpcs": [{"url": "https://secret"}], "hypersync": "https://eth.hypersync.xyz"},
          "10": {"id": 10, "rpc": "https://other-secret"}
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
          "1": {"id": 1, "hypersync": "https://eth.hypersync.xyz"},
          "10": {"id": 10}
        }
      },
      "svm": {
        "chains": {
          "mainnet": {"id": 101}
        }
      }
    }`)

    t.expect(Config.stripSensitiveData(input), ~message="strips rpcs and rpc").toEqual(expected)
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

describe("Config.topLevelDiffKeys", () => {
  it("returns [] for structurally equal JSON regardless of key order", t => {
    let stored = json(`{"a": {"x": 1, "y": 2}, "b": [1, 2, 3]}`)
    let current = json(`{"b": [1, 2, 3], "a": {"y": 2, "x": 1}}`)
    t.expect(
      Config.topLevelDiffKeys(~stored, ~current),
      ~message="key-order independent",
    ).toEqual([])
  })

  it("reports only the top-level keys whose values differ", t => {
    let stored = json(`{"name": "old", "evm": {"chains": {"1": {"id": 1}}}, "fuel": null}`)
    let current = json(`{"name": "new", "evm": {"chains": {"1": {"id": 1}}}, "fuel": null}`)
    t.expect(Config.topLevelDiffKeys(~stored, ~current), ~message="single field").toEqual(["name"])
  })

  it("surfaces nested changes as the enclosing top-level key", t => {
    let stored = json(`{"evm": {"chains": {"1": {"startBlock": 0}}}}`)
    let current = json(`{"evm": {"chains": {"1": {"startBlock": 100}}}}`)
    t.expect(
      Config.topLevelDiffKeys(~stored, ~current),
      ~message="nested change rolled up",
    ).toEqual(["evm"])
  })

  it("reports keys present on only one side", t => {
    let stored = json(`{"a": 1, "b": 2}`)
    let current = json(`{"a": 1, "c": 3}`)
    t.expect(
      Config.topLevelDiffKeys(~stored, ~current),
      ~message="added/removed keys",
    ).toEqual(["b", "c"])
  })

  it("returns multiple changed keys sorted", t => {
    let stored = json(`{"z": 0, "a": 0, "m": 0}`)
    let current = json(`{"z": 1, "a": 1, "m": 0}`)
    t.expect(Config.topLevelDiffKeys(~stored, ~current), ~message="sorted").toEqual(["a", "z"])
  })
})
