@react.component
let make = (~children, ~className=?, ~href, ~openInNewTab=?) => {
  let (target, rel) =
    openInNewTab->Option.getWithDefault(false) ? ("_blank", "noopenner noreferrer") : ("", "")

  <Next.Link href target rel>
    <span className={`hover:text-primary` ++ className->Option.getWithDefault("")}>
      {children}
    </span>
  </Next.Link>
}
