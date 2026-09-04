//! Minimal `.env` loader, ported from the unreleased `dotenvy` 0.16 rewrite
//! (github.com/enviodev/dotenvy @ e2da110). We only need to parse a file into a
//! map without touching the process environment, so the builder, the
//! environment-merging sequences, the `unsafe` env-modifying loaders, and the
//! CLI/macros are all dropped. Vendored to avoid fetching the crate over a git
//! dependency at build time. Original code is MIT-licensed, © the dotenvy
//! authors.

use std::{
    collections::HashMap,
    error, fmt,
    fs::File,
    io::{self, BufRead, BufReader},
    ops::{Deref, DerefMut},
    path::{Path, PathBuf},
};

/// A map of environment variables parsed from a `.env` file.
#[derive(Default, Clone, Debug)]
pub struct EnvMap(HashMap<String, String>);

impl Deref for EnvMap {
    type Target = HashMap<String, String>;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl DerefMut for EnvMap {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl EnvMap {
    #[must_use]
    pub fn new() -> Self {
        Self(HashMap::new())
    }

    pub fn var(&self, key: &str) -> Result<String, Error> {
        self.get(key)
            .cloned()
            .ok_or_else(|| Error::NotPresent(key.to_owned()))
    }
}

#[derive(Debug)]
pub enum Error {
    LineParse(String, usize),
    /// An IO error encountered when opening or reading the file.
    Io(io::Error, Option<PathBuf>),
    /// The variable was not found in the map. The `String` is its name.
    NotPresent(String),
}

impl error::Error for Error {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            Self::Io(e, _) => Some(e),
            Self::LineParse(_, _) | Self::NotPresent(_) => None,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Self::Io(e, path) => match path {
                Some(path) => write!(f, "error reading '{}': {e}", path.to_string_lossy()),
                None => e.fmt(f),
            },
            Self::LineParse(line, index) => write!(
                f,
                "error parsing line: '{line}', error at line index: {index}",
            ),
            Self::NotPresent(s) => write!(f, "{s} is not set"),
        }
    }
}

impl From<(ParseBufError, Option<PathBuf>)> for Error {
    fn from((e, path): (ParseBufError, Option<PathBuf>)) -> Self {
        match e {
            ParseBufError::LineParse(line, index) => Self::LineParse(line, index),
            ParseBufError::Io(e) => Self::Io(e, path),
        }
    }
}

/// Parses the `.env` file at `path` into an [`EnvMap`].
///
/// Only the file is read; the process environment is neither inherited into the
/// result nor modified (equivalent to dotenvy's `EnvSequence::InputOnly`).
/// `$VAR` / `${VAR}` substitutions still resolve against the process
/// environment and earlier entries in the same file.
pub fn from_path(path: impl AsRef<Path>) -> Result<EnvMap, Error> {
    let path = path.as_ref();
    let file = File::open(path).map_err(|e| Error::Io(e, Some(path.to_owned())))?;
    Iter::new(BufReader::new(file))
        .load()
        .map_err(|e| (e, Some(path.to_owned())).into())
}

struct Iter<B> {
    lines: Lines<B>,
    substitution_data: HashMap<String, Option<String>>,
}

impl<B: BufRead> Iter<B> {
    fn new(buf: B) -> Self {
        Self {
            lines: Lines(buf),
            substitution_data: HashMap::new(),
        }
    }

    fn load(mut self) -> Result<EnvMap, ParseBufError> {
        self.remove_bom()?;
        let mut map = EnvMap::new();
        for item in self {
            let (k, v) = item?;
            map.insert(k, v);
        }
        Ok(map)
    }

    /// Removes the BOM if it exists.
    ///
    /// For more info, see the [Unicode BOM character](https://www.compart.com/en/unicode/U+FEFF).
    fn remove_bom(&mut self) -> io::Result<()> {
        let buf = self.lines.0.fill_buf()?;
        if buf.starts_with(&[0xEF, 0xBB, 0xBF]) {
            self.lines.0.consume(3);
        }
        Ok(())
    }
}

struct Lines<B>(B);

enum ParseState {
    Complete,
    Escape,
    StrongOpen,
    StrongOpenEscape,
    WeakOpen,
    WeakOpenEscape,
    Comment,
    WhiteSpace,
}

impl ParseState {
    fn eval_end(self, buf: &str) -> (usize, Self) {
        let mut cur_state = self;
        let mut cur_pos = 0;

        for (pos, c) in buf.char_indices() {
            cur_pos = pos;
            cur_state = match cur_state {
                Self::WhiteSpace => match c {
                    '#' => return (cur_pos, Self::Comment),
                    '\\' => Self::Escape,
                    '"' => Self::WeakOpen,
                    '\'' => Self::StrongOpen,
                    _ => Self::Complete,
                },
                Self::Escape => Self::Complete,
                Self::Complete => match c {
                    c if c.is_whitespace() && c != '\n' && c != '\r' => Self::WhiteSpace,
                    '\\' => Self::Escape,
                    '"' => Self::WeakOpen,
                    '\'' => Self::StrongOpen,
                    _ => Self::Complete,
                },
                Self::WeakOpen => match c {
                    '\\' => Self::WeakOpenEscape,
                    '"' => Self::Complete,
                    _ => Self::WeakOpen,
                },
                Self::WeakOpenEscape => Self::WeakOpen,
                Self::StrongOpen => match c {
                    '\\' => Self::StrongOpenEscape,
                    '\'' => Self::Complete,
                    _ => Self::StrongOpen,
                },
                Self::StrongOpenEscape => Self::StrongOpen,
                // Comments last the entire line.
                Self::Comment => unreachable!("should have returned already"),
            };
        }
        (cur_pos, cur_state)
    }
}

impl<B: BufRead> Iterator for Lines<B> {
    type Item = Result<String, ParseBufError>;

    fn next(&mut self) -> Option<Self::Item> {
        let mut buf = String::new();
        let mut cur_state = ParseState::Complete;
        let mut buf_pos;
        let mut cur_pos;
        loop {
            buf_pos = buf.len();
            match self.0.read_line(&mut buf) {
                Ok(0) => {
                    if matches!(cur_state, ParseState::Complete) {
                        return None;
                    }
                    let len = buf.len();
                    return Some(Err(ParseBufError::LineParse(buf, len)));
                }
                Ok(_n) => {
                    // Skip lines which start with a `#` before iteration
                    // This optimizes parsing a bit.
                    if buf.trim_start().starts_with('#') {
                        return Some(Ok(String::with_capacity(0)));
                    }
                    let result = cur_state.eval_end(&buf[buf_pos..]);
                    cur_pos = result.0;
                    cur_state = result.1;

                    match cur_state {
                        ParseState::Complete => {
                            if buf.ends_with('\n') {
                                buf.pop();
                                if buf.ends_with('\r') {
                                    buf.pop();
                                }
                            }
                            return Some(Ok(buf));
                        }
                        ParseState::Escape
                        | ParseState::StrongOpen
                        | ParseState::StrongOpenEscape
                        | ParseState::WeakOpen
                        | ParseState::WeakOpenEscape
                        | ParseState::WhiteSpace => {}
                        ParseState::Comment => {
                            buf.truncate(buf_pos + cur_pos);
                            return Some(Ok(buf));
                        }
                    }
                }
                Err(e) => return Some(Err(ParseBufError::Io(e))),
            }
        }
    }
}

impl<B: BufRead> Iterator for Iter<B> {
    type Item = Result<(String, String), ParseBufError>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            let line = match self.lines.next() {
                Some(Ok(line)) => line,
                Some(Err(e)) => return Some(Err(e)),
                None => return None,
            };

            match parse_line(&line, &mut self.substitution_data) {
                Ok(Some(res)) => return Some(Ok(res)),
                Ok(None) => {}
                Err(e) => return Some(Err(e)),
            }
        }
    }
}

/// An internal error type so IO errors can be handled without knowing the path.
#[derive(Debug)]
enum ParseBufError {
    LineParse(String, usize),
    Io(io::Error),
}

impl From<io::Error> for ParseBufError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

fn parse_line(
    line: &str,
    substitution_data: &mut HashMap<String, Option<String>>,
) -> Result<Option<(String, String)>, ParseBufError> {
    let mut parser = LineParser::new(line, substitution_data);
    parser.parse_line()
}

struct LineParser<'a> {
    original_line: &'a str,
    substitution_data: &'a mut HashMap<String, Option<String>>,
    line: &'a str,
    pos: usize,
}

impl<'a> LineParser<'a> {
    fn new(line: &'a str, substitution_data: &'a mut HashMap<String, Option<String>>) -> Self {
        LineParser {
            original_line: line,
            substitution_data,
            line: line.trim_end(), // we don’t want trailing whitespace
            pos: 0,
        }
    }

    fn err(&self) -> ParseBufError {
        ParseBufError::LineParse(self.original_line.into(), self.pos)
    }

    fn parse_line(&mut self) -> Result<Option<(String, String)>, ParseBufError> {
        self.skip_whitespace();
        // if its an empty line or a comment, skip it
        if self.line.is_empty() || self.line.starts_with('#') {
            return Ok(None);
        }

        let mut key = self.parse_key()?;
        self.skip_whitespace();

        // export can be either an optional prefix or a key itself
        if key == "export" {
            // here we check for an optional `=`, below we throw directly when it’s not found.
            if self.expect_equal().is_err() {
                key = self.parse_key()?;
                self.skip_whitespace();
                self.expect_equal()?;
            }
        } else {
            self.expect_equal()?;
        }
        self.skip_whitespace();

        if self.line.is_empty() || self.line.starts_with('#') {
            self.substitution_data.insert(key.clone(), None);
            return Ok(Some((key, String::new())));
        }

        let parsed_value = parse_value(self.line, self.substitution_data)?;
        self.substitution_data
            .insert(key.clone(), Some(parsed_value.clone()));

        Ok(Some((key, parsed_value)))
    }

    fn parse_key(&mut self) -> Result<String, ParseBufError> {
        if !self
            .line
            .starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        {
            return Err(self.err());
        }
        let index = match self
            .line
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '.'))
        {
            Some(index) => index,
            None => self.line.len(),
        };
        self.pos += index;
        let key = String::from(&self.line[..index]);
        self.line = &self.line[index..];
        Ok(key)
    }

    fn expect_equal(&mut self) -> Result<(), ParseBufError> {
        if !self.line.starts_with('=') {
            return Err(self.err());
        }
        self.line = &self.line[1..];
        self.pos += 1;
        Ok(())
    }

    fn skip_whitespace(&mut self) {
        if let Some(index) = self.line.find(|c: char| !c.is_whitespace()) {
            self.pos += index;
            self.line = &self.line[index..];
        } else {
            self.pos += self.line.len();
            self.line = "";
        }
    }
}

#[derive(Eq, PartialEq)]
enum SubstitutionMode {
    None,
    Block,
    EscapedBlock,
}

fn parse_value(
    input: &str,
    substitution_data: &HashMap<String, Option<String>>,
) -> Result<String, ParseBufError> {
    let mut strong_quote = false; // '
    let mut weak_quote = false; // "
    let mut escaped = false;
    let mut expecting_end = false;

    //FIXME can this be done without yet another allocation per line?
    let mut output = String::new();

    let mut substitution_mode = SubstitutionMode::None;
    let mut substitution_name = String::new();

    for (index, c) in input.chars().enumerate() {
        //the regex _should_ already trim whitespace off the end
        //expecting_end is meant to permit: k=v #comment
        //without affecting: k=v#comment
        //and throwing on: k=v w
        if expecting_end {
            if c == ' ' || c == '\t' {
                continue;
            } else if c == '#' {
                break;
            }
            return Err(ParseBufError::LineParse(input.to_owned(), index));
        } else if escaped {
            //TODO I tried handling literal \r but various issues
            //imo not worth worrying about until there's a use case
            //(actually handling backslash 0x10 would be a whole other matter)
            //then there's \v \f bell hex... etc
            match c {
                '\\' | '\'' | '"' | '$' | ' ' => output.push(c),
                'n' => output.push('\n'), // handle \n case
                _ => {
                    return Err(ParseBufError::LineParse(input.to_owned(), index));
                }
            }

            escaped = false;
        } else if strong_quote {
            if c == '\'' {
                strong_quote = false;
            } else {
                output.push(c);
            }
        } else if substitution_mode != SubstitutionMode::None {
            if c.is_alphanumeric() {
                substitution_name.push(c);
            } else {
                match substitution_mode {
                    SubstitutionMode::None => unreachable!(),
                    SubstitutionMode::Block => {
                        if c == '{' && substitution_name.is_empty() {
                            substitution_mode = SubstitutionMode::EscapedBlock;
                        } else {
                            apply_substitution(
                                substitution_data,
                                &std::mem::take(&mut substitution_name),
                                &mut output,
                            );
                            if c == '$' {
                                substitution_mode = if !strong_quote && !escaped {
                                    SubstitutionMode::Block
                                } else {
                                    SubstitutionMode::None
                                }
                            } else {
                                substitution_mode = SubstitutionMode::None;
                                output.push(c);
                            }
                        }
                    }
                    SubstitutionMode::EscapedBlock => {
                        if c == '}' {
                            substitution_mode = SubstitutionMode::None;
                            apply_substitution(
                                substitution_data,
                                &std::mem::take(&mut substitution_name),
                                &mut output,
                            );
                        } else {
                            substitution_name.push(c);
                        }
                    }
                }
            }
        } else if c == '$' {
            substitution_mode = if !strong_quote && !escaped {
                SubstitutionMode::Block
            } else {
                SubstitutionMode::None
            }
        } else if weak_quote {
            if c == '"' {
                weak_quote = false;
            } else if c == '\\' {
                escaped = true;
            } else {
                output.push(c);
            }
        } else if c == '\'' {
            strong_quote = true;
        } else if c == '"' {
            weak_quote = true;
        } else if c == '\\' {
            escaped = true;
        } else if c == ' ' || c == '\t' {
            expecting_end = true;
        } else {
            output.push(c);
        }
    }

    //XXX also fail if escaped? or...
    if substitution_mode == SubstitutionMode::EscapedBlock || strong_quote || weak_quote {
        let value_length = input.len();
        Err(ParseBufError::LineParse(
            input.to_owned(),
            if value_length == 0 {
                0
            } else {
                value_length - 1
            },
        ))
    } else {
        apply_substitution(
            substitution_data,
            &std::mem::take(&mut substitution_name),
            &mut output,
        );
        Ok(output)
    }
}

fn apply_substitution(
    substitution_data: &HashMap<String, Option<String>>,
    substitution_name: &str,
    output: &mut String,
) {
    if let Ok(environment_value) = std::env::var(substitution_name) {
        output.push_str(&environment_value);
    } else {
        let stored_value = substitution_data
            .get(substitution_name)
            .unwrap_or(&None)
            .to_owned();
        output.push_str(&stored_value.unwrap_or_default());
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// Asserts each parsed `key=value` pair matches `expected`, in order.
    fn assert_str(actual: &str, expected: Vec<(&str, &str)>) -> Result<(), ParseBufError> {
        let actual_iter = Iter::new(actual.as_bytes());
        let expected_count = expected.len();

        let expected_iter = expected
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v.to_owned()));

        let mut count = 0;
        for (expected, actual) in expected_iter.zip(actual_iter) {
            assert_eq!(actual?, expected);
            count += 1;
        }
        assert_eq!(count, expected_count);
        Ok(())
    }

    #[test]
    fn from_path_missing_file_is_io_error() {
        assert!(matches!(
            from_path("/this/path/does/not/exist/.env"),
            Err(Error::Io(_, _))
        ));
    }

    #[test]
    fn from_path_loads_and_looks_up_vars() {
        let dir = tempdir::TempDir::new("envio_dotenv_test").unwrap();
        let path = dir.path().join(".env");
        std::fs::write(&path, "FOO=bar\nBAZ=\"qu ux\"\n").unwrap();

        let env_map = from_path(&path).unwrap();
        assert_eq!(
            (
                env_map.var("FOO").ok(),
                env_map.var("BAZ").ok(),
                env_map.var("MISSING").ok(),
            ),
            (Some("bar".to_owned()), Some("qu ux".to_owned()), None)
        );
    }

    #[test]
    fn test_remove_bom() {
        let b = b"\xEF\xBB\xBFkey=value\n";
        let mut iter = Iter::new(BufReader::new(Cursor::new(b)));
        iter.remove_bom().unwrap();
        let first_line = iter.lines.next().unwrap().unwrap();
        assert_eq!(first_line, "key=value");
    }

    #[test]
    fn test_remove_bom_no_bom() {
        let b = b"key=value\n";
        let mut iter = Iter::new(BufReader::new(Cursor::new(b)));
        iter.remove_bom().unwrap();
        let first_line = iter.lines.next().unwrap().unwrap();
        assert_eq!(first_line, "key=value");
    }

    #[test]
    fn test_parse_line_env() -> Result<(), ParseBufError> {
        // Note 5 spaces after 'KEY8=' below
        let actual_iter = Iter::new(
            r#"
KEY=1
KEY2="2"
KEY3='3'
KEY4='fo ur'
KEY5="fi ve"
KEY6=s\ ix
KEY7=
KEY8=
KEY9=   # foo
KEY10  ="whitespace before ="
KEY11=    "whitespace after ="
export="export as key"
export   SHELL_LOVER=1
"#
            .as_bytes(),
        );

        let expected_iter = vec![
            ("KEY", "1"),
            ("KEY2", "2"),
            ("KEY3", "3"),
            ("KEY4", "fo ur"),
            ("KEY5", "fi ve"),
            ("KEY6", "s ix"),
            ("KEY7", ""),
            ("KEY8", ""),
            ("KEY9", ""),
            ("KEY10", "whitespace before ="),
            ("KEY11", "whitespace after ="),
            ("export", "export as key"),
            ("SHELL_LOVER", "1"),
        ]
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value.to_owned()));

        let mut count = 0;
        for (expected, actual) in expected_iter.zip(actual_iter) {
            assert_eq!(expected, actual?);
            count += 1;
        }
        assert_eq!(count, 13);
        Ok(())
    }

    #[test]
    fn test_parse_line_comment() {
        let input = br"
# foo=bar
#    ";
        let result: Result<Vec<(String, String)>, ParseBufError> = Iter::new(&input[..]).collect();
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn test_parse_line_invalid() {
        // Note 4 spaces after 'invalid' below
        let actual_iter = Iter::new(
            r"
  invalid
very bacon = yes indeed
=value"
                .as_bytes(),
        );

        let mut count = 0;
        for actual in actual_iter {
            assert!(actual.is_err());
            count += 1;
        }
        assert_eq!(count, 3);
    }

    #[test]
    fn test_parse_value_escapes() -> Result<(), ParseBufError> {
        let actual_iter = Iter::new(
            r#"
KEY=my\ cool\ value
KEY2=\$sweet
KEY3="awesome stuff \"mang\""
KEY4='sweet $\fgs'\''fds'
KEY5="'\"yay\\"\ "stuff"
KEY6="lol" #well you see when I say lol wh
KEY7="line 1\nline 2"
"#
            .as_bytes(),
        );

        let vec = vec![
            ("KEY", r"my cool value"),
            ("KEY2", r"$sweet"),
            ("KEY3", r#"awesome stuff "mang""#),
            ("KEY4", r"sweet $\fgs'fds"),
            ("KEY5", r#"'"yay\ stuff"#),
            ("KEY6", "lol"),
            ("KEY7", "line 1\nline 2"),
        ];
        let expected_iter = vec
            .into_iter()
            .map(|(key, value)| (key.to_string(), value.to_string()));

        for (expected, actual) in expected_iter.zip(actual_iter) {
            assert_eq!(expected, actual?);
        }
        Ok(())
    }

    #[test]
    fn test_parse_value_escapes_invalid() {
        let actual_iter = Iter::new(
            r#"
KEY=my uncool value
KEY2="why
KEY3='please stop''
KEY4=h\8u
"#
            .as_bytes(),
        );

        for actual in actual_iter {
            assert!(actual.is_err());
        }
    }

    #[test]
    fn variable_in_parenthesis_surrounded_by_quotes() -> Result<(), ParseBufError> {
        assert_str(
            r#"
            KEY=test
            KEY1="${KEY}"
            "#,
            vec![("KEY", "test"), ("KEY1", "test")],
        )
    }

    #[test]
    fn sub_undefined_variables_to_empty_string() -> Result<(), ParseBufError> {
        assert_str(r#"KEY=">$KEY1<>${KEY2}<""#, vec![("KEY", "><><")])
    }

    #[test]
    fn do_not_sub_with_dollar_escaped() -> Result<(), ParseBufError> {
        assert_str(
            "KEY=>\\$KEY1<>\\${KEY2}<",
            vec![("KEY", ">$KEY1<>${KEY2}<")],
        )
    }

    #[test]
    fn do_not_sub_in_weak_quotes_with_dollar_escaped() -> Result<(), ParseBufError> {
        assert_str(
            r#"KEY=">\$KEY1<>\${KEY2}<""#,
            vec![("KEY", ">$KEY1<>${KEY2}<")],
        )
    }

    #[test]
    fn do_not_sub_in_strong_quotes() -> Result<(), ParseBufError> {
        assert_str("KEY='>${KEY1}<>$KEY2<'", vec![("KEY", ">${KEY1}<>$KEY2<")])
    }

    #[test]
    fn same_variable_reused() -> Result<(), ParseBufError> {
        assert_str(
            r"
    KEY=VALUE
    KEY1=$KEY$KEY
    ",
            vec![("KEY", "VALUE"), ("KEY1", "VALUEVALUE")],
        )
    }

    #[test]
    fn with_dot() -> Result<(), ParseBufError> {
        assert_str(
            r"
    KEY.Value=VALUE
    ",
            vec![("KEY.Value", "VALUE")],
        )
    }

    #[test]
    fn recursive_substitution() -> Result<(), ParseBufError> {
        assert_str(
            r"
            KEY=${KEY1}+KEY_VALUE
            KEY1=${KEY}+KEY1_VALUE
            ",
            vec![("KEY", "+KEY_VALUE"), ("KEY1", "+KEY_VALUE+KEY1_VALUE")],
        )
    }

    #[test]
    fn var_without_paranthesis_subbed_before_separators() -> Result<(), ParseBufError> {
        assert_str(
            r#"
            KEY1=test_user
            KEY1_1=test_user_with_separator
            KEY=">$KEY1_1<>$KEY1}<>$KEY1{<"
            "#,
            vec![
                ("KEY1", "test_user"),
                ("KEY1_1", "test_user_with_separator"),
                ("KEY", ">test_user_1<>test_user}<>test_user{<"),
            ],
        )
    }

    #[test]
    fn consequent_substitutions() -> Result<(), ParseBufError> {
        assert_str(
            r"
    KEY1=test_user
    KEY2=$KEY1_2
    KEY=>${KEY1}<>${KEY2}<
    ",
            vec![
                ("KEY1", "test_user"),
                ("KEY2", "test_user_2"),
                ("KEY", ">test_user<>test_user_2<"),
            ],
        )
    }

    #[test]
    fn consequent_substitutions_with_one_missing() -> Result<(), ParseBufError> {
        assert_str(
            r"
    KEY2=$KEY1_2
    KEY=>${KEY1}<>${KEY2}<
    ",
            vec![("KEY2", "_2"), ("KEY", "><>_2<")],
        )
    }

    #[test]
    fn should_not_parse_unfinished_subs() {
        let invalid_value = ">${baz{<";

        let iter = Iter::new(
            format!(
                r#"
    FOO=bar
    BAR={invalid_value}
    "#
            )
            .as_bytes(),
        )
        .collect::<Vec<_>>();

        // first line works
        assert_eq!(
            iter[0].as_ref().unwrap(),
            &("FOO".to_owned(), "bar".to_owned())
        );
        // second line error
        assert!(matches!(
            iter[1],
            Err(ParseBufError::LineParse(ref v, idx)) if v == invalid_value && idx == invalid_value.len() - 1
        ));
    }

    #[test]
    fn should_not_allow_dot_as_first_char_of_key() {
        let invalid_key = ".KEY=value";

        let iter = Iter::new(invalid_key.as_bytes()).collect::<Vec<_>>();

        assert!(matches!(
            iter[0],
            Err(ParseBufError::LineParse(ref v, idx)) if v == invalid_key && idx == 0
        ));
    }

    #[test]
    fn should_not_parse_invalid_format() {
        let invalid_fmt = r"<><><>";
        let iter = Iter::new(invalid_fmt.as_bytes()).collect::<Vec<_>>();

        assert!(matches!(
            iter[0],
            Err(ParseBufError::LineParse(ref v, idx)) if v == invalid_fmt && idx == 0
        ));
    }

    #[test]
    fn should_not_parse_invalid_escape() {
        let invalid_esc = r">\f<";
        let iter = Iter::new(format!("VALUE={invalid_esc}").as_bytes()).collect::<Vec<_>>();

        assert!(matches!(
            iter[0],
            Err(ParseBufError::LineParse(ref v, idx)) if v == invalid_esc && idx == invalid_esc.find('\\').unwrap() + 1
        ));
    }
}
