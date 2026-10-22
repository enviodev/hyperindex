// The `msg` of every line a file logger has written to `path` so far, or none
// before the file exists.
let messages = async path =>
  switch await NodeJs.Fs.Promises.readFile(~filepath=NodeJs.Path.resolve([path]), ~encoding=Utf8) {
  | contents =>
    // The logger writes from a thread of its own and ends every line with a
    // newline, so whatever follows the last one is a line still being written.
    let lines = contents->String.split("\n")
    lines
    ->Array.slice(~start=0, ~end=lines->Array.length - 1)
    ->Array.filterMap(line =>
      switch line->JSON.parseOrThrow->JSON.Decode.object {
      | Some(fields) => fields->Dict.get("msg")->Option.flatMap(JSON.Decode.string)
      | None => None
      }
    )
  | exception _ => []
  }
