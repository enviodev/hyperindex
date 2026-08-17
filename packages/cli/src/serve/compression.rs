//! Response compression, negotiated exactly as Hasura negotiates it.
//!
//! The rules are narrower than a stock compression middleware's, and each one
//! is pinned by a recorded case in `corpus/18-transport.ts`:
//!
//! - gzip is the only encoding; `br` and `deflate` are never answered with.
//! - A missing `Accept-Encoding`, or a bare `*`, means identity only. That is
//!   conservative (RFC 7231 allows anything there), and deliberate on
//!   Hasura's side.
//! - When identity and gzip are both acceptable, a body under 700 bytes is
//!   left alone: below that, compression costs more than it saves.
//! - Only an explicit `identity;q=0` makes gzip mandatory regardless of size.
//!
//! No `Vary` header is emitted, also matching Hasura.

use axum::http::HeaderMap;
use flate2::{Compress, Compression, Crc, FlushCompress, Status};
use std::cell::RefCell;

/// Hasura's cutoff: under this many bytes, compression is skipped whenever
/// identity is also acceptable.
const MIN_COMPRESS_BYTES: usize = 700;

/// Bodies at or above this size are compressed on a blocking thread instead
/// of the async executor. At ~1 GB/s (zlib-rs, level 1) this bounds the time
/// a request spends holding a runtime worker to about a millisecond; serve
/// answers list queries tens of megabytes long, where compressing inline
/// would stall every other task on that worker for tens of milliseconds.
const OFFLOAD_BYTES: usize = 1024 * 1024;

/// Level 1. Response bytes are not part of the parity contract — only whether
/// the response was compressed at all — so the level is free, and level 1
/// captures ~96% of level 6's saving on a large response for ~20% of the CPU.
const LEVEL: Compression = Compression::new(1);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Accepted {
    gzip: bool,
    identity: bool,
}

/// Which encodings the client will take, following Hasura's
/// `getAcceptedEncodings`. Quality values are ignored except where they
/// *reject* an encoding, which is the only place they change the outcome.
fn accepted_encodings(headers: &HeaderMap) -> Accepted {
    // The q-value checks are exact string matches rather than a parse,
    // because Hasura's are: it compares against the literal "identity;q=0"
    // and "gzip;q=0" after splitting on commas. Accepting `q=0.0` here would
    // be more correct and less compatible.
    let mut count = 0usize;
    let mut only_star = true;
    let mut gzip_listed = false;
    let mut gzip_refused = false;
    let mut identity_listed = false;
    let mut identity_refused = false;
    let mut star_refused = false;

    for header in headers.get_all(axum::http::header::ACCEPT_ENCODING) {
        let Ok(text) = header.to_str() else { continue };
        for value in text.split(',').map(str::trim) {
            count += 1;
            only_star &= value == "*";
            gzip_listed |= value.starts_with("gzip");
            gzip_refused |= value == "gzip;q=0";
            identity_listed |= value.starts_with("identity");
            identity_refused |= value == "identity;q=0";
            star_refused |= value == "*;q=0";
        }
    }

    // No header at all, or exactly `*`: technically "send what you like", but
    // Hasura reads it as identity-only and so must we.
    if count == 0 || only_star {
        return Accepted {
            gzip: false,
            identity: true,
        };
    }

    Accepted {
        gzip: gzip_listed && !gzip_refused,
        identity: !(identity_refused || (star_refused && !identity_listed)),
    }
}

/// Whether a body of this size should be gzipped for this client.
fn should_compress(headers: &HeaderMap, len: usize) -> bool {
    match accepted_encodings(headers) {
        // Both are fine, so compress only when it pays for itself.
        Accepted {
            gzip: true,
            identity: true,
        } => len >= MIN_COMPRESS_BYTES,
        // Identity was explicitly rejected: gzip regardless of size.
        Accepted {
            gzip: true,
            identity: false,
        } => true,
        _ => false,
    }
}

thread_local! {
    /// One deflate state per thread, reused across responses.
    ///
    /// Building a compressor allocates zlib's window and hash tables — a few
    /// hundred KB — and that allocation dominates the work: measured on a
    /// 2 KB response, a fresh compressor per response costs ~34 us against
    /// ~7 us for a reset one. Resetting is why this holds the raw `Compress`
    /// and writes the gzip framing by hand; the streaming encoders own their
    /// state and cannot be reset.
    static DEFLATE: RefCell<Option<Compress>> = const { RefCell::new(None) };
}

/// Fixed gzip header: deflate, no mtime, unknown OS. Nothing downstream
/// reads these bytes, and Hasura's differ too — only the payload matters.
const GZIP_HEADER: [u8; 10] = [0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff];

fn gzip(body: &[u8]) -> Vec<u8> {
    DEFLATE.with(|cell| {
        let mut slot = cell.borrow_mut();
        let compress = match slot.as_mut() {
            Some(compress) => {
                compress.reset();
                compress
            }
            // `false`: raw deflate, since the gzip framing is written here.
            None => slot.insert(Compress::new(LEVEL, false)),
        };

        let mut out = Vec::with_capacity(body.len() / 8 + 64);
        out.extend_from_slice(&GZIP_HEADER);

        let mut consumed = 0usize;
        loop {
            let before_in = compress.total_in();
            let before_out = compress.total_out();
            let status = compress.compress_vec(&body[consumed..], &mut out, FlushCompress::Finish);
            consumed += (compress.total_in() - before_in) as usize;
            match status {
                Ok(Status::StreamEnd) => break,
                Ok(Status::Ok) | Ok(Status::BufError) => {
                    // No progress means the output buffer is full.
                    if compress.total_out() == before_out {
                        out.reserve(body.len() / 4 + 64);
                    }
                }
                Err(_) => return body.to_vec(),
            }
        }

        let mut crc = Crc::new();
        crc.update(body);
        out.extend_from_slice(&crc.sum().to_le_bytes());
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out
    })
}

/// The body to send, and the `Content-Encoding` to send it under.
pub(super) struct Encoded {
    pub body: Vec<u8>,
    pub content_encoding: Option<axum::http::HeaderValue>,
}

/// Compresses `body` if this client's `Accept-Encoding` calls for it. Large
/// bodies are compressed on a blocking thread; small ones inline, where the
/// work is measured in microseconds and the hand-off would cost more than the
/// compression.
pub(super) async fn encode(headers: &HeaderMap, body: String) -> Encoded {
    if !should_compress(headers, body.len()) {
        return Encoded {
            body: body.into_bytes(),
            content_encoding: None,
        };
    }
    let gzipped = if body.len() >= OFFLOAD_BYTES {
        // Shared rather than moved so the body survives a compressor that
        // panics: an empty payload labelled gzip is a decode error at the
        // client, where the uncompressed body is merely larger.
        let body = std::sync::Arc::new(body);
        let offloaded = std::sync::Arc::clone(&body);
        match tokio::task::spawn_blocking(move || gzip(offloaded.as_bytes())).await {
            Ok(gzipped) => gzipped,
            Err(error) => {
                tracing::error!(%error, "envio serve: response compression failed");
                return Encoded {
                    body: std::sync::Arc::unwrap_or_clone(body).into_bytes(),
                    content_encoding: None,
                };
            }
        }
    } else {
        gzip(body.as_bytes())
    };
    Encoded {
        body: gzipped,
        content_encoding: Some(axum::http::HeaderValue::from_static("gzip")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(accept_encoding: Option<&str>) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Some(value) = accept_encoding {
            headers.insert(
                axum::http::header::ACCEPT_ENCODING,
                value.parse().expect("valid header"),
            );
        }
        headers
    }

    // The negotiation table is pinned end-to-end by corpus/18-transport.ts
    // against live Hasura; this covers the same rules at the unit a
    // recorded case cannot reach, namely the size cutoff boundary.
    #[test]
    fn size_cutoff_applies_only_when_identity_is_also_acceptable() {
        let gzip_only = headers(Some("gzip, identity;q=0"));
        let both = headers(Some("gzip"));
        assert_eq!(
            [
                should_compress(&both, MIN_COMPRESS_BYTES - 1),
                should_compress(&both, MIN_COMPRESS_BYTES),
                should_compress(&gzip_only, 1),
                should_compress(&gzip_only, MIN_COMPRESS_BYTES),
            ],
            [false, true, true, true]
        );
    }

    #[test]
    fn only_gzip_is_ever_offered() {
        let big = MIN_COMPRESS_BYTES;
        assert_eq!(
            [
                should_compress(&headers(None), big),
                should_compress(&headers(Some("*")), big),
                should_compress(&headers(Some("br")), big),
                should_compress(&headers(Some("deflate")), big),
                should_compress(&headers(Some("gzip;q=0")), big),
                should_compress(&headers(Some("identity")), big),
                should_compress(&headers(Some("gzip, deflate, br")), big),
            ],
            [false, false, false, false, false, false, true]
        );
    }

    #[test]
    fn compressed_output_round_trips() {
        let body = "x".repeat(4096);
        let encoded = gzip(body.as_bytes());
        assert!(encoded.len() < body.len());
        let mut decoder = flate2::read::GzDecoder::new(&encoded[..]);
        let mut round_tripped = String::new();
        std::io::Read::read_to_string(&mut decoder, &mut round_tripped).unwrap();
        assert_eq!(round_tripped, body);
    }
}
