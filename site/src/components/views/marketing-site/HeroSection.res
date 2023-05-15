open Typography
open Buttons

@react.component
let make = () => {
  let router = Next.Router.useRouter()

  <section
    className="max-w-7xl mx-auto h-80-percent-screen flex flex-col md:flex-row justify-center items-center my-10">
    <div className="text-center md:text-left">
      <Heading1 className="uppercase leading-normal">
        {"Build"->React.string}
        <span className="text-7xl"> {` bigger.`->React.string} </span>
        <br />
        <span className="text-5xl md:text-6xl"> {"Ship faster."->React.string} </span>
      </Heading1>
      <BigParagraph className="md:m-0 m-2">
        {"Write custom APIs to connect your
front end to any EVM blockchain. "->React.string}
      </BigParagraph>
      <div className="my-4">
        <PrimaryButton
          className=" md:ml-0"
          onClick={_ => {
            router->Next.Router.push(Routes.gettingStarted)
          }}>
          {"Start shipping"->React.string}
        </PrimaryButton>
      </div>
    </div>
    <div className="hidden md:block h-full w-full relative flex justify-right items-center">
      <Next.Image
        src={Routes.cdnFolderRoute(
          ~asset=`/envio/landing/landing-hero-${LightDarkModeToggle.useModeUrlVariant()}.png`,
        )}
        layout=#fill
        objectFit="contain"
      />
    </div>
  </section>
}
