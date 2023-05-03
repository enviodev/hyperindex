@react.component
let make = () => {
  <FullWidthImage
    src={Routes.cdnFolderRoute(
      ~asset=`/envio/landing/sailer-ape-${LightDarkModeToggle.useModeUrlVariant()}.png`,
    )}
  />
}
