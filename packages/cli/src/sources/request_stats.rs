use napi_derive::napi;

pub(crate) const QUERY_BLOCK_HASHES_METHOD: &str = "getBlockHashes";

/// Timing for one backend request. Multiple entries may be returned for a
/// single source operation when that operation paginates internally.
#[napi(object)]
#[derive(Clone, Debug, PartialEq)]
pub struct RequestStat {
    pub method: String,
    pub seconds: f64,
    /// Blocks the backend returned, before any matching drops them. Absent
    /// for methods whose responses aren't measured in blocks.
    pub response_blocks: Option<i64>,
}

impl RequestStat {
    pub(crate) fn new(method: &str, seconds: f64) -> Self {
        RequestStat {
            method: method.to_string(),
            seconds,
            response_blocks: None,
        }
    }
}

/// Collects request timings until a source operation reports them.
#[derive(Default)]
pub(crate) struct Stats(std::sync::Mutex<Vec<RequestStat>>);

impl Stats {
    pub(crate) fn record(&self, method: &str, seconds: f64) {
        self.0
            .lock()
            .unwrap()
            .push(RequestStat::new(method, seconds));
    }

    pub(crate) fn take(&self) -> Vec<RequestStat> {
        std::mem::take(&mut *self.0.lock().unwrap())
    }
}
