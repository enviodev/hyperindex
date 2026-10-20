open Vitest

// The level check runs in ReScript, before anything crosses into Rust, so its
// numbers have to be the ones Rust filters and writes with.
it("Uses the same level numbers as the Rust logger", t => {
  t.expect(
    Core.getAddon().logLevels()->Array.map(({name, value}) => (
      name,
      name->(Utils.magic: string => Logging.level)->Logging.levelNumber,
      value,
    )),
  ).toEqual(Core.getAddon().logLevels()->Array.map(({name, value}) => (name, value, value)))
})
