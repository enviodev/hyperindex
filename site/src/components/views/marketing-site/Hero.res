open Typography
open Buttons

@react.component
let make = () => {
  <section
    className="max-w-7xl mx-auto h-80-percent-screen flex flex-row justify-center items-center my-10">
    <div>
      <Heading1 className="uppercase leading-normal">
        {"Build"->React.string}
        <span className="text-7xl"> {` bigger.`->React.string} </span>
        <br />
        {"Ship faster."->React.string}
      </Heading1>
      <BigParagraph className="text-left">
        {"Write custom APIs to connect your
front end to any EVM blockchain. "->React.string}
      </BigParagraph>
      <div className="flex flex-col md:flex-row justify-start my-4">
        <PrimaryButton className="ml-0"> {"Start shipping"->React.string} </PrimaryButton>
      </div>
    </div>
    <div className="h-full w-full relative flex justify-right items-center">
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
