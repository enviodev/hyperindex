@react.component
let make = () => {
  <FullWidthImage
    src={Routes.cdnFolderRoute(
      ~asset=`/envio/landing/footer-hero-${LightDarkModeToggle.useModeUrlVariant()}.png`,
    )}
  />
}
