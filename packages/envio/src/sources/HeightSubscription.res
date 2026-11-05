// A source's height subscription. The addon owns all of it: the transport, the
// reconnect schedule and its timers. What comes back here is each height and
// each change in the connection's status.
type t
type status = {down: Nullable.t<string>, detail: Nullable.t<string>}

@send
external wsNative: (
  Core.heightSubscriptionCtor,
  string,
  Nullable.t<Clock.native>,
  int => unit,
  status => unit,
) => t = "ws"

@send
external sseNative: (
  Core.heightSubscriptionCtor,
  string,
  string,
  string,
  Nullable.t<Clock.native>,
  int => unit,
  status => unit,
) => t = "sse"

@send external close: t => unit = "close"

let toStatus = ({down, detail}: status): Source.heightSubscriptionStatus =>
  switch down->Nullable.toOption {
  | None => Live
  | Some(label) =>
    Down({reason: label->Source.downReasonFromLabel, detail: ?(detail->Nullable.toOption)})
  }

let open_ = (~clock: Clock.t, subscribe) => {
  // A virtual-time run hands its clock to Rust too; a subscription that would
  // fall back to real time there is the same mistake as reaching for Clock.real.
  if Clock.refuseReal.contents && clock.native->Option.isNone {
    JsError.throwWithMessage(
      "A height subscription opened on virtual time without the clock's native handle, so its timers would run on real time.",
    )
  }
  let subscription = subscribe(clock.native->Nullable.fromOption)
  () => subscription->close
}

let ws = (~clock, ~url, ~onHeight, ~onStatus) =>
  open_(~clock, native =>
    Core.getAddon().heightSubscription->wsNative(url, native, onHeight, status =>
      onStatus(status->toStatus)
    )
  )

let sse = (~clock, ~hyperSyncUrl, ~apiToken, ~onHeight, ~onStatus) =>
  open_(~clock, native =>
    Core.getAddon().heightSubscription->sseNative(
      hyperSyncUrl,
      apiToken,
      `hyperindex/${Utils.EnvioPackage.value.version}`,
      native,
      onHeight,
      status => onStatus(status->toStatus),
    )
  )
