open Typography

module Shipping = {
  @react.component
  let make = () => {
    <section className="w-full flex flex-col justify-center items-center">
      <Heading2> {"Take your shipping to the next level."->React.string} </Heading2>
      <BigParagraph className="text-center max-w-50p">
        {"Index and query custom smart contracts in real time. Get the best performance and developer experience. Build the ultimate Web3 app."->React.string}
      </BigParagraph>
    </section>
  }
}

module OneCommand = {
  @react.component
  let make = () => {
    <section className="w-full flex flex-col justify-center items-center">
      <Heading2> {"One command run. One command deploy."->React.string} </Heading2>
      <BigParagraph className="text-center max-w-50p">
        {"Deploy a simple indexer in two steps. Easily add complexity to build a powerful back end for your Web3 app. "->React.string}
      </BigParagraph>
    </section>
  }
}

module Customisable = {
  @react.component
  let make = () => {
    <section className="w-full flex flex-col justify-center items-center">
      <Heading2> {"Customisable. Reliable. Scalable."->React.string} </Heading2>
      <BigParagraph className="text-center max-w-50p">
        {"Minimise the time you spend on infrastructure and maintenance.
Focus on building something incredible."->React.string}
      </BigParagraph>
    </section>
  }
}
