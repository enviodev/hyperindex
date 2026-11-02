// What the source layer reads time from and arms its timers on. A test can hand
// it a clock that only moves when the test moves it, which takes the scheduler
// out of every race between a timer and the step a test is taking. The label
// names a timer in that clock's timeline; the real clock ignores it.
type timer

type t = {
  now: unit => float,
  setTimeout: (~label: string, unit => unit, int) => timer,
  clearTimeout: timer => unit,
  random: unit => float,
}

// Monotonic: every reading is only ever compared with another, and a wall
// clock corrected mid-run would make a connection look like it served for
// minutes, or a benched source look recovered.
let real: t = {
  now: Performance.now,
  setTimeout: (~label as _, callback, millis) =>
    setTimeout(callback, millis)->(Utils.magic: timeoutId => timer),
  clearTimeout: timer => clearTimeout(timer->(Utils.magic: timer => timeoutId)),
  random: Math.random,
}

let delay = (clock: t, ~label, millis) =>
  Promise.make((resolve, _reject) => clock.setTimeout(~label, () => resolve(), millis)->ignore)

// Half the delay fixed, half spread across it. Every indexer pointed at one
// provider loses its stream, or gives up on a quiet chain, in the same instant
// that provider blinks, and putting them all back on the same schedule is how a
// blip becomes a stampede.
let jitter = (clock: t, delay) =>
  delay / 2 + (clock.random() *. (delay / 2)->Int.toFloat)->Float.toInt

// Clearing a pending timer and forgetting it are one action. A ref left holding
// a spent timer reads as one still pending, and the next clear looks like it
// did something.
let clearRef = (clock: t, timer: ref<option<timer>>) => {
  switch timer.contents {
  | Some(timer) => clock.clearTimeout(timer)
  | None => ()
  }
  timer := None
}
