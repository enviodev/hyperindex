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

@module("date-fns") external format: (Date.t, dateFormats) => string = "format"

type formatDistanceToNowOptions = {includeSeconds: bool}
@module("date-fns")
external formatDistanceToNow: Date.t => string = "formatDistanceToNow"

@module("date-fns")
external formatDistance: (Date.t, Date.t) => Date.t = "formatDistance"

@module("date-fns")
external formatDistanceWithOptions: (Date.t, Date.t, formatDistanceToNowOptions) => string =
  "formatDistance"

@module("date-fns")
external formatDistanceToNowWithOptions: (Date.t, formatDistanceToNowOptions) => string =
  "formatDistanceToNow"

let formatDistanceToNowWithSeconds = (date: Date.t) =>
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
external formatRelative: (Date.t, Date.t) => string = "formatRelative"

type durationFormatOutput = {format: array<string>}

@module("date-fns")
external formatDuration: (durationTimeFormat, durationFormatOutput) => string = "formatDuration"

type interval = {start: Date.t, end: Date.t}

@module("date-fns")
external intervalToDuration: interval => durationTimeFormat = "intervalToDuration"

//helper to convert millis elapsed to duration object
let durationFromMillis = (millis: int) =>
  intervalToDuration({start: 0->Utils.magic, end: millis->Utils.magic})

@module("date-fns") external fromUnixTime: float => Date.t = "fromUnixTime"
