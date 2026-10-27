// Time for a scenario that only moves when the test moves it. The clock itself
// is the Rust one (`clock.rs`): the queue, the time, the seeded generator and
// the timeline live there, shared with any Rust code under test. What stays
// here is what only JS can hold — the callbacks of the timers ReScript arms,
// keyed by the id the clock hands back — and the advance loop, which has to
// let the indexer settle between timers.
module Native = {
  type t
  type fired = {id: int, label: string, js: bool}

  @send external make: (Core.virtualClockCtor, int) => t = "new"
  @send external now: t => float = "now"
  @send external seed: t => int = "seed"
  @send external random: t => float = "random"
  @send external arm: (t, string, float) => int = "arm"
  @send external clear: (t, int) => unit = "clear"
  @send external beginAdvance: (t, float) => float = "beginAdvance"
  @send external fireNext: (t, float) => Nullable.t<fired> = "fireNext"
  @send external endAdvance: (t, float) => unit = "endAdvance"
  @send external note: (t, string) => unit = "note"
  @send external describe: t => string = "describe"
}

type t = {native: Native.t, callbacks: Map.t<int, unit => unit>}

let seedFromEnv = () =>
  switch %raw(`process.env.ENVIO_TEST_SEED`)->Nullable.toOption {
  | None | Some("") => (Math.random() *. 2147483647.)->Float.toInt
  | Some(seed) =>
    switch seed->Int.fromString {
    | Some(seed) if seed >= 0 => seed
    | _ =>
      JsError.throwWithMessage(`ENVIO_TEST_SEED must be a non-negative integer, got "${seed}".`)
    }
  }

let make = (~seed=seedFromEnv()) => {
  native: Core.getAddon().virtualClock->Native.make(seed),
  callbacks: Map.make(),
}

let toClock = (clock: t): Clock.t => {
  now: () => clock.native->Native.now,
  setTimeout: (~label, callback, millis) => {
    let id = clock.native->Native.arm(label, millis->Int.toFloat)
    clock.callbacks->Map.set(id, callback)
    id->(Utils.magic: int => Clock.timer)
  },
  clearTimeout: timer => {
    let id = timer->(Utils.magic: Clock.timer => int)
    clock.callbacks->Map.delete(id)->ignore
    clock.native->Native.clear(id)
  },
  random: () => clock.native->Native.random,
}

// Puts something the test did on the timeline, between the timers around it.
let note = (clock: t, event) => clock.native->Native.note(event)

// Fires every timer due in the next `millis`, in order, letting the indexer
// settle after each so a timer one of them arms lands in the same pass.
let advance = async (clock: t, millis, ~settle: unit => promise<unit>) => {
  if millis < 0 {
    JsError.throwWithMessage(`advanceTime takes a duration, got ${millis->Int.toString}ms.`)
  }
  let until = clock.native->Native.beginAdvance(millis->Int.toFloat)
  await settle()
  let continue = ref(true)
  while continue.contents {
    switch clock.native->Native.fireNext(until)->Nullable.toOption {
    | Some({id, js}) =>
      if js {
        switch clock.callbacks->Map.get(id) {
        | Some(callback) =>
          clock.callbacks->Map.delete(id)->ignore
          callback()
        | None => ()
        }
      }
      await settle()
    | None => continue := false
    }
  }
  clock.native->Native.endAdvance(until)
}

let describe = (clock: t) => clock.native->Native.describe
