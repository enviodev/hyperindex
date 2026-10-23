/// The numbers JSON lines carry, with the `u*` levels of user handler logs
/// between info and warn so a line still says whose it is. A filter ranks each
/// `u*` level as the level it is named after: see `severity`.
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

    /// How a filter ranks the level: a user's error is an error, so a
    /// threshold of `warn` lets `uerror` through and one of `uerror` lets
    /// `warn` through no more than `error` would.
    pub fn severity(self) -> u32 {
        match self {
            Level::UDEBUG => Level::DEBUG.0,
            Level::UINFO => Level::INFO.0,
            Level::UWARN => Level::WARN.0,
            Level::UERROR => Level::ERROR.0,
            level => level.0,
        }
    }

    /// The stricter of two thresholds.
    pub fn at_least(self, floor: Level) -> Level {
        if self.severity() >= floor.severity() {
            self
        } else {
            floor
        }
    }
}
