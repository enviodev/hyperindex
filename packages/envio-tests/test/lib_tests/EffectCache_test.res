open Vitest

// The central reversible mapping between an effect's (name, scope), its
// Postgres cache-table name, and its .envio/cache file path.
describe("Internal.EffectCache address mapping", () => {
  it("Maps cross-chain scope to the flat table name and file path", t => {
    t.expect((
      Internal.EffectCache.toTableName(~effectName="foo", ~scope=CrossChain),
      Internal.EffectCache.toCachePath(~effectName="foo", ~scope=CrossChain),
    )).toEqual(("envio_effect_foo", "foo.tsv"))
  })

  it("Maps chain scope to the chain-prefixed table name and nested file path", t => {
    t.expect((
      Internal.EffectCache.toTableName(~effectName="foo", ~scope=Chain(1)),
      Internal.EffectCache.toCachePath(~effectName="foo", ~scope=Chain(1)),
      Internal.EffectCache.toTableName(~effectName="foo", ~scope=Chain(137)),
      Internal.EffectCache.toCachePath(~effectName="foo", ~scope=Chain(137)),
    )).toEqual(("envio_1_effect_foo", "1/foo.tsv", "envio_137_effect_foo", "137/foo.tsv"))
  })

  it("Round trips every scope through table name and back", t => {
    let cases = [("foo", Internal.CrossChain), ("foo", Chain(1)), ("bar_baz", Chain(137))]
    t.expect(
      cases->Array.map(((effectName, scope)) =>
        Internal.EffectCache.fromTableName(Internal.EffectCache.toTableName(~effectName, ~scope))
      ),
    ).toEqual(cases->Array.map(c => Some(c)))
  })

  it("Parses legacy flat table names as cross-chain caches", t => {
    t.expect(Internal.EffectCache.fromTableName("envio_effect_getTokenMetadata")).toEqual(
      Some(("getTokenMetadata", CrossChain)),
    )
  })

  it("Lets a cross-chain and a chain-scoped cache for the same effect coexist", t => {
    t.expect((
      Internal.EffectCache.fromTableName("envio_effect_foo"),
      Internal.EffectCache.fromTableName("envio_1_effect_foo"),
      Internal.EffectCache.fromTableName("envio_137_effect_foo"),
    )).toEqual((Some(("foo", CrossChain)), Some(("foo", Chain(1))), Some(("foo", Chain(137)))))
  })

  it("Keeps effect names that themselves contain _effect_ unambiguous", t => {
    // Effect literally named "1_effect_x" scoped cross-chain vs effect "x"
    // scoped to chain 1: distinct table names that must decode to distinct
    // (name, scope) pairs.
    t.expect((
      Internal.EffectCache.fromTableName("envio_effect_1_effect_x"),
      Internal.EffectCache.fromTableName("envio_1_effect_x"),
    )).toEqual((Some(("1_effect_x", CrossChain)), Some(("x", Chain(1)))))
  })

  it("Parses only canonical decimal chain ids", t => {
    t.expect(
      ["1", "137", "007", "1foo", "", "-1", "1.5"]->Array.map(Internal.EffectCache.parseChainId),
    ).toEqual([Some(1), Some(137), None, None, None, None, None])
  })

  it("Rejects table names with a non-canonical chain id", t => {
    t.expect(Internal.EffectCache.fromTableName("envio_007_effect_foo")).toEqual(None)
  })

  it("Maps scope to its Prometheus label value", t => {
    t.expect((
      Internal.EffectCache.scopeToString(CrossChain),
      Internal.EffectCache.scopeToString(Chain(137)),
    )).toEqual(("crossChain", "137"))
  })

  it("Returns None for tables that aren't effect caches", t => {
    t.expect(
      ["envio_chains", "envio_checkpoints", "User", "envio_effect_"]->Array.map(
        Internal.EffectCache.fromTableName,
      ),
    ).toEqual([None, None, None, None])
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
