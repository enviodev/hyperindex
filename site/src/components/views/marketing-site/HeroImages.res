module FullWidthImage = {
  @react.component
  let make = (~src) => {
    <section
      className="h-[300px] md:h-60-percent-screen my-4 relative flex justify-center items-center">
      <div className="w-full max-w-5xl flex justify-center items-center">
        <Next.Image src layout=#fill objectFit="contain" />
      </div>
    </section>
  }
}
module ApeHeroImage = {
  @react.component
  let make = () => {
    <FullWidthImage src={Routes.cdnFolderRoute(~asset=`/envio/landing/sailer-ape.png`)} />
  }
}

module CreatureHeroImage = {
  @react.component
  let make = () => {
    <FullWidthImage
      src={Routes.cdnFolderRoute(
        ~asset=`/envio/landing/ship-creatures-${LightDarkModeToggle.useModeUrlVariant()}.png`,
      )}
    />
  }
}

module FooterHeroImage = {
  @react.component
  let make = () => {
    <FullWidthImage
      src={Routes.cdnFolderRoute(
        ~asset=`/envio/landing/footer-hero-${LightDarkModeToggle.useModeUrlVariant()}.png`,
      )}
    />
  }
}
