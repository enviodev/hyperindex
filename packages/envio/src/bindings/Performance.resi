type timeRef = float

let now: unit => timeRef

let secondsSince: timeRef => float

let secondsBetween: (~from: timeRef, ~to: timeRef) => float
