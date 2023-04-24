module Heading1 = {
  @react.component
  let make = (~children) => {
    <h1
      className="m-4 font-bold text-5xl bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text">
      {children}
    </h1>
  }
}

module Heading2 = {
  @react.component
  let make = (~children) => {
    <h2
      className="m-4 font-bold text-4xl bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text">
      {children}
    </h2>
  }
}

module Paragraph = {
  @react.component
  let make = (~children) => {
    <p className="font-bold text-xl text-white"> {children} </p>
  }
}
