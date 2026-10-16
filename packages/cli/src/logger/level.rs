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
    pub const SILENT: Level = Level(u32::MAX);

    const NAMED: [(&'static str, Level); 11] = [
        ("trace", Level::TRACE),
        ("debug", Level::DEBUG),
        ("info", Level::INFO),
        ("udebug", Level::UDEBUG),
        ("uinfo", Level::UINFO),
        ("uwarn", Level::UWARN),
        ("uerror", Level::UERROR),
        ("warn", Level::WARN),
        ("error", Level::ERROR),
        ("fatal", Level::FATAL),
        ("silent", Level::SILENT),
    ];

    pub fn parse(name: &str) -> Option<Level> {
        Self::NAMED
            .iter()
            .find(|(named, _)| *named == name)
            .map(|(_, level)| *level)
    }

    pub fn from_value(value: u32) -> Option<Level> {
        Self::NAMED
            .iter()
            .find(|(_, level)| level.0 == value)
            .map(|(_, level)| *level)
    }

    pub fn name(self) -> &'static str {
        Self::NAMED
            .iter()
            .find(|(_, level)| *level == self)
            .map_or("unknown", |(name, _)| name)
    }

    pub fn value(self) -> u32 {
        self.0
    }
}
