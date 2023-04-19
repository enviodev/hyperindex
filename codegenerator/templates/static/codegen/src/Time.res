let resolvePromiseAfterDelay = (~delayMilliseconds) =>
  Js.Promise2.make((~resolve, ~reject as _) => {
    let _interval = Js.Global.setTimeout(_ => {
      resolve(. ())
    }, delayMilliseconds)
  })

let retryOnCatchAfterDelay = (
  ~task: unit => Promise.t<'a>,
  ~retryMessage,
  ~retryDelayMilliseconds,
) => {
  let rec executeTask = () => {
    task()->Promise.catch(err => {
      Js.log2("Error: ", err)
      Js.log(
        `Waiting ${retryDelayMilliseconds->Belt.Int.toString} milliseconds seconds before retrying`,
      )
      Js.log(retryMessage)

      resolvePromiseAfterDelay(~delayMilliseconds=retryDelayMilliseconds)->Promise.then(_ => {
        Js.log("Retrying...")
        Js.log(retryMessage)

        executeTask()
      })
    })
  }

  executeTask()
}
