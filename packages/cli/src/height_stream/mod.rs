//! Height subscriptions: a transport reads the socket, [`machine`] decides
//! retries and staleness, and [`driver`] runs it on a clock and hands what it
//! reports to a sink.

mod driver;
mod machine;
mod sse;
mod ws;

use std::sync::Arc;

use napi::bindgen_prelude::{Function, Status};
use napi::threadsafe_function::{ThreadsafeFunction, ThreadsafeFunctionCallMode};
use napi_derive::napi;

use crate::clock::{Clock, RealClock, VirtualClockHandle};
use driver::{Sink, Subscription};
use machine::DownReason;

/// What a subscription reports about its connection. Live when `down` is
/// absent; otherwise `down` is the reason's metric label.
#[napi(object)]
pub struct HeightStreamStatus {
    pub down: Option<String>,
    /// Whatever the provider said about this one failure.
    pub detail: Option<String>,
}

/// Weak, so a subscription nobody closed doesn't keep the process alive.
type Callback<T> = ThreadsafeFunction<T, (), T, Status, false, true>;

struct JsSink {
    clock: Arc<dyn Clock>,
    on_height: Callback<i64>,
    on_status: Callback<HeightStreamStatus>,
}

impl Sink for JsSink {
    fn height(&self, height: i64) {
        // Held until the callback has run, so a test's advance waits for it.
        let hold = self.clock.hold();
        self.on_height.call_with_return_value(
            height,
            ThreadsafeFunctionCallMode::NonBlocking,
            move |_, _| {
                drop(hold);
                Ok(())
            },
        );
    }

    fn status(&self, down: Option<DownReason>, detail: Option<String>) {
        let hold = self.clock.hold();
        self.on_status.call_with_return_value(
            HeightStreamStatus {
                down: down.map(DownReason::label),
                detail,
            },
            ThreadsafeFunctionCallMode::NonBlocking,
            move |_, _| {
                drop(hold);
                Ok(())
            },
        );
    }
}

fn clock_of(clock: Option<&VirtualClockHandle>) -> Arc<dyn Clock> {
    clock.map_or_else(RealClock::shared, VirtualClockHandle::shared)
}

fn callbacks(
    on_height: Function<i64, ()>,
    on_status: Function<HeightStreamStatus, ()>,
) -> napi::Result<(Callback<i64>, Callback<HeightStreamStatus>)> {
    Ok((
        on_height
            .build_threadsafe_function()
            .callee_handled::<false>()
            .weak::<true>()
            .build()?,
        on_status
            .build_threadsafe_function()
            .callee_handled::<false>()
            .weak::<true>()
            .build()?,
    ))
}

/// One source's height subscription. Closing it unsubscribes.
#[napi]
pub struct HeightSubscription {
    subscription: Option<Subscription>,
}

#[napi]
impl HeightSubscription {
    /// A node's `newHeads` over WebSocket. `clock` is a test's virtual clock;
    /// without one, real time.
    #[napi(factory)]
    pub fn ws(
        url: String,
        clock: Option<&VirtualClockHandle>,
        on_height: Function<i64, ()>,
        on_status: Function<HeightStreamStatus, ()>,
    ) -> napi::Result<Self> {
        let clock = clock_of(clock);
        let (on_height, on_status) = callbacks(on_height, on_status)?;
        Ok(HeightSubscription {
            subscription: Some(driver::subscribe(
                Arc::new(ws::Ws::new(url)),
                clock.clone(),
                Arc::new(JsSink {
                    clock,
                    on_height,
                    on_status,
                }),
            )),
        })
    }

    /// HyperSync's height stream.
    #[napi(factory)]
    pub fn sse(
        hypersync_url: String,
        api_token: String,
        user_agent: String,
        clock: Option<&VirtualClockHandle>,
        on_height: Function<i64, ()>,
        on_status: Function<HeightStreamStatus, ()>,
    ) -> napi::Result<Self> {
        let clock = clock_of(clock);
        let (on_height, on_status) = callbacks(on_height, on_status)?;
        Ok(HeightSubscription {
            subscription: Some(driver::subscribe(
                Arc::new(sse::Sse::new(&hypersync_url, api_token, user_agent)),
                clock.clone(),
                Arc::new(JsSink {
                    clock,
                    on_height,
                    on_status,
                }),
            )),
        })
    }

    #[napi]
    pub fn close(&mut self) {
        self.subscription = None;
    }
}
