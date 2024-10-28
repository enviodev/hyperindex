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

let intFromMillis: milliseconds => int
let intFromNanos: nanoseconds => int
let intFromSeconds: seconds => int
let floatFromMillis: milliseconds => float
