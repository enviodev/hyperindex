// @ocaml.doc(`Please add additional useful formats:
//
// hh:mm:ss         | 00:00:00
// do MMM ''yy      | 1st Jan '21
// ha do MMM ''yy   | 8PM 1st Jan '21
// ha               | 8PM
// iii              | Tues
// iii MMM          | Tues Jan
// MMM              | Jan
// `)
//
// type dateFormats = [
//   | #"HH:mm:ss"
//   | #"do MMM ''yy"
//   | #"ha do MMM ''yy"
//   | #"h:mma do MMM ''yy"
//   | #ha
//   | #iii
//   | #"iii MMM"
//   | #"do MMM"
//   | #MMM
//   | #"h:mma"
// ]

type dateFormats = | @as("h") Seconds

@module("date-fns/format") external format: (Js.Date.t, dateFormats) => string = "default"

type formatDistanceToNowOptions = {includeSeconds: bool}
@module("date-fns/formatDistanceToNow")
external formatDistanceToNow: Js.Date.t => string = "default"

@module("date-fns")
external formatDistance: (Js.Date.t, Js.Date.t) => string = "formatDistance"

@module("date-fns")
external formatDistanceWithOptions: (Js.Date.t, Js.Date.t, formatDistanceToNowOptions) => string =
  "formatDistance"

@module("date-fns/formatDistanceToNow")
external formatDistanceToNowWithOptions: (Js.Date.t, formatDistanceToNowOptions) => string =
  "default"

let formatDistanceToNowWithSeconds = (date: Js.Date.t) =>
  date->formatDistanceToNowWithOptions({includeSeconds: true})

type durationTimeFormat = {
  years: int,
  months: int,
  weeks: int,
  days: int,
  hours: int,
  minutes: int,
  seconds: int,
}

@module("date-fns/formatRelative")
external formatRelative: (Js.Date.t, Js.Date.t) => string = "default"

type durationFormatOutput = {format: array<string>}

@module("date-fns/formatDuration")
external formatDuration: (durationTimeFormat, durationFormatOutput) => string = "default"

type interval = {start: Js_date.t, end: Js_date.t}

@module("date-fns/intervalToDuration")
external intervalToDuration: interval => durationTimeFormat = "default"

@module("date-fns/fromUnixTime") external fromUnixTime: float => Js.Date.t = "default"
