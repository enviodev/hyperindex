//! Height subscriptions: a transport reads the socket, [`machine`] decides
//! retries and staleness, and [`driver`] runs it on a clock and hands what it
//! reports to a sink.

pub(crate) mod driver;
pub(crate) mod machine;
pub(crate) mod sse;
pub(crate) mod ws;
