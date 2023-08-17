type seconds = int
type milliseconds = int
type nanoseconds = int

type timeTuple = (seconds, nanoseconds)

type timeRef = timeTuple

type timeElapsed = timeTuple

@val @scope("process") external makeTimer: unit => timeRef = "hrtime"

@val @scope("process") external timeSince: timeRef => timeElapsed = "hrtime"

let nanoToMilli = (nano: nanoseconds): milliseconds => nano / 1_000_000
let secToMilli = (sec: seconds): milliseconds => sec * 1_000

let nanoToTimeTuple = (nano: nanoseconds): timeTuple => {
  let factor = 1_000_000_000
  let seconds = Js.Math.floor(nano->Belt.Float.fromInt /. factor->Belt.Float.fromInt)
  let nanos = mod(nano, factor)
  (seconds, nanos)
}

let timeElapsedToNewRef = (elapsed: timeElapsed, ref: timeRef): timeRef => {
  let (elapsedSeconds, elapsedNano) = elapsed
  let (refSeconds, refNano) = ref

  let (nanoExtraSeconds, remainderNanos) = nanoToTimeTuple(elapsedNano + refNano)
  (elapsedSeconds + refSeconds + nanoExtraSeconds, remainderNanos)
}

let toMillis = ((sec, nano): timeElapsed): milliseconds => {
  sec->secToMilli + nano->nanoToMilli
}

let intFromMillis = Obj.magic
let intFromNanos = Obj.magic
let intFromSeconds = Obj.magic
