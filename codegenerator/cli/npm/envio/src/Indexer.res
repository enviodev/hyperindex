type t = {
  config: Config.t,
  registrations: EventRegister.registrations,
  persistence: Persistence.t,
}

let make = (~config) => {
  config
}
