open Vitest

describe("Tui.shouldUse", () => {
  it(
    "prefers ENVIO_TUI over what the terminal looks like, and never draws where it is suppressed",
    t => {
      t.expect((
        Tui.shouldUse(~suppressed=true, ~explicitTui=Some(true)),
        Tui.shouldUse(~explicitTui=Some(true)),
        Tui.shouldUse(~explicitTui=Some(false)),
        Tui.shouldUse(~explicitTui=None),
      )).toEqual((false, true, false, !Envio.isNonInteractive()))
    },
  )
})
