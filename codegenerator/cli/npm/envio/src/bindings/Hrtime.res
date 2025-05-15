type seconds = float
type milliseconds = float
type nanoseconds = float

type timeTuple = (seconds, nanoseconds)

type timeRef = timeTuple

type timeElapsed = timeTuple

@val @scope("process") external makeTimer: unit => timeRef = "hrtime"

@val @scope("process") external timeSince: timeRef => timeElapsed = "hrtime"

let nanoToMilli = (nano: nanoseconds): milliseconds => nano /. 1_000_000.
let secToMilli = (sec: seconds): milliseconds => sec *. 1_000.

let nanoToTimeTuple = (nano: nanoseconds): timeTuple => {
  let factor = 1_000_000_000.
  let seconds = Js.Math.floor_float(nano /. factor)
  let nanos = mod_float(nano, factor)
  (seconds, nanos)
}

let timeElapsedToNewRef = (elapsed: timeElapsed, ref: timeRef): timeRef => {
  let (elapsedSeconds, elapsedNano) = elapsed
  let (refSeconds, refNano) = ref

  let (nanoExtraSeconds, remainderNanos) = nanoToTimeTuple(elapsedNano +. refNano)
  (elapsedSeconds +. refSeconds +. nanoExtraSeconds, remainderNanos)
}

let toMillis = ((sec, nano): timeElapsed): milliseconds => {
  sec->secToMilli +. nano->nanoToMilli
}

let toInt = float => float->Belt.Int.fromFloat
let intFromMillis = toInt
let intFromNanos = toInt
let intFromSeconds = toInt
let floatFromMillis = Utils.magic
