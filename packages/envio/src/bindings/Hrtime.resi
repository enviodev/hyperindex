type seconds
type milliseconds
type nanoseconds

type timeTuple = (seconds, nanoseconds)

type timeRef

type timeElapsed = timeTuple

let makeTimer: unit => timeRef

let timeSince: timeRef => timeElapsed

let nanoToMilli: nanoseconds => milliseconds
let secToMilli: seconds => milliseconds

let timeElapsedToNewRef: (timeElapsed, timeRef) => timeRef
let toMillis: timeElapsed => milliseconds
let toSeconds: timeElapsed => seconds
let toSecondsFloat: timeElapsed => float

let intFromMillis: milliseconds => int
let intFromNanos: nanoseconds => int
let intFromSeconds: seconds => int
let floatFromMillis: milliseconds => float
let floatFromSeconds: seconds => float

let millisBetween: (~from: timeRef, ~to: timeRef) => int
let secondsBetween: (~from: timeRef, ~to: timeRef) => float
