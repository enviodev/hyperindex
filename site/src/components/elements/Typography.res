module Heading1 = {
  @react.component
  let make = (~children, ~className=?) => {
    <h1
      className={"m-4 font-bold text-5xl bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text " ++
      className->Option.getWithDefault("")}>
      {children}
    </h1>
  }
}

module Heading2 = {
  @react.component
  let make = (~children, ~className=?) => {
    <h2
      className={"m-4 font-bold text-4xl bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text " ++
      className->Option.getWithDefault("")}>
      {children}
    </h2>
  }
}

// unused, may need to be edited when used
module Heading3 = {
  @react.component
  let make = (~children, ~className=?) => {
    <h2
      className={"m-4 font-bold text-2xl bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text " ++
      className->Option.getWithDefault("")}>
      {children}
    </h2>
  }
}

module Heading4 = {
  @react.component
  let make = (~children, ~className=?) => {
    <h2 className={"font-bold text-xl uppercase " ++ className->Option.getWithDefault("")}>
      {children}
    </h2>
  }
}

module BigParagraph = {
  @react.component
  let make = (~children, ~className=?) => {
    <p className={"font-bold text-2xl text-white " ++ className->Option.getWithDefault("")}>
      {children}
    </p>
  }
}

module Paragraph = {
  @react.component
  let make = (~children, ~className=?) => {
    <p className={"font-bold text-xl text-white " ++ className->Option.getWithDefault("")}>
      {children}
    </p>
  }
}
