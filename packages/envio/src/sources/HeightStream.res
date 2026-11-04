/*
Reconnect driver shared by every height subscription transport. A transport
supplies `connect`, which wires its socket to the driver callbacks and returns a
close function. Retries, staleness detection and status reporting are decided in
Rust (`source_manager/stream.rs`); this side connects, closes and arms timers on
the clock when told to.
*/

type driver = {
  // The stream is usable: for SSE the connection opened, for WebSocket the
  // subscription was confirmed.
  onConnected: unit => unit,
  onKeepAlive: unit => unit,
  onHeight: int => unit,
  // A message the transport couldn't read. Not a failure by itself, but from
  // then on only a height we can read counts as the connection still being
  // useful, so a stream of them goes quiet and fails as "unreadable", carrying
  // the frame that started it.
  onUnreadable: (~detail: string) => unit,
  onFailure: (~reason: Source.heightSubscriptionDownReason, ~detail: string=?) => unit,
}

module Native = {
  // Effects are only ever built by Rust.
  @@warning("-37")

  type t

  type downReason = {name: string, code?: int}

  @tag("kind")
  type effect =
    | Connect({generation: int})
    | Close({generation: int})
    | ArmTimer({timer: int, label: string, millis: int, jitter: bool})
    | ClearTimer({timer: int})
    | Height({height: int})
    | Status({down?: downReason, detail?: string})

  @send external make: (Core.heightStreamCtor, int) => t = "make"
  @send external takeEffect: t => Nullable.t<effect> = "takeEffect"
  @send external isCurrent: (t, int) => bool = "isCurrent"
  @send external start: t => unit = "start"
  @send external unsubscribe: t => unit = "unsubscribe"
  @send external connected: (t, int, float) => unit = "connected"
  @send external keepAlive: (t, int) => unit = "keepAlive"
  @send external height: (t, int, int, float) => unit = "height"
  @send external unreadable: (t, int, string) => unit = "unreadable"
  @send
  external failure: (t, int, downReason, Nullable.t<string>, float) => unit = "failure"
  @send external connectFailed: (t, int, Nullable.t<string>, float) => unit = "connectFailed"
  @send external timerFired: (t, int, float) => unit = "timerFired"
}

// A constructor without a payload is its own name at runtime.
let reasonToNative = (reason: Source.heightSubscriptionDownReason): Native.downReason =>
  switch reason {
  | Http(code) => {name: "Http", code}
  | reason => {name: reason->(Utils.magic: Source.heightSubscriptionDownReason => string)}
  }

let reasonFromNative = ({name, ?code}: Native.downReason): Source.heightSubscriptionDownReason =>
  switch code {
  | Some(code) => Http(code)
  | None => name->(Utils.magic: string => Source.heightSubscriptionDownReason)
  }

let subscribe = (
  ~clock: Clock.t,
  ~staleTimeout: int,
  ~onHeight: int => unit,
  ~onStatus: Source.heightSubscriptionStatus => unit,
  // Must not allocate anything it can then throw past: a throw leaves the driver
  // without the close function, so only the transport can release what it took.
  ~connect: driver => unit => unit,
): (unit => unit) => {
  let native = Core.getAddon().heightStream->Native.make(staleTimeout)
  let timers: Map.t<int, Clock.timer> = Map.make()
  let closeConnection = ref(None)

  // Drained one effect at a time: a transport can report synchronously from
  // inside `connect`, and what that queues still runs in the order it was owed.
  let rec flush = () => {
    let continue = ref(true)
    while continue.contents {
      switch native->Native.takeEffect->Nullable.toOption {
      | Some(effect) => execute(effect)
      | None => continue := false
      }
    }
  }
  and report = call => {
    call()
    flush()
  }
  and execute = (effect: Native.effect) =>
    switch effect {
    | Connect({generation}) =>
      let driver = {
        onConnected: () => report(() => native->Native.connected(generation, clock.now())),
        onKeepAlive: () => report(() => native->Native.keepAlive(generation)),
        onHeight: height => report(() => native->Native.height(generation, height, clock.now())),
        onUnreadable: (~detail) => report(() => native->Native.unreadable(generation, detail)),
        onFailure: (~reason, ~detail=?) =>
          report(() =>
            native->Native.failure(
              generation,
              reason->reasonToNative,
              detail->Nullable.fromOption,
              clock.now(),
            )
          ),
      }
      // A transport constructor can throw on a malformed url. Left to escape it
      // would reach a timer callback on the next retry and take the process
      // down. What it says is the failure's detail.
      switch try Ok(connect(driver)) catch {
      | exn => Error(exn)
      } {
      | Ok(close) =>
        if native->Native.isCurrent(generation) {
          closeConnection := Some(close)
        } else {
          close()
        }
      | Error(exn) =>
        report(() =>
          native->Native.connectFailed(
            generation,
            exn->Utils.exnMessage->Nullable.fromOption,
            clock.now(),
          )
        )
      }
    | Close(_) =>
      switch closeConnection.contents {
      | Some(close) =>
        closeConnection := None
        close()
      | None => ()
      }
    | ArmTimer({timer, label, millis, jitter}) =>
      timers->Map.set(
        timer,
        clock.setTimeout(
          ~label,
          () => {
            timers->Map.delete(timer)->ignore
            report(() => native->Native.timerFired(timer, clock.now()))
          },
          jitter ? clock->Clock.jitter(millis) : millis,
        ),
      )
    // Rust only clears a timer it armed that has not fired, and a fired one
    // leaves the map before Rust hears of it.
    | ClearTimer({timer}) =>
      clock.clearTimeout(timers->Map.get(timer)->Option.getUnsafe)
      timers->Map.delete(timer)->ignore
    | Height({height}) => onHeight(height)
    | Status({?down, ?detail}) =>
      onStatus(
        switch down {
        | None => Live
        | Some(reason) => Down({reason: reason->reasonFromNative, ?detail})
        },
      )
    }

  report(() => native->Native.start)
  () => report(() => native->Native.unsubscribe)
}
