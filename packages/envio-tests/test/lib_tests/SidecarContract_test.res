open Vitest

@module("node:fs") external mkdirSync: (string, {..}) => unit = "mkdirSync"
@module("node:fs") external writeFileSync: (string, string) => unit = "writeFileSync"
@module("node:path") @variadic external pathJoin: array<string> => string = "join"
@module("node:path") external pathDirname: string => string = "dirname"
@module("node:url") external fileURLToPath: string => string = "fileURLToPath"
@module("node:crypto") external randomUUID: unit => string = "randomUUID"
@val external importMetaUrl: string = "import.meta.url"

let tmpDir = pathJoin([pathDirname(fileURLToPath(importMetaUrl)), "..", ".tmp"])

let writeContract = (~ext, source) => {
  mkdirSync(tmpDir, {"recursive": true})
  let file = pathJoin([tmpDir, `sidecar-contract-${randomUUID()}.${ext}`])
  writeFileSync(file, source)
  file
}

let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: sidecar-contract-loading
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "NewGravatar(uint256 id, address owner, string displayName, string imageUrl)"
`,
)

let withContract = contract => {...config, sidecar: Some({contract, entry: "unused.ts"})}

let loadedFunctions = async config => {
  await SidecarContract.loadOrThrow(~config)
  SidecarContract.get()->Option.map(({functions}) => functions->Dict.keysToArray)
}

describe("SidecarContract.loadOrThrow", () => {
  // Loading binds the module the config names, whatever else defined a
  // contract in the process before it: each load replaces the last.
  Async.it("binds the contract each config names, one after the other", async t => {
    let first = writeContract(
      ~ext="mjs",
      `import { defineSidecar, S } from "envio";
export default defineSidecar({ functions: { first: { input: S.string } } });`,
    )
    let second = writeContract(
      ~ext="mjs",
      `import { defineSidecar, S } from "envio";
export default defineSidecar({ functions: { second: { input: S.string } } });`,
    )

    let loaded = [
      await loadedFunctions(withContract(first)),
      await loadedFunctions(withContract(second)),
      await loadedFunctions(withContract(first)),
      await loadedFunctions(config),
    ]

    t.expect(loaded).toEqual([Some(["first"]), Some(["second"]), Some(["first"]), None])
  })

  Async.it("takes default.default from a CommonJS build of the contract", async t => {
    let file = writeContract(
      ~ext="cjs",
      `exports.default = { kind: "envio.sidecarContract", functions: { fromCjs: { input: null } }, webhooks: {} };`,
    )

    t.expect(await loadedFunctions(withContract(file))).toEqual(Some(["fromCjs"]))
  })

  Async.it("rejects a module whose default export is not a sidecar contract", async t => {
    let file = writeContract(~ext="mjs", `export default { functions: {} };`)

    let message = switch await SidecarContract.loadOrThrow(~config=withContract(file)) {
    | () => "loaded"
    | exception JsExn(e) => e->JsExn.message->Option.getOr("no message")
    }

    t.expect(message).toBe(
      `The sidecar contract '${file}' must default-export defineSidecar({ functions }): \`export default defineSidecar(...)\`.`,
    )
  })
})
