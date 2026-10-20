//! A manifest the repo renders from a template before graph-cli runs.
//!
//! graph-cli only ever reads a finished manifest; what a hosting user passes it
//! is the manifest path and `--network`. Many repos write that manifest first
//! with a package.json script — `mustache config/mainnet.json
//! subgraph.template.yaml > subgraph.yaml`, one per network or one taking the
//! network from a variable. envio reproduces such a script itself when every
//! step of it, up to graph-cli, is one of a few standard tool invocations
//! (`mustache`, `yaml2json`, `cat`, `echo`, `mkdir`), so the manifest is a pure
//! function of committed files and the network the user picks
//! (`ENVIO_SUBGRAPH_NETWORK`). A script that runs anything else — node,
//! truffle, a shell script, jq — is named in the error instead.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use serde_json::Value;

use super::mustache;
use crate::project_paths::path_utils::normalize_path;

#[derive(Debug, Clone, PartialEq)]
enum Part {
    Lit(String),
    Var {
        name: String,
        default: Option<String>,
    },
    /// `$(…)`, backticks, `${x:+…}`: nothing envio evaluates.
    Opaque,
}

type Word = Vec<Part>;

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Word(Word),
    Op(&'static str),
}

const OPERATORS: &[&str] = &[
    "&&", "||", ">>", "&>", ">&", "|", ";", "&", ">", "<", "(", ")", "\n",
];

fn lex(src: &str) -> Vec<Tok> {
    let chars: Vec<char> = src.chars().collect();
    let mut tokens = Vec::new();
    let mut i = 0;
    let rest = |i: usize| chars[i..].iter().collect::<String>();
    while i < chars.len() {
        let ch = chars[i];
        if ch == ' ' || ch == '\t' || ch == '\r' {
            i += 1;
            continue;
        }
        if ch == '#' {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
            continue;
        }
        let tail = rest(i);
        if let Some(op) = OPERATORS.iter().find(|op| tail.starts_with(**op)) {
            tokens.push(Tok::Op(if *op == "\n" { ";" } else { op }));
            i += op.chars().count();
            continue;
        }
        let mut word: Word = Vec::new();
        let push = |word: &mut Word, ch: char| match word.last_mut() {
            Some(Part::Lit(text)) => text.push(ch),
            _ => word.push(Part::Lit(ch.to_string())),
        };
        while i < chars.len() {
            let ch = chars[i];
            if matches!(
                ch,
                ' ' | '\t' | '\r' | '\n' | '&' | '|' | ';' | '<' | '>' | '(' | ')'
            ) {
                // `2>` is a redirect of fd 2, not the word "2".
                break;
            }
            match ch {
                '\'' => {
                    i += 1;
                    while i < chars.len() && chars[i] != '\'' {
                        push(&mut word, chars[i]);
                        i += 1;
                    }
                    i += 1;
                    if word.is_empty() {
                        word.push(Part::Lit(String::new()));
                    }
                }
                '"' => {
                    i += 1;
                    if word.is_empty() {
                        word.push(Part::Lit(String::new()));
                    }
                    while i < chars.len() && chars[i] != '"' {
                        match chars[i] {
                            '\\' if i + 1 < chars.len()
                                && matches!(chars[i + 1], '"' | '\\' | '$' | '`') =>
                            {
                                push(&mut word, chars[i + 1]);
                                i += 2;
                            }
                            '$' => i = expand(&chars, i, &mut word),
                            '`' => {
                                word.push(Part::Opaque);
                                i += 1;
                                while i < chars.len() && chars[i] != '`' {
                                    i += 1;
                                }
                                i += 1;
                            }
                            ch => {
                                push(&mut word, ch);
                                i += 1;
                            }
                        }
                    }
                    i += 1;
                }
                '\\' if i + 1 < chars.len() => {
                    if chars[i + 1] != '\n' {
                        push(&mut word, chars[i + 1]);
                    }
                    i += 2;
                }
                '$' => i = expand(&chars, i, &mut word),
                '`' => {
                    word.push(Part::Opaque);
                    i += 1;
                    while i < chars.len() && chars[i] != '`' {
                        i += 1;
                    }
                    i += 1;
                }
                ch => {
                    push(&mut word, ch);
                    i += 1;
                }
            }
        }
        // `2>file`: the fd number belongs to the redirect.
        if i < chars.len()
            && chars[i] == '>'
            && matches!(word.as_slice(), [Part::Lit(text)] if text.chars().all(|c| c.is_ascii_digit()))
        {
            continue;
        }
        tokens.push(Tok::Word(word));
    }
    tokens
}

/// A `$` expansion at `chars[i]`, appended to `word`; returns the index after it.
fn expand(chars: &[char], i: usize, word: &mut Word) -> usize {
    let next = chars.get(i + 1).copied();
    match next {
        Some('(') => {
            let mut depth = 0;
            let mut j = i + 1;
            while j < chars.len() {
                match chars[j] {
                    '(' => depth += 1,
                    ')' => {
                        depth -= 1;
                        if depth == 0 {
                            break;
                        }
                    }
                    _ => {}
                }
                j += 1;
            }
            word.push(Part::Opaque);
            j + 1
        }
        Some('{') => {
            let Some(end) = chars[i + 2..].iter().position(|ch| *ch == '}') else {
                word.push(Part::Opaque);
                return chars.len();
            };
            let body: String = chars[i + 2..i + 2 + end].iter().collect();
            let name_len = body
                .char_indices()
                .find(|(index, ch)| !(ch.is_ascii_alphanumeric() || *ch == '_') || *index > 64)
                .map(|(index, _)| index)
                .unwrap_or(body.len());
            let (name, op) = body.split_at(name_len);
            let part = if name.is_empty() {
                Part::Opaque
            } else if op.is_empty() {
                Part::Var {
                    name: name.to_string(),
                    default: None,
                }
            } else if let Some(default) = op.strip_prefix(":-").or_else(|| op.strip_prefix('-')) {
                if default.contains(['$', '`']) {
                    Part::Opaque
                } else {
                    Part::Var {
                        name: name.to_string(),
                        default: Some(default.trim_matches(['"', '\'']).to_string()),
                    }
                }
            } else {
                Part::Opaque
            };
            word.push(part);
            i + 3 + end
        }
        Some(ch) if ch.is_ascii_alphabetic() || ch == '_' => {
            let len = chars[i + 1..]
                .iter()
                .take_while(|ch| ch.is_ascii_alphanumeric() || **ch == '_')
                .count();
            word.push(Part::Var {
                name: chars[i + 1..i + 1 + len].iter().collect(),
                default: None,
            });
            i + 1 + len
        }
        Some(ch) if ch.is_ascii_digit() => {
            word.push(Part::Var {
                name: ch.to_string(),
                default: None,
            });
            i + 2
        }
        Some('@' | '*' | '#' | '?' | '!' | '-') => {
            word.push(Part::Opaque);
            i + 2
        }
        _ => {
            match word.last_mut() {
                Some(Part::Lit(text)) => text.push('$'),
                _ => word.push(Part::Lit("$".to_string())),
            }
            i + 1
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Redirect {
    Out,
    Append,
    In,
    /// `2>`, `&>`, `>&`: where errors go, which a render doesn't depend on.
    Other,
}

#[derive(Debug, Clone, Default)]
struct Stage {
    words: Vec<Word>,
    redirects: Vec<(Redirect, Word)>,
}

/// One pipeline of a script, and whether it runs only if the one before failed.
#[derive(Debug, Clone)]
struct Step {
    stages: Vec<Stage>,
    after_failure: bool,
    /// The package directory it runs in, when a workspace-wide script runs it
    /// in another package than the plan's.
    cwd: Option<PathBuf>,
}

fn parse_steps(script: &str) -> Option<Vec<Step>> {
    let mut steps = Vec::new();
    let mut stages = vec![Stage::default()];
    let mut after_failure = false;
    let mut tokens = lex(script).into_iter().peekable();
    let mut fd_redirect = false;
    while let Some(token) = tokens.next() {
        let stage = stages.last_mut().expect("a stage");
        match token {
            Tok::Word(word) => {
                // `2>&1`'s `1`, and `2>`'s fd: leftovers of an fd redirect.
                if fd_redirect {
                    fd_redirect = false;
                    stage.redirects.push((Redirect::Other, word));
                } else {
                    stage.words.push(word);
                }
            }
            Tok::Op(op @ (">" | ">>" | "<" | "&>" | ">&")) => {
                let kind = match op {
                    ">" => Redirect::Out,
                    ">>" => Redirect::Append,
                    "<" => Redirect::In,
                    _ => Redirect::Other,
                };
                // A digit word just before `>` (`2>`) was lexed as a word.
                let fd = matches!(stage.words.last().map(|w| w.as_slice()), Some([Part::Lit(text)]) if text.chars().all(|c| c.is_ascii_digit()))
                    && kind != Redirect::In;
                let kind = if fd {
                    let digits = stage.words.pop();
                    if digits != Some(vec![Part::Lit("1".to_string())]) {
                        Redirect::Other
                    } else {
                        kind
                    }
                } else {
                    kind
                };
                match tokens.next() {
                    Some(Tok::Word(target)) => stage.redirects.push((kind, target)),
                    Some(Tok::Op("&")) if op == ">" => {
                        fd_redirect = true;
                    }
                    _ => return None,
                }
            }
            Tok::Op("|") => stages.push(Stage::default()),
            Tok::Op(op @ ("&&" | "||" | ";")) => {
                if stages.iter().any(|stage| !stage.words.is_empty()) {
                    steps.push(Step {
                        stages: std::mem::replace(&mut stages, vec![Stage::default()]),
                        after_failure,
                        cwd: None,
                    });
                }
                after_failure = op == "||";
            }
            // Subshells and background jobs.
            Tok::Op(_) => return None,
        }
    }
    if stages.iter().any(|stage| !stage.words.is_empty()) {
        steps.push(Step {
            stages,
            after_failure,
            cwd: None,
        });
    }
    Some(steps)
}

fn literal(word: &Word) -> Option<String> {
    let mut text = String::new();
    for part in word {
        match part {
            Part::Lit(lit) => text.push_str(lit),
            _ => return None,
        }
    }
    Some(text)
}

fn word_text(word: &Word) -> String {
    word.iter()
        .map(|part| match part {
            Part::Lit(text) => text.clone(),
            Part::Var {
                name,
                default: None,
            } => format!("${{{name}}}"),
            Part::Var {
                name,
                default: Some(default),
            } => format!("${{{name}:-{default}}}"),
            Part::Opaque => "$(…)".to_string(),
        })
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
enum Command {
    Mustache {
        view: Word,
        template: Word,
        output: Option<Word>,
    },
    Yaml2Json(Word),
    Cat(Vec<Word>),
    Echo(Vec<Word>),
    /// `mkdir`, `true`, `rm`: nothing a render reads.
    NoOp,
    /// `cp <from> <to>`: Aave copies the schema of its version in.
    Copy {
        from: Word,
        to: Word,
    },
    /// graph-cli itself: what follows is envio's job, not the render's.
    Graph,
    /// `npm run <script>` (`yarn <script>`, `pnpm <script>`), with the
    /// variables set for it: inlined, so its steps are read with them bound.
    RunScript {
        name: String,
        env: Vec<(String, Word)>,
    },
    /// `yarn workspaces run <script>` (`npm run <script> --workspaces`, `pnpm
    /// -r run <script>`, `lerna run`, `turbo run`): that script of every
    /// workspace package that has it, each in its own directory.
    FanOut {
        name: String,
        env: Vec<(String, Word)>,
    },
    Other(String),
}

fn assignment(word: &Word) -> Option<(String, Word)> {
    let Some(Part::Lit(text)) = word.first() else {
        return None;
    };
    let (name, value) = text.split_once('=')?;
    let valid = !name.is_empty()
        && name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
        && !name.starts_with(|ch: char| ch.is_ascii_digit());
    if !valid {
        return None;
    }
    let mut rest = vec![Part::Lit(value.to_string())];
    rest.extend(word[1..].iter().cloned());
    Some((name.to_string(), rest))
}

/// The script a workspace-wide command runs: `yarn workspaces run X`, `yarn
/// workspaces foreach [-A …] run X`, `lerna run X`, `turbo run X`, `pnpm -r
/// [run] X`.
fn fan_out_script(tool: &str, words: &[&Word]) -> Option<String> {
    let texts: Vec<String> = words.iter().filter_map(|word| literal(word)).collect();
    let after = |marker: &str| {
        texts
            .iter()
            .position(|text| text == marker)
            .and_then(|at| texts[at + 1..].iter().find(|text| !text.starts_with('-')))
            .cloned()
    };
    match tool {
        "yarn" => after("run"),
        "lerna" | "turbo" => after("run"),
        "pnpm"
            if texts
                .iter()
                .any(|text| text == "-r" || text == "--recursive") =>
        {
            after("run").or_else(|| {
                texts[1..]
                    .iter()
                    .find(|text| !text.starts_with('-'))
                    .cloned()
            })
        }
        _ => None,
    }
}

fn classify(words: &[Word]) -> Command {
    let mut words: Vec<&Word> = words.iter().collect();
    let mut env: Vec<(String, Word)> = Vec::new();
    loop {
        while let Some(pair) = words.first().and_then(|word| assignment(word)) {
            env.push(pair);
            words.remove(0);
        }
        let Some(first) = words.first().and_then(|word| literal(word)) else {
            return Command::Other(words.first().map(|w| word_text(w)).unwrap_or_default());
        };
        let name = first.rsplit('/').next().unwrap_or(&first).to_string();
        let second = words.get(1).and_then(|word| literal(word));
        match (name.as_str(), second.as_deref()) {
            ("npx", _) => {
                words.remove(0);
                while words
                    .first()
                    .and_then(|word| literal(word))
                    .is_some_and(|text| text.starts_with('-'))
                {
                    words.remove(0);
                }
            }
            ("cross-env" | "env", _) => {
                words.remove(0);
            }
            // env-cmd loads a .env file of deploy keys; a render reads none.
            ("env-cmd", _) => {
                words.remove(0);
                while let Some(flag) = words.first().and_then(|word| literal(word)) {
                    if !flag.starts_with('-') {
                        break;
                    }
                    words.remove(0);
                    if matches!(
                        flag.as_str(),
                        "-f" | "--file" | "-e" | "--environments" | "-r" | "--rc-file"
                    ) {
                        if words.is_empty() {
                            break;
                        }
                        words.remove(0);
                    }
                }
            }
            ("yarn", Some("workspaces")) | ("lerna" | "turbo", Some("run")) | ("pnpm", _)
                if fan_out_script(&name, &words).is_some() =>
            {
                return Command::FanOut {
                    name: fan_out_script(&name, &words).expect("checked"),
                    env,
                };
            }
            ("npm", Some("run" | "run-script"))
                if words.iter().any(|word| {
                    matches!(literal(word).as_deref(), Some("--workspaces" | "-ws"))
                }) =>
            {
                return match words.get(2).and_then(|word| literal(word)) {
                    Some(name) => Command::FanOut { name, env },
                    None => Command::Other("npm run --workspaces".to_string()),
                };
            }
            ("npm" | "pnpm" | "yarn" | "bun", Some("run" | "run-script")) => {
                return match words.get(2).and_then(|word| literal(word)) {
                    Some(name) => Command::RunScript { name, env },
                    None => Command::Other(format!("{name} run")),
                };
            }
            ("npm" | "pnpm", Some("exec" | "dlx")) | ("yarn", Some("exec")) => {
                words.drain(..2);
                if words.first().and_then(|word| literal(word)).as_deref() == Some("--") {
                    words.remove(0);
                }
            }
            ("yarn" | "pnpm", Some("mustache" | "yaml2json" | "graph")) => {
                words.remove(0);
            }
            ("yarn" | "pnpm", Some(script)) if !script.starts_with('-') => {
                return Command::RunScript {
                    name: script.to_string(),
                    env,
                };
            }
            ("cp", _) => {
                return match &words[1..] {
                    [from, to]
                        if [from, to].iter().all(|word| {
                            literal(word).is_none_or(|text| !text.starts_with('-'))
                        }) =>
                    {
                        Command::Copy {
                            from: (*from).clone(),
                            to: (*to).clone(),
                        }
                    }
                    _ => Command::Other("cp".to_string()),
                };
            }
            ("mustache", _) => {
                let args: Vec<&Word> = words[1..].to_vec();
                if args.iter().any(|word| {
                    literal(word).is_some_and(|text| text.starts_with('-') && text != "-")
                        || word.contains(&Part::Opaque)
                }) {
                    // Partials (`-p`) and options the CLI may grow.
                    return Command::Other(format!(
                        "mustache {}",
                        args.iter()
                            .map(|w| word_text(w))
                            .collect::<Vec<_>>()
                            .join(" ")
                    ));
                }
                return match args.as_slice() {
                    [view, template] => Command::Mustache {
                        view: (*view).clone(),
                        template: (*template).clone(),
                        output: None,
                    },
                    [view, template, output] => Command::Mustache {
                        view: (*view).clone(),
                        template: (*template).clone(),
                        output: Some((*output).clone()),
                    },
                    _ => Command::Other("mustache".to_string()),
                };
            }
            ("yaml2json", _) => {
                let args: Vec<&Word> = words[1..]
                    .iter()
                    .copied()
                    .filter(|word| !matches!(literal(word).as_deref(), Some("-p" | "--pretty")))
                    .collect();
                return match args.as_slice() {
                    [file] if literal(file).is_none_or(|text| !text.starts_with('-')) => {
                        Command::Yaml2Json((*file).clone())
                    }
                    _ => Command::Other("yaml2json".to_string()),
                };
            }
            ("cat", _) => {
                let args: Vec<Word> = words[1..].iter().map(|word| (*word).clone()).collect();
                if args
                    .iter()
                    .any(|word| literal(word).is_some_and(|text| text.starts_with('-')))
                {
                    return Command::Other("cat".to_string());
                }
                return Command::Cat(args);
            }
            ("echo", _) => {
                let args: Vec<Word> = words[1..].iter().map(|word| (*word).clone()).collect();
                if args
                    .first()
                    .and_then(literal)
                    .is_some_and(|text| text.starts_with('-'))
                {
                    return Command::Other("echo".to_string());
                }
                return Command::Echo(args);
            }
            ("mkdir" | "true" | "rm" | "rimraf", _) => return Command::NoOp,
            ("graph", _) => return Command::Graph,
            _ => {
                return Command::Other(
                    words
                        .iter()
                        .map(|word| word_text(word))
                        .collect::<Vec<_>>()
                        .join(" "),
                )
            }
        }
    }
}

/// A package.json script that writes the manifest the way envio can repeat.
#[derive(Debug, Clone)]
struct Plan {
    /// The package directory the script runs in.
    dir: PathBuf,
    script: String,
    /// The scripts it runs through `npm run`, inlined into `steps`.
    inlined: Vec<String>,
    steps: Vec<Step>,
    /// The variable that picks the view (`config/${NETWORK:-mainnet}.json`),
    /// with the script's own default, and the word it appears in.
    hole: Option<(String, Option<String>, Word)>,
    /// The view of the mustache call that writes the manifest.
    view: Word,
    template: String,
}

/// A script that writes the manifest, but with a step envio doesn't run.
#[derive(Debug, Clone)]
struct Writer {
    script: String,
    step: String,
    /// The scripts it runs through `npm run`.
    inlined: Vec<String>,
}

fn vars(word: &Word) -> Vec<(String, Option<String>)> {
    word.iter()
        .filter_map(|part| match part {
            Part::Var { name, default } => Some((name.clone(), default.clone())),
            _ => None,
        })
        .collect()
}

fn same_path(dir: &Path, word: &Word, target: &Path) -> bool {
    literal(word).is_some_and(|text| normalize_path(dir.join(text)) == target)
}

fn bind(word: &Word, bindings: &BTreeMap<String, String>) -> Word {
    word.iter()
        .map(|part| match part {
            Part::Var { name, .. } if bindings.contains_key(name) => {
                Part::Lit(bindings[name].clone())
            }
            part => part.clone(),
        })
        .collect()
}

/// `steps` with every `npm run <script>` the script itself is replaced by,
/// read with the variables the call sets — a shell passes them to the
/// script's own commands, not to the words of the call.
fn inline_scripts(
    scripts: &BTreeMap<String, String>,
    steps: Vec<Step>,
    bindings: &BTreeMap<String, String>,
    depth: usize,
    names: &mut Vec<String>,
    dir: &Path,
) -> Vec<Step> {
    let mut inlined = Vec::new();
    for step in steps {
        let step = Step {
            stages: step
                .stages
                .iter()
                .map(|stage| Stage {
                    words: stage
                        .words
                        .iter()
                        .map(|word| bind(word, bindings))
                        .collect(),
                    redirects: stage
                        .redirects
                        .iter()
                        .map(|(kind, word)| (*kind, bind(word, bindings)))
                        .collect(),
                })
                .collect(),
            after_failure: step.after_failure,
            cwd: step.cwd,
        };
        let call = match step.stages.as_slice() {
            [stage] if stage.redirects.is_empty() && !step.after_failure && depth < 5 => {
                match classify(&stage.words) {
                    Command::RunScript { name, env } => Some((name, env, false)),
                    Command::FanOut { name, env } => Some((name, env, true)),
                    _ => None,
                }
            }
            _ => None,
        };
        let scoped = |env: Vec<(String, Word)>| {
            let mut scoped = bindings.clone();
            for (variable, value) in env {
                if let Some(value) = literal(&value) {
                    scoped.insert(variable, value);
                }
            }
            scoped
        };
        let inner = call.and_then(|(name, env, fan_out)| {
            let scoped = scoped(env);
            if !fan_out {
                let text = scripts.get(&name)?;
                let steps = parse_steps(text)?;
                names.push(name);
                return Some(inline_scripts(
                    scripts,
                    steps,
                    &scoped,
                    depth + 1,
                    names,
                    dir,
                ));
            }
            // Each workspace package that has the script runs it in its own
            // directory, with its own scripts.
            let mut all = Vec::new();
            for package in workspace_package_dirs(dir) {
                let package_scripts: BTreeMap<String, String> =
                    package_scripts(&package).into_iter().collect();
                let Some(steps) = package_scripts
                    .get(&name)
                    .and_then(|text| parse_steps(text))
                else {
                    continue;
                };
                let inner =
                    inline_scripts(&package_scripts, steps, &scoped, depth + 1, names, &package);
                all.extend(inner.into_iter().map(|step| Step {
                    cwd: step.cwd.or_else(|| Some(package.clone())),
                    ..step
                }));
            }
            names.push(name);
            Some(all)
        });
        match inner {
            Some(inner) => inlined.extend(inner),
            None => inlined.push(step),
        }
    }
    inlined
}

/// The directories of the workspace whose root is `dir`: package.json
/// `workspaces` (npm, yarn) or pnpm-workspace.yaml globs, as the runtime
/// reads them.
pub(crate) fn workspace_package_dirs(dir: &Path) -> Vec<PathBuf> {
    let manifest = std::fs::read_to_string(dir.join("package.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok());
    let declared = manifest.as_ref().and_then(|manifest| {
        let workspaces = manifest.get("workspaces")?;
        workspaces
            .as_array()
            .or_else(|| workspaces.get("packages")?.as_array())
            .cloned()
    });
    let mut globs: Vec<String> = declared
        .unwrap_or_default()
        .iter()
        .filter_map(|glob| glob.as_str().map(str::to_string))
        .collect();
    if globs.is_empty() {
        if let Ok(pnpm) = std::fs::read_to_string(dir.join("pnpm-workspace.yaml")) {
            if let Ok(yaml) = serde_yaml::from_str::<serde_yaml::Value>(&pnpm) {
                globs = yaml
                    .get("packages")
                    .and_then(|packages| packages.as_sequence())
                    .map(|packages| {
                        packages
                            .iter()
                            .filter_map(|glob| glob.as_str().map(str::to_string))
                            .collect()
                    })
                    .unwrap_or_default();
            }
        }
    }
    let mut dirs: Vec<PathBuf> = Vec::new();
    for glob in globs.iter().filter(|glob| !glob.starts_with('!')) {
        let mut current = vec![dir.to_path_buf()];
        for part in glob
            .trim_start_matches("./")
            .trim_end_matches('/')
            .split('/')
        {
            let mut next = Vec::new();
            for base in &current {
                let entries = || -> Vec<PathBuf> {
                    std::fs::read_dir(base)
                        .map(|entries| {
                            let mut paths: Vec<PathBuf> = entries
                                .filter_map(|entry| entry.ok())
                                .map(|entry| entry.path())
                                .filter(|path| {
                                    path.is_dir()
                                        && path.file_name().is_some_and(|name| {
                                            name != "node_modules"
                                                && !name.to_string_lossy().starts_with('.')
                                        })
                                })
                                .collect();
                            paths.sort();
                            paths
                        })
                        .unwrap_or_default()
                };
                if part == "**" {
                    let mut stack = vec![(base.clone(), 0)];
                    while let Some((path, depth)) = stack.pop() {
                        next.push(path.clone());
                        if depth < 4 {
                            let saved = std::fs::read_dir(&path)
                                .map(|entries| {
                                    entries
                                        .filter_map(|entry| entry.ok())
                                        .map(|entry| entry.path())
                                        .filter(|path| {
                                            path.is_dir()
                                                && path.file_name().is_some_and(|name| {
                                                    name != "node_modules"
                                                        && !name.to_string_lossy().starts_with('.')
                                                })
                                        })
                                        .collect::<Vec<_>>()
                                })
                                .unwrap_or_default();
                            stack.extend(saved.into_iter().map(|path| (path, depth + 1)));
                        }
                    }
                } else if part.contains('*') {
                    let pattern = format!(
                        "^{}$",
                        part.split('*')
                            .map(regex::escape)
                            .collect::<Vec<_>>()
                            .join("[^/]*")
                    );
                    let Ok(pattern) = regex::Regex::new(&pattern) else {
                        continue;
                    };
                    next.extend(entries().into_iter().filter(|path| {
                        path.file_name()
                            .is_some_and(|name| pattern.is_match(&name.to_string_lossy()))
                    }));
                } else if base.join(part).is_dir() {
                    next.push(base.join(part));
                }
            }
            current = next;
        }
        for path in current {
            if path.join("package.json").exists() && !dirs.contains(&path) {
                dirs.push(path);
            }
        }
    }
    dirs
}

/// Whether a step runs a file of the repo (`ts-node ./script/build`, `node
/// ops/render.js`, `./build.sh`) whose source mentions one of `needles`:
/// Uniswap's build script is what writes its manifest. The file is read,
/// never run.
fn runs_a_file_mentioning(dir: &Path, steps: &[Step], needles: &[&str]) -> bool {
    const EXTENSIONS: &[&str] = &["", ".ts", ".js", ".mjs", ".cjs", ".sh"];
    let find = |base: &Path, word: &str| -> Option<PathBuf> {
        EXTENSIONS
            .iter()
            .map(|extension| base.join(format!("{word}{extension}")))
            .find(|file| {
                file.is_file() && std::fs::metadata(file).is_ok_and(|m| m.len() < 1_000_000)
            })
    };
    let mentions = |file: &Path| {
        std::fs::read_to_string(file)
            .is_ok_and(|text| needles.iter().any(|needle| text.contains(needle)))
    };
    // Uniswap's script/build.ts imports the module that reads the template.
    let imports = regex::Regex::new(r#"(?:from\s*|require\s*\(\s*)["'](\.\.?/[^"']+)["']"#)
        .expect("a valid regex");
    steps.iter().flat_map(|step| &step.stages).any(|stage| {
        stage.words.iter().filter_map(literal).any(|word| {
            if word.starts_with('-') || word.contains("://") || Path::new(&word).is_absolute() {
                return false;
            }
            let Some(file) = find(dir, &word) else {
                return false;
            };
            if mentions(&file) {
                return true;
            }
            let base = file.parent().unwrap_or(dir).to_path_buf();
            std::fs::read_to_string(&file).is_ok_and(|text| {
                imports
                    .captures_iter(&text)
                    .filter_map(|captures| find(&base, &captures[1]))
                    .any(|imported| mentions(&imported))
            })
        })
    })
}

/// How a script relates to the manifest at `target`: a plan when envio can
/// repeat it, a writer when it can't, or nothing.
fn analyze(
    dir: &Path,
    name: &str,
    script: &str,
    target: &Path,
    scripts: &BTreeMap<String, String>,
) -> Option<Result<Plan, Writer>> {
    let mentions = script.contains(
        target
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default()
            .as_str(),
    );
    let Some(steps) = parse_steps(script) else {
        return mentions.then(|| {
            Err(Writer {
                script: name.to_string(),
                step: script.to_string(),
                inlined: Vec::new(),
            })
        });
    };
    let mut inlined = Vec::new();
    let steps = inline_scripts(scripts, steps, &BTreeMap::new(), 0, &mut inlined, dir);
    let mut unsupported: Option<String> = None;
    let mut writes: Option<(Word, String)> = None;
    let mut holes: Vec<(String, Option<String>, Word)> = Vec::new();
    'steps: for step in &steps {
        if step.after_failure {
            continue;
        }
        let mut stdin_view: Option<Word> = None;
        let step_dir = step.cwd.as_deref().unwrap_or(dir);
        // A template and view another package's script names are kept
        // relative to the plan's directory.
        let from_plan = |word: &Word| -> Word {
            match (step.cwd.as_ref(), literal(word)) {
                (Some(cwd), Some(text)) if text != "-" => vec![Part::Lit(
                    pathdiff::diff_paths(normalize_path(cwd.join(&text)), dir)
                        .map(|path| path.display().to_string())
                        .unwrap_or(text),
                )],
                _ => word.clone(),
            }
        };
        for (index, stage) in step.stages.iter().enumerate() {
            let command = classify(&stage.words);
            let last = index + 1 == step.stages.len();
            let writes_target = |output: &Word| same_path(step_dir, output, target);
            let mut inputs: Vec<Word> = Vec::new();
            match &command {
                Command::Graph => break 'steps,
                Command::Other(text) => {
                    unsupported.get_or_insert_with(|| text.clone());
                }
                Command::Mustache {
                    view,
                    template,
                    output,
                } => {
                    let view = if literal(view).as_deref() == Some("-") {
                        stdin_view.clone().unwrap_or_else(|| view.clone())
                    } else {
                        view.clone()
                    };
                    inputs.push(view.clone());
                    inputs.push(template.clone());
                    let into_target = output.as_ref().is_some_and(writes_target)
                        || (last
                            && stage.redirects.iter().any(|(kind, word)| {
                                matches!(kind, Redirect::Out | Redirect::Append)
                                    && writes_target(word)
                            }));
                    if into_target {
                        match literal(&from_plan(template)) {
                            Some(template) => writes = Some((from_plan(&view), template)),
                            None => {
                                unsupported.get_or_insert_with(|| word_text(template));
                            }
                        }
                    }
                }
                Command::Yaml2Json(file) => {
                    inputs.push(file.clone());
                    stdin_view = Some(file.clone());
                }
                Command::Cat(files) => {
                    inputs.extend(files.iter().cloned());
                    if let [file] = files.as_slice() {
                        stdin_view = Some(file.clone());
                        // defi.money copies a committed per-network manifest:
                        // `cat ./subgraph/arbitrum/prod.yaml > subgraph.yaml`.
                        let into_target = last
                            && stage
                                .redirects
                                .iter()
                                .any(|(kind, word)| *kind == Redirect::Out && writes_target(word));
                        if into_target {
                            let source = from_plan(file);
                            let text = literal(&source).unwrap_or_else(|| word_text(&source));
                            writes = Some((source, text));
                        }
                    }
                }
                Command::Copy { from, to } => {
                    inputs.push(from.clone());
                    // A copy's source is its view: `cp
                    // ./schemas/schema.${VERSION:-v1}.graphql schema.graphql`
                    // picks it by the variable.
                    if writes_target(to) {
                        let source = from_plan(from);
                        let file = literal(&source).unwrap_or_else(|| word_text(&source));
                        writes = Some((source, file));
                    }
                }
                Command::RunScript { name, .. } | Command::FanOut { name, .. } => {
                    unsupported.get_or_insert_with(|| format!("npm run {name}"));
                }
                Command::Echo(_) | Command::NoOp => {}
            }
            for (_, word) in &stage.redirects {
                if vars(word).iter().any(|(_, default)| default.is_none())
                    || word.contains(&Part::Opaque)
                {
                    unsupported.get_or_insert_with(|| word_text(word));
                }
            }
            for word in inputs {
                if word.contains(&Part::Opaque) {
                    unsupported.get_or_insert_with(|| word_text(&word));
                }
                for (var, default) in vars(&word) {
                    if !holes.iter().any(|(name, _, _)| *name == var) {
                        holes.push((var, default, word.clone()));
                    }
                }
            }
        }
    }
    let Some((view, template)) = writes else {
        // A script that may write it with a tool of its own: named in the
        // error, never run.
        let lowered = script.to_lowercase();
        let manifest_name = target
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default();
        let suspect = mentions
            || ["template", "mustache", "handlebars", ".hbs", "render"]
                .iter()
                .any(|word| lowered.contains(word))
            || ["render", "manifest", "template", "yaml"]
                .iter()
                .any(|word| name.to_lowercase().contains(word))
            || runs_a_file_mentioning(dir, &steps, &[&manifest_name, "template"]);
        return (unsupported.is_some() && suspect).then(|| {
            Err(Writer {
                script: name.to_string(),
                step: script.to_string(),
                inlined: inlined.clone(),
            })
        });
    };
    if unsupported.is_some() || holes.len() > 1 {
        return Some(Err(Writer {
            script: name.to_string(),
            step: script.to_string(),
            inlined,
        }));
    }
    Some(Ok(Plan {
        dir: dir.to_path_buf(),
        script: name.to_string(),
        inlined,
        steps,
        hole: holes.into_iter().next(),
        view,
        template,
    }))
}

/// The files a `word` with `hole` in it names under `dir`, by the hole's value.
fn expand_hole(dir: &Path, word: &Word, hole: &str) -> BTreeMap<String, PathBuf> {
    let mut pattern = String::from("^");
    for part in word {
        match part {
            Part::Lit(text) => pattern.push_str(&regex::escape(text)),
            Part::Var { name, .. } if name == hole => pattern.push_str("([^/]+)"),
            Part::Var {
                default: Some(default),
                ..
            } => pattern.push_str(&regex::escape(default)),
            _ => return BTreeMap::new(),
        }
    }
    pattern.push('$');
    let Ok(pattern) = regex::Regex::new(&pattern) else {
        return BTreeMap::new();
    };
    // Every directory the pattern can reach: its literal prefix, walked down
    // as deep as the pattern has components.
    let prefix: String = match word.first() {
        Some(Part::Lit(text)) => text
            .rsplit_once('/')
            .map(|(dir, _)| dir)
            .unwrap_or("")
            .to_string(),
        _ => String::new(),
    };
    let depth = word_text(word).matches('/').count() - prefix.matches('/').count();
    let mut found = BTreeMap::new();
    let mut pending = vec![(prefix.clone(), 0)];
    while let Some((relative, level)) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(dir.join(&relative)) else {
            continue;
        };
        for entry in entries.filter_map(|entry| entry.ok()) {
            let name = entry.file_name().to_string_lossy().to_string();
            let path = if relative.is_empty() {
                name
            } else {
                format!("{relative}/{name}")
            };
            if entry.path().is_dir() {
                if level < depth {
                    pending.push((path.clone(), level + 1));
                }
                continue;
            }
            let candidate = path.clone();
            if let Some(captures) = pattern.captures(&candidate) {
                let values: BTreeSet<&str> = captures
                    .iter()
                    .skip(1)
                    .flatten()
                    .map(|capture| capture.as_str())
                    .collect();
                if let [value] = values.into_iter().collect::<Vec<_>>().as_slice() {
                    found.insert(value.to_string(), dir.join(path));
                }
            }
        }
    }
    found
}

fn stem(path: &str) -> String {
    let file = path.rsplit('/').next().unwrap_or(path);
    file.split_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(file)
        .to_string()
}

/// The network each literal plan renders: the path component its view
/// differs in from the other scripts' (`config/<network>.json`,
/// `config/<network>/config.json`), else its view's file name.
fn literal_networks(plans: &[&Plan]) -> Vec<String> {
    // Seamless renders every network from one view (`generate-manifest-base`,
    // `generate-manifest-ethereum`): the scripts' names tell them apart.
    if let Some(suffixes) = script_suffixes(plans) {
        return suffixes;
    }
    let views: Vec<Vec<String>> = plans
        .iter()
        .map(|plan| {
            literal(&plan.view)
                .unwrap_or_default()
                .split('/')
                .map(str::to_string)
                .collect()
        })
        .collect();
    let same_shape = views.len() > 1 && views.iter().all(|view| view.len() == views[0].len());
    let differing: Vec<usize> = if same_shape {
        (0..views[0].len())
            .filter(|index| views.iter().any(|view| view[*index] != views[0][*index]))
            .collect()
    } else {
        Vec::new()
    };
    views
        .iter()
        .map(|view| match differing.as_slice() {
            [index] => stem(&view[*index]),
            _ => stem(&view.join("/")),
        })
        .collect()
}

/// What tells per-network scripts apart once their common prefix, up to a
/// `:` or `-`, is gone (`prepare:matic` → `matic`), when that is distinct
/// for each.
fn script_suffixes(plans: &[&Plan]) -> Option<Vec<String>> {
    if plans.len() < 2 {
        return None;
    }
    let first = plans[0].script.as_str();
    let mut common = first.len();
    for plan in &plans[1..] {
        common = common.min(
            first
                .chars()
                .zip(plan.script.chars())
                .take_while(|(a, b)| a == b)
                .count(),
        );
    }
    let prefix_end = first[..common].rfind([':', '-'])? + 1;
    let suffixes: Vec<String> = plans
        .iter()
        .map(|plan| plan.script[prefix_end..].to_string())
        .collect();
    let distinct: BTreeSet<&String> = suffixes.iter().collect();
    (distinct.len() == suffixes.len() && suffixes.iter().all(|suffix| !suffix.is_empty()))
        .then_some(suffixes)
}

/// The other scripts of the chosen network that are standard renders too
/// (Seamless' `generate-addresses-base` beside `generate-manifest-base`):
/// their steps, inlined. A script with any other step is left out.
fn sibling_renders(plan: &Plan, network: &str, target: &Path) -> Vec<(String, Vec<Step>)> {
    let all = package_scripts(&plan.dir);
    let scripts: BTreeMap<String, String> = all.iter().cloned().collect();
    all.iter()
        .filter(|(name, _)| {
            *name != plan.script
                && [":", "-"]
                    .iter()
                    .any(|separator| name.ends_with(&format!("{separator}{network}")))
        })
        .filter_map(|(name, script)| {
            let mut inlined = Vec::new();
            let steps = inline_scripts(
                &scripts,
                parse_steps(script)?,
                &BTreeMap::new(),
                0,
                &mut inlined,
                &plan.dir,
            );
            let mut writes = false;
            for stage in steps.iter().flat_map(|step| &step.stages) {
                match classify(&stage.words) {
                    Command::Graph => break,
                    Command::Mustache { .. }
                    | Command::Yaml2Json(_)
                    | Command::Cat(_)
                    | Command::Echo(_)
                    | Command::Copy { .. }
                    | Command::NoOp => {}
                    Command::RunScript { .. } | Command::FanOut { .. } | Command::Other(_) => {
                        return None
                    }
                }
                for (_, word) in &stage.redirects {
                    if same_path(&plan.dir, word, target) {
                        return None;
                    }
                    writes = true;
                }
                if let Command::Mustache {
                    output: Some(_), ..
                }
                | Command::Copy { .. } = classify(&stage.words)
                {
                    writes = true;
                }
            }
            writes.then(|| (name.clone(), steps))
        })
        .collect()
}

#[derive(Debug)]
struct Choice<'a> {
    plan: &'a Plan,
    network: String,
    hole_value: Option<String>,
    view: String,
}

/// The option whose manifest indexes `network`, when the user names the
/// network graph-node sees (`arbitrum-one`) rather than the scripts' name for
/// it (defi.money's `codegen:arb`). Only one may match.
fn choose_by_indexed_network<'a>(
    plans: &'a [Plan],
    network: &str,
    target: &Path,
) -> Option<Choice<'a>> {
    let mut matching = options(plans).into_iter().filter_map(|(_, choice)| {
        let mut run = Run {
            dir: &choice.plan.dir,
            cwd: choice.plan.dir.to_path_buf(),
            target,
            hole: None,
            files: BTreeMap::new(),
        };
        let hole_name = choice.plan.hole.as_ref().map(|(name, _, _)| name.clone());
        if let (Some(name), Some(value)) = (hole_name.as_deref(), choice.hole_value.as_deref()) {
            run.hole = Some((name, value));
        }
        run.steps(&choice.plan.steps).ok()?;
        let manifest: serde_yaml::Value = serde_yaml::from_str(run.files.get(target)?).ok()?;
        let sources = manifest.get("dataSources")?.as_sequence()?;
        let indexes = !sources.is_empty()
            && sources
                .iter()
                .all(|source| source.get("network").and_then(|n| n.as_str()) == Some(network));
        indexes.then_some(choice)
    });
    let first = matching.next()?;
    matching.next().is_none().then_some(first)
}

/// Every network the plans render, with how./// Every network the plans render, with how.
fn options<'a>(plans: &'a [Plan]) -> Vec<(String, Choice<'a>)> {
    let literal_plans: Vec<&Plan> = plans.iter().filter(|plan| plan.hole.is_none()).collect();
    let literal_names = literal_networks(&literal_plans);
    let mut options: Vec<(String, Choice<'a>)> = Vec::new();
    for plan in plans {
        if let Some((name, _, word)) = &plan.hole {
            for (value, path) in expand_hole(&plan.dir, word, name) {
                let view = pathdiff::diff_paths(&path, &plan.dir)
                    .unwrap_or(path)
                    .display()
                    .to_string();
                options.push((
                    value.clone(),
                    Choice {
                        plan,
                        network: value.clone(),
                        hole_value: Some(value),
                        view,
                    },
                ));
            }
        }
    }
    for (plan, name) in literal_plans.iter().zip(literal_names) {
        options.push((
            name.clone(),
            Choice {
                plan,
                network: name,
                hole_value: None,
                view: literal(&plan.view).unwrap_or_default(),
            },
        ));
    }
    options
}

fn choose<'a>(plans: &'a [Plan], network: Option<&str>) -> Result<Choice<'a>, Vec<String>> {
    let mut options = options(plans);
    // A workspace root's `yarn workspaces run prepare:<net>` also renders the
    // packages the mappings import; the package's own script renders only
    // its manifest.
    options.sort_by_key(|(_, choice)| !choice.plan.steps.iter().any(|step| step.cwd.is_some()));
    let mut names: Vec<String> = Vec::new();
    for (name, _) in &options {
        if !names.contains(name) {
            names.push(name.clone());
        }
    }
    let picked = match network {
        Some(network) => options.into_iter().find(|(name, choice)| {
            name == network
                || choice.plan.script == network
                || choice.plan.script.rsplit(':').next() == Some(network)
        }),
        None => {
            let default = plans.iter().find_map(|plan| {
                plan.hole
                    .as_ref()
                    .and_then(|(_, default, _)| default.clone())
            });
            match default {
                Some(default) if names.contains(&default) => {
                    options.into_iter().find(|(name, _)| *name == default)
                }
                _ if names.len() == 1 => options.into_iter().next(),
                _ => None,
            }
        }
    };
    picked.map(|(_, choice)| choice).ok_or(names)
}

enum Output {
    Text(String),
    Json(Value),
}

impl Output {
    fn text(self) -> String {
        match self {
            Output::Text(text) => text,
            Output::Json(value) => value.to_string(),
        }
    }
}

struct Run<'a> {
    dir: &'a Path,
    /// The directory the current step runs in.
    cwd: PathBuf,
    target: &'a Path,
    hole: Option<(&'a str, &'a str)>,
    files: BTreeMap<PathBuf, String>,
}

impl Run<'_> {
    fn resolve(&self, word: &Word) -> Result<PathBuf> {
        let mut text = String::new();
        for part in word {
            match part {
                Part::Lit(lit) => text.push_str(lit),
                Part::Var { name, .. } if self.hole.is_some_and(|(hole, _)| hole == name) => {
                    text.push_str(self.hole.expect("checked").1)
                }
                Part::Var {
                    default: Some(default),
                    ..
                } => text.push_str(default),
                _ => return Err(anyhow!("{} has a value envio can't know", word_text(word))),
            }
        }
        if Path::new(&text).is_absolute() {
            return Err(anyhow!("{text} is outside the project"));
        }
        Ok(normalize_path(self.cwd.join(text)))
    }

    fn read(&self, word: &Word) -> Result<String> {
        let path = self.resolve(word)?;
        if let Some(text) = self.files.get(&path) {
            return Ok(text.clone());
        }
        std::fs::read_to_string(&path).context(format!("Failed to read {}", path.display()))
    }

    fn word(&self, word: &Word) -> Result<String> {
        let path = self.resolve(word)?;
        Ok(pathdiff::diff_paths(path, self.dir)
            .map(|path| path.display().to_string())
            .unwrap_or_default())
    }

    fn write(&mut self, word: &Word, text: String, append: bool) -> Result<()> {
        let path = self.resolve(word)?;
        if !path.starts_with(self.dir) {
            return Err(anyhow!(
                "the script writes {}, outside the project",
                path.display()
            ));
        }
        let existing = match (append, self.files.get(&path)) {
            (false, _) => String::new(),
            (true, Some(text)) => text.clone(),
            // Appending to the manifest envio is writing anew starts it empty.
            (true, None) if path == self.target => String::new(),
            (true, None) => std::fs::read_to_string(&path).unwrap_or_default(),
        };
        self.files.insert(path, existing + &text);
        Ok(())
    }

    fn stage(&mut self, stage: &Stage, stdin: Option<Output>) -> Result<Output> {
        let stdin = match stage
            .redirects
            .iter()
            .find(|(kind, _)| *kind == Redirect::In)
        {
            Some((_, word)) => Some(Output::Text(self.read(word)?)),
            None => stdin,
        };
        Ok(match classify(&stage.words) {
            Command::Mustache {
                view,
                template,
                output,
            } => {
                let view_value = if literal(&view).as_deref() == Some("-") {
                    match stdin {
                        Some(Output::Json(value)) => value,
                        Some(Output::Text(text)) => serde_json::from_str(&text)
                            .context("mustache read a view from stdin that isn't JSON")?,
                        None => {
                            return Err(anyhow!(
                                "mustache reads its view from stdin, and nothing is piped in"
                            ))
                        }
                    }
                } else {
                    let file = self.word(&view)?;
                    if file.ends_with(".js") || file.ends_with(".cjs") {
                        return Err(anyhow!(
                            "the view {file} is a JavaScript module, which mustache runs"
                        ));
                    }
                    serde_json::from_str(&self.read(&view)?)
                        .context(format!("mustache's view {file} isn't JSON"))?
                };
                let rendered = mustache::render(&self.read(&template)?, &view_value).context(
                    format!("mustache failed to render {}", self.word(&template)?),
                )?;
                match output {
                    Some(output) => {
                        self.write(&output, rendered, false)?;
                        Output::Text(String::new())
                    }
                    None => Output::Text(rendered),
                }
            }
            Command::Yaml2Json(file) => {
                let yaml: serde_yaml::Value = serde_yaml::from_str(&self.read(&file)?)
                    .context(format!("{} isn't YAML", self.word(&file)?))?;
                Output::Json(serde_json::to_value(yaml)?)
            }
            Command::Cat(files) => {
                let mut text = String::new();
                for file in &files {
                    text.push_str(&self.read(file)?);
                }
                if files.is_empty() {
                    text = stdin.map(Output::text).unwrap_or_default();
                }
                Output::Text(text)
            }
            Command::Echo(words) => {
                let mut parts = Vec::new();
                for word in &words {
                    parts.push(match literal(word) {
                        Some(text) => text,
                        None => self.word(word)?,
                    });
                }
                Output::Text(format!("{}\n", parts.join(" ")))
            }
            Command::NoOp => Output::Text(String::new()),
            Command::Copy { from, to } => {
                let text = self.read(&from)?;
                self.write(&to, text, false)?;
                Output::Text(String::new())
            }
            Command::Graph
            | Command::RunScript { .. }
            | Command::FanOut { .. }
            | Command::Other(_) => unreachable!("plans hold only these"),
        })
    }

    fn steps(&mut self, steps: &[Step]) -> Result<()> {
        for step in steps {
            if step.after_failure {
                continue;
            }
            self.cwd = step.cwd.clone().unwrap_or_else(|| self.dir.to_path_buf());
            if step
                .stages
                .iter()
                .any(|stage| classify(&stage.words) == Command::Graph)
            {
                break;
            }
            let mut stdout: Option<Output> = None;
            for stage in &step.stages {
                let output = self.stage(stage, stdout.take())?;
                let outputs: Vec<&(Redirect, Word)> = stage
                    .redirects
                    .iter()
                    .filter(|(kind, _)| matches!(kind, Redirect::Out | Redirect::Append))
                    .collect();
                // A shell opens every `>` of a command in order, and the
                // output goes to the last.
                let Some(((last_kind, last), opened)) = outputs.split_last() else {
                    stdout = Some(output);
                    continue;
                };
                for (kind, word) in opened {
                    self.write(word, String::new(), *kind == Redirect::Append)?;
                }
                self.write(last, output.text(), *last_kind == Redirect::Append)?;
            }
        }
        Ok(())
    }
}

/// What envio rendered, for the log and for the codegen script to skip.
#[derive(Debug, Clone, PartialEq)]
pub struct Rendered {
    /// The manifest written: the one looked for, or the one the codegen
    /// script's `graph codegen <manifest>` builds.
    pub manifest: PathBuf,
    pub script: String,
    /// The scripts the one rendering runs through `npm run`.
    pub inlined: Vec<String>,
    pub network: String,
    pub template: String,
    pub view: String,
    pub files: Vec<PathBuf>,
    pub steps: Vec<String>,
}

/// Where envio records the manifests it wrote, so a later start renders them
/// again — for another `ENVIO_SUBGRAPH_NETWORK` — rather than reading one as
/// the user's own.
fn record_path(project_root: &Path) -> PathBuf {
    project_root.join(".envio").join("rendered-manifests.json")
}

fn digest(text: &str) -> String {
    use sha2::Digest;
    format!("{:x}", sha2::Sha256::digest(text.as_bytes()))
}

fn rendered_by_envio(project_root: &Path, target: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(target) else {
        return false;
    };
    std::fs::read_to_string(record_path(project_root))
        .ok()
        .and_then(|record| serde_json::from_str::<BTreeMap<String, String>>(&record).ok())
        .and_then(|record| record.get(&target.display().to_string()).cloned())
        .is_some_and(|recorded| recorded == digest(&text))
}

fn record(project_root: &Path, target: &Path, manifest: &str) -> Result<()> {
    let record = record_path(project_root);
    let mut recorded: BTreeMap<String, String> = std::fs::read_to_string(&record)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    recorded.insert(target.display().to_string(), digest(manifest));
    if let Some(parent) = record.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&record, serde_json::to_string_pretty(&recorded)?)?;
    Ok(())
}

/// The variables a step reads: where a script takes its network
/// (`${NETWORK:-arc-testnet}`), with the default it gives.
fn step_variables(step: &str) -> Vec<(String, Option<String>)> {
    let mut found: Vec<(String, Option<String>)> = Vec::new();
    for token in lex(step) {
        let Tok::Word(word) = token else { continue };
        for (name, default) in vars(&word) {
            let positional = name.chars().all(|ch| ch.is_ascii_digit());
            if !positional && !name.starts_with("npm_") && !found.iter().any(|(n, _)| *n == name) {
                found.push((name, default));
            }
        }
    }
    found
}

/// The project's bins and its workspaces', nearest first, as a package
/// manager puts them on PATH.
fn bin_path(dir: &Path) -> std::ffi::OsString {
    let mut dirs: Vec<PathBuf> = dir
        .ancestors()
        .map(|dir| dir.join("node_modules").join(".bin"))
        .collect();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    std::env::join_paths(dirs).unwrap_or_default()
}

/// The project's `codegen` script, which envio runs to build the generated
/// code anyway (§6a), when its steps before `graph codegen` are what write
/// the manifest (cope-market: `node scripts/build-manifest.mjs
/// ${NETWORK:-arc-testnet} && graph codegen`). They run first, with the
/// network picked in the variable they read it from.
fn run_codegen_prelude(
    project_root: &Path,
    target: &Path,
    dir: &Path,
    network: Option<&str>,
) -> Result<Option<Rendered>> {
    let graph_codegen =
        regex::Regex::new(r"^(?:(?:npx|pnpm exec|pnpm|yarn|bunx)\s+)?graph\s+codegen\b")
            .expect("a valid regex");
    let Some(script) = package_scripts(dir)
        .into_iter()
        .find(|(name, _)| name == "codegen")
        .map(|(_, script)| script)
    else {
        return Ok(None);
    };
    let steps: Vec<String> = script
        .split("&&")
        .map(|step| step.trim().to_string())
        .filter(|step| !step.is_empty())
        .collect();
    let Some(first_codegen) = steps.iter().position(|step| graph_codegen.is_match(step)) else {
        return Ok(None);
    };
    let prelude = &steps[..first_codegen];
    // beefy's `rm -Rf generated` writes no manifest; §6a runs it at codegen.
    let writes_nothing = |step: &String| {
        parse_steps(step).is_some_and(|parsed| {
            parsed
                .iter()
                .flat_map(|step| &step.stages)
                .all(|stage| classify(&stage.words) == Command::NoOp && stage.redirects.is_empty())
        })
    };
    if prelude.iter().all(writes_nothing) {
        return Ok(None);
    }
    let manifest_name = target
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut picked = network.map(str::to_string);
    for step in prelude {
        let variables = step_variables(step);
        let mut command = std::process::Command::new("sh");
        command
            .arg("-c")
            .arg(step)
            .current_dir(dir)
            .env("PATH", bin_path(dir));
        for (name, default) in &variables {
            match network {
                Some(network) => {
                    command.env(name, network);
                }
                None => {
                    if picked.is_none() && std::env::var_os(name).is_none() {
                        picked = default.clone();
                    }
                }
            }
        }
        let assigned: Vec<String> = match network {
            Some(network) => variables
                .iter()
                .map(|(name, _)| format!("{name}={network}"))
                .collect(),
            None => Vec::new(),
        };
        eprintln!(
            "Envio Subgraph is running `{step}`{} from the project's codegen script: there is no \
             {manifest_name}, and the script's steps before `graph codegen` write it.",
            if assigned.is_empty() {
                String::new()
            } else {
                format!(" with {}", assigned.join(" "))
            }
        );
        let status = command
            .status()
            .context(format!("Failed to run `{step}`"))?;
        if !status.success() {
            return Err(anyhow!(
                "There is no {manifest_name} here, and the project's codegen script writes it: \
                 envio ran `{step}` from it, and it exited with {} — the error above is the \
                 script's own.",
                status
                    .code()
                    .map(|code| code.to_string())
                    .unwrap_or_else(|| "a signal".to_string())
            ));
        }
    }
    // balancer-v2's steps write subgraph.<network>.yaml, and its codegen step
    // names the one it builds: `graph codegen subgraph.mainnet.yaml`.
    let named = steps[first_codegen]
        .split_whitespace()
        .skip_while(|word| *word != "codegen")
        .skip(1)
        .scan(false, |takes_value, word| {
            let value = std::mem::replace(
                takes_value,
                matches!(word, "-o" | "--output-dir" | "-u" | "--uncrashable-config"),
            );
            Some((value, word))
        })
        .find(|(value, word)| !value && (word.ends_with(".yaml") || word.ends_with(".yml")))
        .map(|(_, word)| absolute(&dir.join(word)));
    let written = [Some(target.to_path_buf()), named]
        .into_iter()
        .flatten()
        .find(|manifest| manifest.is_file());
    // Steps that wrote no manifest leave the error to what does write one.
    let Some(written) = written else {
        return Ok(None);
    };
    let manifest = std::fs::read_to_string(&written)?;
    record(project_root, &written, &manifest)?;
    Ok(Some(Rendered {
        manifest: written.clone(),
        script: "codegen".to_string(),
        inlined: Vec::new(),
        network: picked.unwrap_or_default(),
        template: String::new(),
        view: String::new(),
        files: vec![written],
        steps: prelude.to_vec(),
    }))
}

/// The network the repo's own build passes `graph build --network`, when its
/// scripts agree on one (`--network ${NETWORK_NAME:-arbitrum-sepolia}`, or a
/// literal): what graph-cli builds with when nothing else is set.
pub fn build_network_default(dirs: &[&Path]) -> Option<String> {
    let flag =
        regex::Regex::new(r#"--network(?:=|\s+)["']?(?:\$\{\w+:-([\w.-]+)\}|([A-Za-z][\w.-]*))"#)
            .expect("a valid regex");
    let mut seen: Vec<PathBuf> = Vec::new();
    let mut networks: BTreeSet<String> = BTreeSet::new();
    for dir in dirs {
        let dir = absolute(dir);
        if seen.contains(&dir) {
            continue;
        }
        seen.push(dir.clone());
        for (_, script) in package_scripts(&dir) {
            for captures in flag.captures_iter(&script) {
                if let Some(network) = captures.get(1).or_else(|| captures.get(2)) {
                    networks.insert(network.as_str().to_string());
                }
            }
        }
    }
    match networks.into_iter().collect::<Vec<_>>().as_slice() {
        [network] => Some(network.clone()),
        _ => None,
    }
}

/// The scripts a package runs: package.json's, then its Makefile's targets
/// (`make <target>`).
/// The networks file the repo's scripts pass graph-cli with `--network
/// <network>` (zkBob: `--network sepolia --network-file
/// ./networks-bob-sepolia.json`), when they pair the network with one file.
pub fn network_file_for(dirs: &[&Path], network: &str) -> Option<PathBuf> {
    let flag = |name: &str| {
        regex::Regex::new(&format!(
            r#"--{name}(?:=|\s+)["']?(?:\$\{{\w+:-([^}}"'\s]+)\}}|([^\s"'&;|]+))"#
        ))
        .expect("a valid regex")
    };
    let (network_flag, file_flag) = (flag("network"), flag("network-file"));
    let value = |captures: regex::Captures| {
        captures
            .get(1)
            .or_else(|| captures.get(2))
            .map(|value| value.as_str().to_string())
    };
    let mut files: BTreeSet<PathBuf> = BTreeSet::new();
    for dir in dirs {
        let dir = absolute(dir);
        for (_, script) in package_scripts(&dir) {
            for command in script.split("&&") {
                let file = file_flag.captures(command).and_then(value);
                let named = network_flag.captures(command).and_then(value);
                if let (Some(file), Some(named)) = (file, named) {
                    if named == network {
                        files.insert(normalize_path(dir.join(file)));
                    }
                }
            }
        }
    }
    match files.into_iter().collect::<Vec<_>>().as_slice() {
        [file] => Some(file.clone()),
        _ => None,
    }
}

fn package_scripts(dir: &Path) -> Vec<(String, String)> {
    let mut scripts: Vec<(String, String)> = std::fs::read_to_string(dir.join("package.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|json| json.get("scripts").and_then(Value::as_object).cloned())
        .map(|scripts| {
            scripts
                .into_iter()
                .filter_map(|(name, script)| Some((name, script.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default();
    if let Ok(makefile) = std::fs::read_to_string(dir.join("Makefile")) {
        scripts.extend(makefile_targets(&makefile));
    }
    scripts
}

/// A Makefile's targets as shell scripts: each recipe line chained with `&&`
/// (make stops at the first that fails), `$(var)` read as the shell variable
/// it is set as on make's command line, with the Makefile's own `var ?= x` as
/// its default. moonwell renders its manifest in `make generate-config`.
fn makefile_targets(makefile: &str) -> Vec<(String, String)> {
    let joined = makefile.replace("\\\n", " ");
    let assignment = regex::Regex::new(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(?:\?=|:=|=)\s*(.*)$")
        .expect("a valid regex");
    let rule =
        regex::Regex::new(r"^([A-Za-z0-9_][A-Za-z0-9_./-]*)\s*:([^=]|$)").expect("a valid regex");
    let mut defaults: BTreeMap<String, String> = BTreeMap::new();
    for line in joined.lines() {
        if let Some(captures) = assignment.captures(line) {
            let value = captures[2].trim().to_string();
            if !value.contains('$') {
                defaults.insert(captures[1].to_string(), value);
            }
        }
    }
    let reference =
        regex::Regex::new(r"\$[({]([A-Za-z_][A-Za-z0-9_]*)[)}]").expect("a valid regex");
    let to_shell = |line: &str| -> String {
        let line = line.replace("$$", "\u{0}");
        let line = reference.replace_all(&line, |captures: &regex::Captures| {
            match defaults.get(&captures[1]) {
                Some(value) => format!("${{{}:-{value}}}", &captures[1]),
                None => format!("${{{}}}", &captures[1]),
            }
        });
        line.replace('\u{0}', "$")
    };
    let mut targets: Vec<(String, String)> = Vec::new();
    let mut current: Option<(String, Vec<String>)> = None;
    for line in joined.lines() {
        if let Some(recipe) = line.strip_prefix('\t') {
            if let Some((_, lines)) = current.as_mut() {
                let recipe = recipe.trim_start_matches(['@', '-', '+']).trim();
                if !recipe.is_empty() {
                    lines.push(to_shell(recipe));
                }
            }
            continue;
        }
        if let Some((name, lines)) = current.take() {
            if !lines.is_empty() {
                targets.push((format!("make {name}"), lines.join(" && ")));
            }
        }
        if let Some(captures) = rule.captures(line) {
            if !captures[1].starts_with('.') {
                current = Some((captures[1].to_string(), Vec::new()));
            }
        }
    }
    if let Some((name, lines)) = current {
        if !lines.is_empty() {
            targets.push((format!("make {name}"), lines.join(" && ")));
        }
    }
    targets
}

fn absolute(path: &Path) -> PathBuf {
    normalize_path(std::env::current_dir().unwrap_or_default().join(path))
}

/// The package directories whose scripts may write `target`: its own, then
/// the packages above it up to the repository's root (a workspace root's
/// scripts render into its packages).
fn package_dirs(target: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for dir in target.ancestors().skip(1).take(4) {
        if dir.join("package.json").exists() {
            dirs.push(dir.to_path_buf());
        }
        if dir.join(".git").exists() {
            break;
        }
    }
    dirs
}

fn scan(target: &Path) -> (Vec<Plan>, Vec<Writer>) {
    let mut plans = Vec::new();
    let mut writers = Vec::new();
    let own = target.parent().map(Path::to_path_buf);
    for dir in package_dirs(target) {
        let label = |name: &str| match &own {
            Some(own) if *own != dir => format!(
                "{name}\" in \"{}",
                pathdiff::diff_paths(dir.join("package.json"), own)
                    .unwrap_or_default()
                    .display()
            ),
            _ => name.to_string(),
        };
        let mut found = Vec::new();
        let mut raw_writers: Vec<Writer> = Vec::new();
        let all = package_scripts(&dir);
        let scripts: BTreeMap<String, String> = all.iter().cloned().collect();
        for (name, script) in all {
            match analyze(&dir, &name, &script, target, &scripts) {
                Some(Ok(plan)) => {
                    // nftx's public repo gitignores the template its mustache
                    // scripts render: a ts-node script writes it first.
                    let view = plan.hole.is_none().then(|| literal(&plan.view)).flatten();
                    let absent = [Some(plan.template.clone()), view]
                        .into_iter()
                        .flatten()
                        .find(|file| {
                            file != "-" && !file.contains("${") && !dir.join(file).exists()
                        });
                    match absent {
                        Some(file) => raw_writers.push(Writer {
                            script: name,
                            step: format!(
                                "{script} ({file} isn't in the repo: another step writes it)"
                            ),
                            inlined: plan.inlined,
                        }),
                        None => found.push(plan),
                    }
                }
                Some(Err(writer)) => raw_writers.push(writer),
                None => {}
            }
        }
        // `publish-graph:gnosis` only runs `render-subgraph-config:gnosis`,
        // the script that writes the manifest: that one is named.
        let writer_names: Vec<String> = raw_writers.iter().map(|w| w.script.clone()).collect();
        writers.extend(
            raw_writers
                .into_iter()
                .filter(|writer| {
                    !writer
                        .inlined
                        .iter()
                        .any(|name| *name != writer.script && writer_names.contains(name))
                })
                .map(|writer| Writer {
                    script: label(&writer.script),
                    ..writer
                }),
        );
        // zora's `codegen` runs `yarn gen-yaml-config`, the script that
        // renders: the one that writes the manifest itself is the plan.
        let names: Vec<String> = found.iter().map(|plan| plan.script.clone()).collect();
        found.retain(|plan| {
            !plan
                .inlined
                .iter()
                .any(|name| *name != plan.script && names.contains(name))
        });
        plans.extend(found);
    }
    (plans, writers)
}

/// The package.json scripts in `dir` whose text, or a repo file they run,
/// mentions `needle` (`sync-abis` runs ./scripts/sync-abis.sh, which writes
/// `../abis/`). Read, never run.
pub fn scripts_mentioning(dir: &Path, needle: &str) -> Vec<(String, String)> {
    package_scripts(dir)
        .into_iter()
        .filter(|(_, script)| {
            script.contains(needle)
                || parse_steps(script)
                    .is_some_and(|steps| runs_a_file_mentioning(dir, &steps, &[needle]))
        })
        .collect()
}

/// The files a manifest needs that aren't there, written by a package.json
/// script of standard tools that writes them (FilOzone's `generate:schema`:
/// `cp ./schemas/schema.${VERSION:-v1}.graphql schema.graphql`), each with
/// its variables at their defaults. Only missing files are written.
pub fn write_missing_inputs(manifest_dir: &Path, manifest: &str) -> Result<()> {
    let Ok(yaml) = serde_yaml::from_str::<serde_yaml::Value>(manifest) else {
        return Ok(());
    };
    let mut files: Vec<String> = Vec::new();
    if let Some(schema) = yaml
        .get("schema")
        .and_then(|schema| schema.get("file"))
        .and_then(|file| file.as_str())
    {
        files.push(schema.to_string());
    }
    for key in ["dataSources", "templates"] {
        for source in yaml
            .get(key)
            .and_then(|list| list.as_sequence())
            .into_iter()
            .flatten()
        {
            let Some(mapping) = source.get("mapping") else {
                continue;
            };
            if let Some(file) = mapping.get("file").and_then(|file| file.as_str()) {
                files.push(file.to_string());
            }
            for abi in mapping
                .get("abis")
                .and_then(|abis| abis.as_sequence())
                .into_iter()
                .flatten()
            {
                if let Some(file) = abi.get("file").and_then(|file| file.as_str()) {
                    files.push(file.to_string());
                }
            }
        }
    }
    let dir = absolute(manifest_dir);
    for file in files {
        let target = normalize_path(dir.join(&file));
        if target.exists() {
            continue;
        }
        let (plans, _) = scan(&target);
        let Ok(choice) = choose(&plans, None) else {
            continue;
        };
        let mut run = Run {
            dir: &choice.plan.dir,
            cwd: choice.plan.dir.to_path_buf(),
            target: &target,
            hole: None,
            files: BTreeMap::new(),
        };
        let hole_name = choice.plan.hole.as_ref().map(|(name, _, _)| name.clone());
        if let (Some(name), Some(value)) = (hole_name.as_deref(), choice.hole_value.as_deref()) {
            run.hole = Some((name, value));
        }
        if run.steps(&choice.plan.steps).is_err() {
            continue;
        }
        for (path, text) in &run.files {
            if path.exists() {
                continue;
            }
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(path, text).context(format!("Failed to write {}", path.display()))?;
        }
    }
    Ok(())
}

/// Whether `path` is a mustache template rather than a manifest.
pub fn is_template(path: &Path) -> bool {
    std::fs::read_to_string(path).is_ok_and(|text| text.contains("{{"))
}

/// The manifest a script beside `template` renders from it, when `--config`
/// names the template rather than the manifest.
pub fn template_output(template: &Path) -> Option<PathBuf> {
    let template = absolute(template);
    let dir = template.parent()?.to_path_buf();
    let mut outputs: Vec<PathBuf> = Vec::new();
    for (_, script) in package_scripts(&dir) {
        for step in parse_steps(&script).unwrap_or_default() {
            for stage in &step.stages {
                let mut words: Vec<&Word> = stage.redirects.iter().map(|(_, word)| word).collect();
                if let Command::Mustache {
                    output: Some(output),
                    ..
                } = classify(&stage.words)
                {
                    outputs.push(normalize_path(
                        dir.join(literal(&output).unwrap_or_default()),
                    ));
                }
                words.retain(|word| {
                    literal(word)
                        .is_some_and(|text| text.ends_with(".yaml") || text.ends_with(".yml"))
                });
                outputs.extend(
                    words
                        .iter()
                        .filter_map(|word| literal(word))
                        .map(|text| normalize_path(dir.join(text))),
                );
            }
        }
    }
    outputs.sort();
    outputs.dedup();
    outputs
        .into_iter()
        .filter(|output| *output != template)
        .find(|output| {
            scan(output)
                .0
                .iter()
                .any(|plan| normalize_path(plan.dir.join(&plan.template)) == template)
        })
}

/// For "the manifest is missing": the package.json scripts beside it that
/// write it, or may, with a step envio doesn't run — and why the user has to.
pub fn unrepeatable_writers(target: &Path) -> Option<String> {
    let target = absolute(target);
    let manifest_name = target.file_name()?.to_string_lossy().to_string();
    let (_, writers) = scan(&target);
    if writers.is_empty() {
        return None;
    }
    let lines: Vec<String> = writers
        .iter()
        .map(|writer| format!("  \"{}\": {}", writer.script, writer.step))
        .collect();
    Some(format!(
        "The project writes its manifest with a package.json script, and envio can't repeat \
         {}:\n{}\n\
         envio renders a manifest itself only when every step of the script is a standard \
         tool over files in the repo (`mustache <config> <template> > {manifest_name}`, \
         `yaml2json`, `cat`), so that the network you pick is its only input. Run the script \
         for your network, then start envio again.",
        if writers.len() == 1 { "it" } else { "these" },
        lines.join("\n")
    ))
}

/// The rest of a render whose manifest is already there: when one network's
/// render writes exactly the manifest at `target` (committed, or written by an
/// earlier run of the script), the files it writes beside it that are missing
/// (matic's gitignored `src/network.ts`) are written. Nothing that exists is
/// touched, and an unproven network writes nothing.
/// Whether a render is the manifest there: the same YAML, however another
/// renderer laid it out (the corpus harness' keeps mustache's standalone
/// lines).
fn same_manifest(rendered: &str, existing: &str) -> bool {
    rendered == existing
        || matches!(
            (
                serde_yaml::from_str::<serde_yaml::Value>(rendered),
                serde_yaml::from_str::<serde_yaml::Value>(existing),
            ),
            (Ok(a), Ok(b)) if a == b
        )
}

fn write_missing_companions(target: &Path) -> Result<()> {
    let Ok(existing) = std::fs::read_to_string(target) else {
        return Ok(());
    };
    let (plans, _) = scan(target);
    for (_, choice) in options(&plans) {
        let mut run = Run {
            dir: &choice.plan.dir,
            cwd: choice.plan.dir.to_path_buf(),
            target,
            hole: None,
            files: BTreeMap::new(),
        };
        let hole_name = choice.plan.hole.as_ref().map(|(name, _, _)| name.clone());
        if let (Some(name), Some(value)) = (hole_name.as_deref(), choice.hole_value.as_deref()) {
            run.hole = Some((name, value));
        }
        let proven = run.steps(&choice.plan.steps).is_ok()
            && run
                .files
                .get(target)
                .is_some_and(|rendered| same_manifest(rendered, &existing));
        if !proven {
            continue;
        }
        if choice.hole_value.is_none() {
            for (_, steps) in sibling_renders(choice.plan, &choice.network, target) {
                let before = run.files.clone();
                if run.steps(&steps).is_err() {
                    run.files = before;
                }
            }
        }
        for (path, text) in &run.files {
            if path.as_path() == target || path.exists() {
                continue;
            }
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(path, text).context(format!("Failed to write {}", path.display()))?;
        }
        return Ok(());
    }
    Ok(())
}

/// Writes the manifest at `target` (and whatever else its script writes) when
/// it is missing, or is one envio rendered before, and a package.json script
/// beside it renders it in a way envio can repeat. `Ok(None)`: nothing to
/// render, the manifest is read as it is (or reported missing).
pub fn render_manifest(
    project_root: &Path,
    target: &Path,
    network: Option<&str>,
) -> Result<Option<Rendered>> {
    let target = absolute(target);
    if target.exists() && !rendered_by_envio(project_root, &target) {
        write_missing_companions(&target)?;
        return Ok(None);
    }
    let Some(dir) = target.parent().map(Path::to_path_buf) else {
        return Ok(None);
    };
    let manifest_name = target
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_default();

    let (plans, _) = scan(&target);
    if plans.is_empty() {
        return run_codegen_prelude(project_root, &target, &dir, network);
    }

    let choice = choose(&plans, network)
        .or_else(|names| {
            network
                .and_then(|network| choose_by_indexed_network(&plans, network, &target))
                .ok_or(names)
        })
        .map_err(|networks| {
            let scripts: Vec<String> = plans.iter().map(|plan| plan.script.clone()).collect();
            let first = networks.first().cloned().unwrap_or_default();
            match network {
                Some(network) => anyhow!(
                    "{} names the network '{network}', but the package.json scripts that render \
                 {manifest_name} ({}) render it for: {}.",
                    super::NETWORK_ENV_VAR,
                    scripts.join(", "),
                    networks.join(", ")
                ),
                None => anyhow!(
                    "There is no {manifest_name} here: the package.json scripts {} render it from \
                 {} for one network at a time ({}). Pick the network, as the script's \
                 argument does:\n  {}={first}",
                    scripts.join(", "),
                    plans[0].template,
                    networks.join(", "),
                    super::NETWORK_ENV_VAR,
                ),
            }
        })?;

    let mut run = Run {
        dir: &choice.plan.dir,
        cwd: choice.plan.dir.to_path_buf(),
        target: &target,
        hole: None,
        files: BTreeMap::new(),
    };
    let hole_name = choice.plan.hole.as_ref().map(|(name, _, _)| name.clone());
    if let (Some(name), Some(value)) = (hole_name.as_deref(), choice.hole_value.as_deref()) {
        run.hole = Some((name, value));
    }
    run.steps(&choice.plan.steps).map_err(|err| {
        anyhow!(
            "Envio Subgraph rendered {manifest_name} as the package.json script \"{}\" does, \
             and it failed: {err:#}",
            choice.plan.script
        )
    })?;
    let mut inlined = choice.plan.inlined.clone();
    if choice.hole_value.is_none() {
        for (name, steps) in sibling_renders(choice.plan, &choice.network, &target) {
            // A sibling that can't render (its template isn't there) is the
            // user's to run; the manifest is rendered either way.
            let before = run.files.clone();
            if run.steps(&steps).is_ok() {
                inlined.push(name);
            } else {
                run.files = before;
            }
        }
    }
    let Some(manifest) = run.files.get(&target).cloned() else {
        return Ok(None);
    };
    for (path, text) in &run.files {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, text).context(format!("Failed to write {}", path.display()))?;
    }
    record(project_root, &target, &manifest)?;

    Ok(Some(Rendered {
        manifest: target.clone(),
        script: choice.plan.script.clone(),
        inlined,
        network: choice.network.clone(),
        template: choice.plan.template.clone(),
        view: choice.view.clone(),
        files: run.files.keys().cloned().collect(),
        steps: Vec::new(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn script_steps(script: &str) -> Vec<Vec<Command>> {
        parse_steps(script)
            .unwrap()
            .iter()
            .map(|step| {
                step.stages
                    .iter()
                    .map(|stage| classify(&stage.words))
                    .collect()
            })
            .collect()
    }

    #[test]
    fn reads_the_commands_of_a_render_script() {
        let lit = |text: &str| vec![Part::Lit(text.to_string())];
        let network = vec![
            Part::Lit("config/".to_string()),
            Part::Var {
                name: "NETWORK".to_string(),
                default: Some("zora-testnet".to_string()),
            },
            Part::Lit(".yaml".to_string()),
        ];
        assert_eq!(
            script_steps(
                "cat template_warning.md > subgraph.yaml && yaml2json config/${NETWORK:-zora-testnet}.yaml | npx mustache - subgraph.template.yaml >> subgraph.yaml && graph codegen 2>&1"
            ),
            vec![
                vec![Command::Cat(vec![lit("template_warning.md")])],
                vec![
                    Command::Yaml2Json(network),
                    Command::Mustache {
                        view: lit("-"),
                        template: lit("subgraph.template.yaml"),
                        output: None
                    }
                ],
                vec![Command::Graph],
            ]
        );
        assert_eq!(
            script_steps("cross-env mustache 'config/mainnet/config.json' subgraph.template.yaml out.yaml; node build.js"),
            vec![
                vec![Command::Mustache {
                    view: lit("config/mainnet/config.json"),
                    template: lit("subgraph.template.yaml"),
                    output: Some(lit("out.yaml"))
                }],
                vec![Command::Other("node build.js".to_string())],
            ]
        );
    }
}
