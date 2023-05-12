module Heading2 = {
  @react.component
  let make = (~children) => {
    <h2
      className="font-bold text-3xl bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text">
      {children}
    </h2>
  }
}
