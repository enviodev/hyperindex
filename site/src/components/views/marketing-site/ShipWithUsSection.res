open Typography
open Buttons

@react.component
let make = () => {
  let router = Next.Router.useRouter()
  <section className="flex flex-col justify-center items-center my-10">
    <Heading2 className="my-8"> {"Ship with us"->React.string} </Heading2>
    <BigParagraph className="text-center md:max-w-50p px-4 md:px-10">
      {"Build with Envio, build with us. Join our community of elite
shippers and get hands on support from the core team."->React.string}
    </BigParagraph>
    <div className="flex flex-col md:flex-row justify-evenly my-4">
      <PrimaryButton
        onClick={_ => {
          router->Next.Router.push(Routes.docs)
        }}>
        {"Read the docs"->React.string}
      </PrimaryButton>
      <div className="w-20" /> // spacer
      <InversePrimaryButton
        onClick={_ => {
          router->Next.Router.push(Routes.discord)
        }}>
        {"Join the Discord"->React.string}
      </InversePrimaryButton>
    </div>
  </section>
}
