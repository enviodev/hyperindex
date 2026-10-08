type result =
  | Passed
  | TypeErrors(string)
  | Skipped(string)

let timeoutMinutes = 10

// tsc's pretty output reads the same from TypeScript 5 to 7: a diagnostic
// starts unindented with its location, its code frame and related locations
// follow indented, and `--listFiles` prints the program's files after the
// last one, before the closing summary.
let fileDiagnostic = /^(.+):\d+:\d+ - error TS\d+: /
let globalDiagnostic = /^error TS\d+: /
let summary = /^Found \d+ errors?\b/
let thrownError = /^\w*Error: /

let lines = output => output->String.replaceAll("\r\n", "\n")->String.split("\n")

let rec findUp = (directory, name) => {
  let candidate = NodeJs.Path.resolve([directory, name])->NodeJs.Path.toString
  if NodeJs.Fs.existsSync(candidate) {
    Some(candidate)
  } else {
    let parent = NodeJs.Path.dirname(directory)->NodeJs.Path.toString
    parent === directory ? None : findUp(parent, name)
  }
}

// The `tsc` the project's own scripts run. TypeScript 7 has no JavaScript API
// to call instead, only this command.
let resolveTsc = (~cwd) =>
  try {
    let manifest =
      NodeJs.Module.createRequire(
        NodeJs.Path.resolve([cwd, "package.json"])->NodeJs.Path.toString,
      )->NodeJs.Module.resolve("typescript/package.json")
    let bin = switch NodeJs.Fs.readFileSync(manifest)->JSON.parseOrThrow {
    | JSON.Object(fields) =>
      switch fields->Dict.get("bin") {
      | Some(JSON.String(bin)) => Some(bin)
      | Some(JSON.Object(bins)) =>
        switch bins->Dict.get("tsc") {
        | Some(JSON.String(bin)) => Some(bin)
        | _ => None
        }
      | _ => None
      }
    | _ => None
    }
    bin->Option.map(bin =>
      NodeJs.Path.resolve([
        NodeJs.Path.dirname(manifest)->NodeJs.Path.toString,
        bin,
      ])->NodeJs.Path.toString
    )
  } catch {
  | _ => None
  }

type run = {error: option<NodeJs.ChildProcess.execFileError>, output: string}

let runTsc = (~tsc, ~cwd, args) =>
  Promise.make((resolve, _) =>
    NodeJs.ChildProcess.execFile(
      NodeJs.Process.process->NodeJs.Process.execPath,
      [tsc]->Array.concat(args),
      {cwd, timeout: timeoutMinutes * 60 * 1000, maxBuffer: Float.Constants.positiveInfinity},
      (error, stdout, stderr) =>
        resolve({
          error: error->Null.toOption,
          output: NodeJs.Util.stripVTControlCharacters(stdout ++ stderr),
        }),
    )
  )

type diagnostic = {file: string, lines: array<string>}

// Paths compare relative to the project, which on Windows also ignores the
// case of a drive letter tsc may print differently.
let parse = (output, ~cwd) => {
  let relative = file =>
    NodeJs.Path.relative(cwd, NodeJs.Path.resolve([cwd, file])->NodeJs.Path.toString)
  let diagnostics = []
  let programFiles = Utils.Set.make()
  let current = ref(None)
  output
  ->lines
  ->Array.forEach(line =>
    switch fileDiagnostic->RegExp.exec(line)->Option.map(RegExp.Result.matches) {
    | Some([Some(file)]) =>
      let diagnostic = {file: relative(file), lines: [line]}
      diagnostics->Array.push(diagnostic)
      current := Some(diagnostic)
    | _ if NodeJs.Path.isAbsolute(line) =>
      programFiles->Utils.Set.add(relative(line))->ignore
      current := None
    | _ if globalDiagnostic->RegExp.test(line) || summary->RegExp.test(line) => current := None
    | _ => current.contents->Option.forEach(diagnostic => diagnostic.lines->Array.push(line))
    }
  )
  (diagnostics, programFiles)
}

// Exit codes say nothing here: TypeScript 5 and 6 exit with 2 on type errors,
// 7 with 1, and 1 is also how its launcher fails when the native compiler
// isn't installed.
let failure = ({error, output}) =>
  switch error {
  | Some({killed: true}) => `tsc didn't finish within ${timeoutMinutes->Int.toString} minutes.`
  | _ =>
    output
    ->lines
    ->Array.find(line => thrownError->RegExp.test(line))
    ->Option.getOr(output->String.trim)
  }

let check = async (~cwd, ~files) => {
  // The ReScript compiler checks a ReScript project's handlers, so it has no
  // reason to set up TypeScript, and the warning would only be noise there.
  // `rescript.json` at the root is what makes codegen treat it as ReScript.
  let skip = warning =>
    NodeJs.Fs.existsSync(NodeJs.Path.resolve([cwd, "rescript.json"])->NodeJs.Path.toString)
      ? Passed
      : Skipped(warning)

  switch (resolveTsc(~cwd), findUp(cwd, "tsconfig.json")) {
  | (None, _) => skip("Skipped the handler type check: the project doesn't depend on typescript.")
  | (_, None) =>
    skip(
      "Skipped the handler type check: no tsconfig.json found. Add one to type-check handlers on start, like the one envio init creates.",
    )
  | (Some(tsc), Some(tsconfig)) =>
    // The project's own `tsc --noEmit`, minus the build info it would write.
    // `explainFiles` would replace the listed files' absolute paths with
    // relative ones and the reasons each is included.
    let run = await runTsc(
      ~tsc,
      ~cwd,
      [
        "--project",
        tsconfig,
        "--noEmit",
        "--incremental",
        "false",
        "--composite",
        "false",
        "--listFiles",
        "--explainFiles",
        "false",
        "--pretty",
      ],
    )
    let (diagnostics, programFiles) = run.output->parse(~cwd)
    // Only the handlers' errors count.
    let handlers = files->Array.map(file => NodeJs.Path.relative(cwd, file))
    let errors =
      diagnostics->Array.filterMap(({file, lines}) =>
        handlers->Array.includes(file) ? Some(lines->Array.join("\n")->String.trimEnd) : None
      )
    let unchecked = handlers->Array.filter(file => !(programFiles->Utils.Set.has(file)))
    if run.error->Option.isSome && diagnostics->Array.length === 0 {
      let reason = failure(run)
      Skipped(
        `Skipped the handler type check: TypeScript's tsc failed without reporting a type error:\n\n${reason}`,
      )
    } else if errors->Array.length > 0 {
      TypeErrors(errors->Array.join("\n\n"))
    } else if unchecked->Array.length > 0 {
      let names = unchecked->Array.join(", ")
      let tsconfig = NodeJs.Path.relative(cwd, tsconfig)
      let pronoun = unchecked->Array.length === 1 ? "it" : "them"
      Skipped(
        `Skipped the handler type check for ${names}: ${tsconfig} doesn't include ${pronoun}.`,
      )
    } else {
      Passed
    }
  }
}
