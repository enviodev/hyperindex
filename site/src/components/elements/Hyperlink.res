@react.component
let make = (~children, ~className=?, ~href, ~openInNewTab=?) => {
  let (target, rel) =
    openInNewTab->Option.getWithDefault(false) ? ("_blank", "noopenner noreferrer") : ("", "")
  <Next.Link href>
    <span
      // ${Styles.generalStyles["custom-cursor"]} todo: add custom cursor
      className={`hover:text-primary` ++ className->Option.getWithDefault("")}
      target
      rel>
      {children}
    </span>
  </Next.Link>
}
