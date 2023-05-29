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

let registerNftFactoryHandlers = () => {
  try {
    let _ = %raw(`require("../../src/EventHandlers.ts")`)
  } catch {
  | _ =>
    Js.log(
      "Unable to find the handler file for [object]. Please place a file at ../../src/EventHandlers.ts",
    )
  }
}

let registerSimpleNftHandlers = () => {
  try {
    let _ = %raw(`require("../../src/EventHandlers.ts")`)
  } catch {
  | _ =>
    Js.log(
      "Unable to find the handler file for [object]. Please place a file at ../../src/EventHandlers.ts",
    )
  }
}

let registerAllHandlers = () => {
  registerGravatarHandlers()
  registerNftFactoryHandlers()
  registerSimpleNftHandlers()
}
