open Vitest

// The addon reads a table back by the same names (storage/effect_cache.rs).
describe("Internal.EffectCache.toTableName", () => {
  it("Names a cross-chain cache by its effect, and a chain's by both", t => {
    t.expect((
      Internal.EffectCache.toTableName(~effectName="foo", ~scope=CrossChain),
      Internal.EffectCache.toTableName(~effectName="foo", ~scope=Chain(137->ChainId.fromInt)),
      Internal.EffectCache.toTableName(~effectName="1_effect_x", ~scope=CrossChain),
    )).toEqual(("envio_effect_foo", "envio_137_effect_foo", "envio_effect_1_effect_x"))
  })

  it("Maps scope to its Prometheus label value", t => {
    t.expect((
      Internal.chainScopeToString(CrossChain),
      Internal.chainScopeToString(Chain(137->ChainId.fromInt)),
    )).toEqual(("crossChain", "137"))
  })
})

describe("createEffect name validation", () => {
  it("Rejects names that aren't safe as a cache table name / file path segment", t => {
    let attempt = name =>
      switch Envio.createEffect(
        {name, input: S.string, output: S.string, rateLimit: Disable},
        async ({input}) => input,
      ) {
      | _ => true
      | exception JsExn(_) => false
      }

    // First two are valid (dots are allowed mid-name for existing names like
    // "token.metadata"); the rest carry a path separator, leading-dot traversal,
    // whitespace, or other characters that would break the table/path mapping.
    t.expect(
      ["ok_name-1", "token.metadata", "a/b", "../evil", "has space", "semi;colon"]->Array.map(
        attempt,
      ),
    ).toEqual([true, true, false, false, false, false])
  })
})
