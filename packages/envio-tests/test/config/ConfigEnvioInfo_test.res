open Vitest

let json = (s: string): JSON.t => s->JSON.parseOrThrow

describe("Config.toEnvioInfo", () => {
  it("keeps everything but the chains and the command's own fields", t => {
    let input = json(`{
      "name": "demo",
      "isDev": true,
      "isolatedChains": [1],
      "evm": {
        "addressFormat": "checksum",
        "chains": {"ethereum": {"id": 1, "rpcs": [{"url": "https://secret"}]}}
      },
      "fuel": {
        "chains": {"fuel": {"id": 0, "hypersync": "https://fuel.hypersync.xyz"}}
      }
    }`)

    t.expect(Config.toEnvioInfo(input)).toEqual(
      json(`{"name": "demo", "evm": {"addressFormat": "checksum"}, "fuel": {}}`),
    )
  })

  it("does not mutate the input JSON", t => {
    let input = json(`{"isDev": true, "evm": {"chains": {"1": {"id": 1}}}}`)
    let _ = Config.toEnvioInfo(input)
    t.expect(input).toEqual(json(`{"isDev": true, "evm": {"chains": {"1": {"id": 1}}}}`))
  })
})

describe("Config.diffPaths", () => {
  it("returns [] for structurally equal JSON regardless of key order", t => {
    let stored = json(`{"a": {"x": 1, "y": 2}, "b": [1, 2, 3]}`)
    let current = json(`{"b": [1, 2, 3], "a": {"y": 2, "x": 1}}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="key-order independent").toEqual([])
  })

  it("reports the dotted path of a single changed leaf", t => {
    let stored = json(`{"name": "old", "evm": {"chains": {"1": {"id": 1}}}}`)
    let current = json(`{"name": "new", "evm": {"chains": {"1": {"id": 1}}}}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="single field").toEqual(["name"])
  })

  it("drills into nested objects to the actual leaf path", t => {
    let stored = json(`{"evm": {"chains": {"1": {"startBlock": 0}}}}`)
    let current = json(`{"evm": {"chains": {"1": {"startBlock": 100}}}}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="nested leaf, not 'evm'").toEqual([
      "evm.chains.1.startBlock",
    ])
  })

  it("uses [i] notation for array index changes", t => {
    let stored = json(`{"contracts": [{"name": "A"}, {"name": "B"}]}`)
    let current = json(`{"contracts": [{"name": "A"}, {"name": "C"}]}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="array index path").toEqual([
      "contracts[1].name",
    ])
  })

  it("reports an array element that exists on only one side", t => {
    let stored = json(`{"contracts": [{"name": "A"}]}`)
    let current = json(`{"contracts": [{"name": "A"}, {"name": "B"}]}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="missing array slot").toEqual([
      "contracts[1]",
    ])
  })

  it("reports keys present on only one side", t => {
    let stored = json(`{"a": 1, "b": 2}`)
    let current = json(`{"a": 1, "c": 3}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="added/removed keys").toEqual(["b", "c"])
  })

  it("collects multiple diffs in deterministic key order", t => {
    let stored = json(`{"z": {"q": 0}, "a": 0, "m": 0}`)
    let current = json(`{"z": {"q": 1}, "a": 1, "m": 0}`)
    t.expect(Config.diffPaths(~stored, ~current), ~message="sorted").toEqual(["a", "z.q"])
  })
})
