open Vitest

// Handler modules are user TypeScript, loaded through the module hooks
// `HandlerLoader` registers rather than through vite. The fixture in
// `src/ts_loader_fixture` uses the parts of TypeScript Node cannot run as-is:
// a non-erasable `enum`, an extensionless relative import, and a `.js`
// specifier resolving to a `.ts` sibling. Registration only lands if all three
// survive the transform.
let config = {...Config.load(), handlers: "src/ts_loader_fixture"}
let _ = await HandlerLoader.registerAllHandlers(~config)

describe("TypeScript handler loading", () => {
  it("registers a handler declared with non-erasable syntax and bundler-style imports", t => {
    let registration = MockConfig.getEvmOnEventRegistration(
      ~config,
      ~contractName="EventFiltersTest",
      ~eventName="Transfer",
    )
    t.expect({
      "hasHandler": registration.handler->Option.isSome,
      "isWildcard": registration.isWildcard,
    }).toEqual({"hasHandler": true, "isWildcard": true})
  })
})
