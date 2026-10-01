mod format;
mod logo;
mod render;
mod session;
mod state;

use napi_derive::napi;
use render::{Palette, SPINNER_INTERVAL_MS};
use session::{Session, Size};
use state::{Messages, State};
use state::{TuiChain, TuiInfo, TuiMessage};
use std::{
    ffi::CStr,
    fs::{File, OpenOptions},
    io::{self, Write},
    os::fd::AsRawFd,
    sync::{mpsc, Arc},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

/// The terminal behind stdout, opened anew. Node switches its own stdout to
/// non-blocking mode, which would make a write from this thread fail with
/// `EAGAIN` whenever the terminal falls behind; a fresh open of the same device
/// blocks as a terminal write should.
#[derive(Clone)]
struct Tty(Arc<File>);

impl Tty {
    fn open() -> io::Result<Self> {
        let mut name = [0 as libc::c_char; 256];
        // SAFETY: the buffer outlives the call and its length is passed along.
        let code = unsafe { libc::ttyname_r(libc::STDOUT_FILENO, name.as_mut_ptr(), name.len()) };
        if code != 0 {
            return Err(io::Error::from_raw_os_error(code));
        }
        // SAFETY: on success `ttyname_r` wrote a NUL-terminated path into the buffer.
        let path = unsafe { CStr::from_ptr(name.as_ptr()) }
            .to_str()
            .map_err(io::Error::other)?;
        Ok(Tty(Arc::new(OpenOptions::new().write(true).open(path)?)))
    }

    fn size(&self) -> io::Result<Size> {
        // SAFETY: `winsize` is plain data the ioctl fills in.
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        // SAFETY: the descriptor is open for as long as `self` is, and
        // TIOCGWINSZ writes only into the struct passed.
        if unsafe { libc::ioctl(self.0.as_raw_fd(), libc::TIOCGWINSZ, &mut size) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Size {
            width: size.ws_col,
            height: size.ws_row,
        })
    }
}

impl Write for Tty {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        (&*self.0).write(buf)
    }
    fn flush(&mut self) -> io::Result<()> {
        (&*self.0).flush()
    }
}

/// A frame that panics mid-draw would otherwise leave the user's shell with
/// no cursor.
struct ShowCursorOnPanic(Tty);

impl Drop for ShowCursorOnPanic {
    fn drop(&mut self) {
        if thread::panicking() {
            let _ = self.0.write_all(b"\x1b[?25h");
        }
    }
}

fn supports_truecolor() -> bool {
    std::env::var("COLORTERM").is_ok_and(|value| {
        value.eq_ignore_ascii_case("truecolor") || value.eq_ignore_ascii_case("24bit")
    })
}

fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0., |elapsed| elapsed.as_millis() as f64)
}

enum Command {
    Update(Vec<TuiChain>),
    Messages(Messages),
    Print(String),
    Stop(mpsc::Sender<()>),
}

fn run(mut session: Session<Tty>, tty: Tty, mut state: State, commands: mpsc::Receiver<Command>) {
    let started = Instant::now();
    loop {
        let mut batch: Vec<Command> =
            match commands.recv_timeout(Duration::from_millis(SPINNER_INTERVAL_MS)) {
                Ok(command) => vec![command],
                Err(mpsc::RecvTimeoutError::Timeout) => vec![],
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    let (ack, _) = mpsc::channel();
                    vec![Command::Stop(ack)]
                }
            };
        batch.extend(commands.try_iter());

        let mut printed: Vec<String> = Vec::new();
        let mut stop = None;
        for command in batch {
            match command {
                Command::Update(chains) => state.update(&chains, now_ms()),
                Command::Messages(messages) => state.messages = messages,
                Command::Print(text) => printed.push(text),
                Command::Stop(ack) => stop = Some(ack),
            }
        }
        let tick = (started.elapsed().as_millis() / SPINNER_INTERVAL_MS as u128) as usize;
        let printed = (!printed.is_empty()).then(|| printed.join("\n"));
        let result = tty.size().and_then(|size| match stop {
            Some(_) => session.finish(printed.as_deref(), &state, now_ms(), tick, size),
            None => session.render(printed.as_deref(), &state, now_ms(), tick, size),
        });
        // A terminal that went away takes the display with it.
        if result.is_err() || stop.is_some() {
            if let Some(ack) = stop {
                let _ = ack.send(());
            }
            return;
        }
    }
}

/// The progress display. Drawn by a thread of its own, so it keeps animating
/// while the indexer keeps the event loop busy.
#[napi]
pub struct Tui {
    commands: mpsc::Sender<Command>,
    running: bool,
}

#[napi]
impl Tui {
    #[napi(factory)]
    pub fn start(info: TuiInfo) -> napi::Result<Self> {
        let to_napi =
            |e: io::Error| napi::Error::from_reason(format!("Failed to start the TUI: {e}"));
        let tty = Tty::open().map_err(to_napi)?;
        tty.size().map_err(to_napi)?;
        let mut session = Session::new(
            tty.clone(),
            Palette {
                truecolor: supports_truecolor(),
            },
        );
        session.hide_cursor().map_err(to_napi)?;
        let (commands, receiver) = mpsc::channel();
        thread::Builder::new()
            .name("envio-tui".to_string())
            .spawn(move || {
                let _restore = ShowCursorOnPanic(tty.clone());
                run(session, tty, State::new(info), receiver)
            })
            .map_err(to_napi)?;
        Ok(Tui {
            commands,
            running: true,
        })
    }

    #[napi]
    pub fn update(&self, chains: Vec<TuiChain>) {
        let _ = self.commands.send(Command::Update(chains));
    }

    /// `null` when the messages failed to load.
    #[napi]
    pub fn set_messages(&self, messages: Option<Vec<TuiMessage>>) {
        let _ = self.commands.send(Command::Messages(
            messages.map_or(Messages::Failed, Messages::Loaded),
        ));
    }

    #[napi]
    pub fn print(&self, text: String) {
        let _ = self.commands.send(Command::Print(text));
    }

    /// Draws the final frame and returns once it is on screen, so it can run
    /// from an exit handler.
    #[napi]
    pub fn stop(&mut self) {
        if !std::mem::replace(&mut self.running, false) {
            return;
        }
        let (ack, done) = mpsc::channel();
        if self.commands.send(Command::Stop(ack)).is_ok() {
            let _ = done.recv_timeout(Duration::from_secs(2));
        }
    }
}
