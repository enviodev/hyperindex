/**
Throttles a scheduled function to run at a minimum given interval

Does NOT queue scheduled functions but rather overwrites them
on each schedule call.
*/
type t

/**
Creates a throttler that throttles scheduled functions to run at a minimum
given interval in milliseconds.

Does NOT queue scheduled functions but rather overwrites them

The logger will be used to log any errors that occur in the scheduled
functions.
*/
let make: (~intervalMillis: int, ~logger: Pino.t) => t

/**
Schedules a function to be run on a throttler, overwriting any
previously scheduled functions. Should only be used for functions
that do not need to be executed if there is a more up to date scheduled
function available.
*/
let schedule: (t, unit => promise<unit>) => unit
