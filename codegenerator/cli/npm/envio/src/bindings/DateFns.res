/**
Formats: 
hh:mm:ss         | 00:00:00
do MMM ''yy      | 1st Jan '21
ha do MMM ''yy   | 8PM 1st Jan '21
ha               | 8PM
iii              | Tues
iii MMM          | Tues Jan
MMM              | Jan
`)
*/
type dateFormats =
  | @as("HH:mm:ss") HoursMinSec
  | @as("ha") Hour
  | @as("do MMM ''yy") DayMonthYear
  | @as("ha do MMM ''yy") HourDayMonthYear
  | @as("h:mma do MMM ''yy") HourMinDayMonthYear
  | @as("iii") DayName
  | @as("iii MMM") DayNameMonth
  | @as("do MMM") DayMonth
  | @as("MMM") Month
  | @as("h:mma") HourMin

@module("date-fns") external format: (Js.Date.t, dateFormats) => string = "format"

type formatDistanceToNowOptions = {includeSeconds: bool}
@module("date-fns")
external formatDistanceToNow: Js.Date.t => string = "formatDistanceToNow"

@module("date-fns")
external formatDistance: (Js.Date.t, Js.Date.t) => string = "formatDistance"

@module("date-fns")
external formatDistanceWithOptions: (Js.Date.t, Js.Date.t, formatDistanceToNowOptions) => string =
  "formatDistance"

@module("date-fns")
external formatDistanceToNowWithOptions: (Js.Date.t, formatDistanceToNowOptions) => string =
  "formatDistanceToNow"

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

@module("date-fns")
external formatRelative: (Js.Date.t, Js.Date.t) => string = "formatRelative"

type durationFormatOutput = {format: array<string>}

@module("date-fns")
external formatDuration: (durationTimeFormat, durationFormatOutput) => string = "formatDuration"

type interval = {start: Js_date.t, end: Js_date.t}

@module("date-fns")
external intervalToDuration: interval => durationTimeFormat = "intervalToDuration"

//helper to convert millis elapsed to duration object
let durationFromMillis = (millis: int) =>
  intervalToDuration({start: 0->Utils.magic, end: millis->Utils.magic})

@module("date-fns") external fromUnixTime: float => Js.Date.t = "fromUnixTime"
