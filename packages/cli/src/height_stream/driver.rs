//! Runs one subscription's [`HeightStream`] on a clock: opens and closes the
//! transport's connections, sleeps out its timers, and hands what it reports
//! to a sink.

use std::sync::Arc;

use tokio::sync::{mpsc, oneshot};

use super::machine::{DownReason, Effect, HeightStream};
use crate::clock::{Clock, Hold, Sleep};

/// What a connection saw, in the order it saw it.
#[derive(Debug, PartialEq)]
pub enum Report {
    /// The stream is usable.
    Connected,
    KeepAlive,
    Height(i64),
    Unreadable(String),
    Failure(DownReason, Option<String>),
}

pub type Reports = mpsc::UnboundedSender<(u32, Report)>;

/// An open connection. Dropping it closes it.
pub struct Connection {
    close: Option<oneshot::Sender<()>>,
}

impl Connection {
    /// Runs `connection` until it ends or the returned handle is dropped, in
    /// which case `connection` is told so it can close the socket properly.
    pub fn spawn<F, Fut>(connection: F) -> Connection
    where
        F: FnOnce(oneshot::Receiver<()>) -> Fut,
        Fut: std::future::Future<Output = ()> + Send + 'static,
    {
        let (close, closed) = oneshot::channel();
        napi::bindgen_prelude::spawn(connection(closed));
        Connection { close: Some(close) }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        if let Some(close) = self.close.take() {
            let _ = close.send(());
        }
    }
}

pub trait Transport: Send + Sync + 'static {
    fn stale_timeout(&self) -> u32;
    /// Opens a connection whose reports carry `generation`. An error is a url
    /// it can't even try, and says why.
    fn connect(&self, generation: u32, reports: Reports) -> Result<Connection, String>;
}

pub trait Sink: Send + Sync + 'static {
    fn height(&self, height: i64);
    /// Live when `down` is absent.
    fn status(&self, down: Option<DownReason>, detail: Option<String>);
}

/// A running subscription. Dropping it unsubscribes.
pub struct Subscription {
    stop: Option<oneshot::Sender<()>>,
}

impl Drop for Subscription {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
    }
}

pub fn subscribe(
    transport: Arc<dyn Transport>,
    clock: Arc<dyn Clock>,
    sink: Arc<dyn Sink>,
) -> Subscription {
    let (stop, stopped) = oneshot::channel();
    // The first connect happens here rather than in the task, so a url that
    // can't be opened is reported before the caller gets its handle back, on
    // the same turn, as every later attempt is.
    let driver = Driver::new(transport, clock, sink);
    napi::bindgen_prelude::spawn(driver.run(stopped));
    Subscription { stop: Some(stop) }
}

struct Driver {
    transport: Arc<dyn Transport>,
    clock: Arc<dyn Clock>,
    sink: Arc<dyn Sink>,
    machine: HeightStream,
    reports: Reports,
    received: mpsc::UnboundedReceiver<(u32, Report)>,
    connection: Option<Connection>,
    timer: Option<(u32, Sleep)>,
}

impl Driver {
    fn new(transport: Arc<dyn Transport>, clock: Arc<dyn Clock>, sink: Arc<dyn Sink>) -> Self {
        let (reports, received) = mpsc::unbounded_channel();
        let mut driver = Driver {
            machine: HeightStream::new(transport.stale_timeout()),
            transport,
            clock,
            sink,
            reports,
            received,
            connection: None,
            timer: None,
        };
        driver.machine.start();
        driver.execute();
        driver
    }

    /// Carries out what the machine asked for, in order. A connect that fails
    /// on the spot reports here, so its effects run in the same pass.
    fn execute(&mut self) {
        while let Some(effect) = self.machine.take_effect() {
            match effect {
                Effect::Connect { generation } => {
                    match self.transport.connect(generation, self.reports.clone()) {
                        Ok(connection) => self.connection = Some(connection),
                        Err(detail) => {
                            self.machine.connect_failed(
                                generation,
                                Some(detail),
                                self.clock.now_ms(),
                            );
                        }
                    }
                }
                Effect::Close => self.connection = None,
                Effect::ArmTimer {
                    timer,
                    label,
                    millis,
                    jitter,
                } => {
                    let millis = if jitter {
                        jittered(millis, self.clock.random())
                    } else {
                        millis
                    };
                    self.timer = Some((timer, self.clock.sleep(label, u64::from(millis))));
                }
                Effect::ClearTimer { timer } => {
                    if self
                        .timer
                        .as_ref()
                        .is_some_and(|(pending, _)| *pending == timer)
                    {
                        self.timer = None;
                    }
                }
                Effect::Height(height) => self.sink.height(height),
                Effect::Status { down, detail } => self.sink.status(down, detail),
            }
        }
    }

    fn report(&mut self, generation: u32, report: Report) {
        let now = self.clock.now_ms();
        match report {
            Report::Connected => self.machine.connected(generation, now),
            Report::KeepAlive => self.machine.keep_alive(generation),
            Report::Height(height) => self.machine.height(generation, height, now),
            Report::Unreadable(detail) => self.machine.unreadable(generation, detail),
            Report::Failure(reason, detail) => {
                self.machine.failure(generation, reason, detail, now);
            }
        }
    }

    async fn run(mut self, mut stopped: oneshot::Receiver<()>) {
        loop {
            let timer = async {
                match self.timer.as_mut() {
                    Some((_, sleep)) => sleep.as_mut().await,
                    None => std::future::pending::<Hold>().await,
                }
            };
            tokio::select! {
                biased;
                _ = &mut stopped => return,
                hold = timer => {
                    let (fired, _) = self.timer.take().expect("the timer that fired is pending");
                    self.machine.timer_fired(fired, self.clock.now_ms());
                    self.execute();
                    // Held until what it woke has run, so a test's advance
                    // waits for the reports it caused.
                    drop(hold);
                }
                Some((generation, report)) = self.received.recv() => {
                    self.report(generation, report);
                    self.execute();
                }
            }
        }
    }
}

/// Half the delay fixed, half spread across it, as the ReScript clock does.
fn jittered(millis: u32, random: f64) -> u32 {
    let half = millis / 2;
    half + (random * f64::from(half)) as u32
}
