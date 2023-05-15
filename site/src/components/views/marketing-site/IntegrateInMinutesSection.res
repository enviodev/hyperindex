open Typography
open Buttons

@react.component
let make = () => {
  let router = Next.Router.useRouter()
  <section className="flex flex-col justify-center items-center my-10">
    <Heading2 className="my-8"> {"Integrate in minutes."->React.string} </Heading2>
    <BigParagraph className="text-center md:max-w-50p m-2">
      {"Start from a template. Customise to your smart contracts. Deploy."->React.string}
    </BigParagraph>
    <div className="flex flex-col md:flex-row justify-center my-4">
      <PrimaryButton
        onClick={_ => {
          router->Next.Router.push(Routes.gettingStarted)
        }}>
        {"Try the quickstart guide"->React.string}
      </PrimaryButton>
    </div>
  </section>
}
