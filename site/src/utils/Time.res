let useTypedCharactersString = (~delay=25, string) => {
  let (revealedCharCount, setRevealedCharCount) = React.useState(_ => 0)
  let (optIntervalId, setOptIntervalId) = React.useState(_ => None)

  React.useEffect4(() => {
    let _ = optIntervalId->Option.map(intervalId => {
      if revealedCharCount >= string->String.length {
        Js.Global.clearInterval(intervalId)
      }
    })

    None
  }, (optIntervalId, revealedCharCount, string, delay))

  React.useEffect2(() => {
    setRevealedCharCount(_ => 0)
    let intervalId = Js.Global.setInterval(() => {
      setRevealedCharCount(
        prevCount => {
          prevCount + 1
        },
      )
    }, delay)

    setOptIntervalId(_ => Some(intervalId))

    Some(() => Js.Global.clearInterval(intervalId))
  }, (delay, string))

  string->Js.String2.substrAtMost(~from=0, ~length=revealedCharCount)
}

@ocaml.doc(`Delay the display execution`)
module DelayedDisplay = {
  @react.component
  let make = (~delay=1000, ~children, ~tempDisplay=React.null) => {
    let (show, setShow) = React.useState(_ => false)

    React.useEffect1(() => {
      let timeout = Js.Global.setTimeout(_ => setShow(_ => true), delay)
      Some(_ => Js.Global.clearTimeout(timeout))
    }, [])

    if show {
      children
    } else {
      tempDisplay
    }
  }
}
