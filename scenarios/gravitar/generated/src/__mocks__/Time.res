let resolveAfterDelay = (~delayMilliseconds) => {
  Js.Promise2.make((~resolve, ~reject as _) => {
    let _ = Js.Global.setTimeout(() => {
      resolve(. ())
    }, delayMilliseconds)
  })
}
