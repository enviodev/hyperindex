/// Pino's numeric levels, which the `u*` levels for user handler logs sit
/// between, so a level filter can let a user's logs through without the
/// indexer's own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Level(u32);

impl Level {
    pub const TRACE: Level = Level(10);
    pub const DEBUG: Level = Level(20);
    pub const INFO: Level = Level(30);
    pub const UDEBUG: Level = Level(32);
    pub const UINFO: Level = Level(34);
    pub const UWARN: Level = Level(36);
    pub const UERROR: Level = Level(38);
    pub const WARN: Level = Level(40);
    pub const ERROR: Level = Level(50);
    pub const FATAL: Level = Level(60);
    // The largest number ReScript's 32-bit int holds, so the level check there
    // compares against the same value.
    pub const SILENT: Level = Level(2_147_483_647);

    pub const ALL: [Level; 11] = [
        Level::TRACE,
        Level::DEBUG,
        Level::INFO,
        Level::UDEBUG,
        Level::UINFO,
        Level::UWARN,
        Level::UERROR,
        Level::WARN,
        Level::ERROR,
        Level::FATAL,
        Level::SILENT,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Level::TRACE => "trace",
            Level::DEBUG => "debug",
            Level::INFO => "info",
            Level::UDEBUG => "udebug",
            Level::UINFO => "uinfo",
            Level::UWARN => "uwarn",
            Level::UERROR => "uerror",
            Level::WARN => "warn",
            Level::ERROR => "error",
            Level::FATAL => "fatal",
            _ => "silent",
        }
    }

    pub fn parse(name: &str) -> Option<Level> {
        Level::ALL.into_iter().find(|level| level.name() == name)
    }

    pub fn from_value(value: u32) -> Option<Level> {
        Level::ALL.into_iter().find(|level| level.0 == value)
    }

    pub fn value(self) -> u32 {
        self.0
    }
}
