open Typography
open Buttons

@react.component
let make = () => {
  <section className="flex flex-col justify-center items-center">
    <Heading2> {"Ship with us"->React.string} </Heading2>
    <Paragraph>
      {"Build with Envio, build with us. Join our community of elite
shippers and get hands on support from the core team."->React.string}
    </Paragraph>
    <div className="flex flex-row m-4">
      <PrimaryButton> {"Read the docs"->React.string} </PrimaryButton>
      <InversePrimaryButton> {"Join the Discord"->React.string} </InversePrimaryButton>
    </div>
  </section>
}
