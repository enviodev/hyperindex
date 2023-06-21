let resolvePromiseAfterDelay = (~delayMilliseconds) =>
  Js.Promise2.make((~resolve, ~reject as _) => {
    let _interval = Js.Global.setTimeout(_ => {
      resolve(. ())
    }, delayMilliseconds)
  })
