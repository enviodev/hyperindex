let registerGravatarHandlers = () => {
  try {
    let _ = %raw(`require("../../src/EventHandlers.bs.js")`)
  } catch {
  | _ =>
    Js.log(
      "Unable to find the handler file for [object]. Please place a file at ../../src/EventHandlers.bs.js",
    )
  }
}

let registerAllHandlers = () => {
  registerGravatarHandlers()
}
