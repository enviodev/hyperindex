type timeRef = float

@val @scope("performance") external now: unit => timeRef = "now"

let secondsSince = (from: timeRef): float => (now() -. from) /. 1000.

let secondsBetween = (~from: timeRef, ~to: timeRef): float => (to -. from) /. 1000.
