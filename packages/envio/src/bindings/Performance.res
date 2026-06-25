type timeRef = float

@val @scope("performance") external now: unit => timeRef = "now"

let toSeconds = (millis: float): float => Math.round(millis) /. 1000.

let secondsSince = (from: timeRef): float => toSeconds(now() -. from)

let secondsBetween = (~from: timeRef, ~to: timeRef): float => toSeconds(to -. from)
