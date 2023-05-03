@module
external generalStyles: {
  "custom-cursor": string,
  "logo-container": string,
  "screen-centered-container": string,
  "v-align-in-responsive-height": string,
  "loader": string,
  "tooltip": string,
  "has-tooltip": string,
  "toggle__dot": string,
  "pixel": string,
  "blurry-text-black": string,
  "blurry-text-white": string,
} = "../../../styles/general-styles.module.css"

@module
external floatingMenuZoomStyle: {
  "floating-menu": string,
  "should-display": string,
  "zoom-in-effect": string,
  "should-display-zoom-in-effect": string,
} = "../../../styles/floating-menu-zoom-style.module.css"

external imageStyles: {"disable-anti-aliasing": string} = "../../../styles/image.module.css"

@module
external overrides: {"zero-padding-important": string, "zero-margin-important": string} =
  "../../../styles/overrides.module.css"
