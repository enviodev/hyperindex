module ApeHeroImage = {
  @react.component
  let make = () => {
    <FullWidthImage
      src={Routes.cdnFolderRoute(
        ~asset=`/envio/landing/sailer-ape-${LightDarkModeToggle.useModeUrlVariant()}.png`,
      )}
    />
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
