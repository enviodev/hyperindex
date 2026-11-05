// A source built in Rust, which the source manager calls itself.
type t

// A page it answered with, as the addon hands it over.
type page

@send external canStream: t => bool = "canStream"
@send external onReorg: t => unit = "onReorg"
@send external getHeight: t => promise<int> = "getHeight"
