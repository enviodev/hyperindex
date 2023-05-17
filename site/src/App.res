// This type is based on the getInitialProps return value.
// If you are using getServerSideProps or getStaticProps, you probably
// will never need this
// See https://nextjs.org/docs/advanced-features/custom-app
type pageProps

module PageComponent = {
  type t = React.component<pageProps>
}

type props = {
  @as("Component")
  component: PageComponent.t,
  pageProps: pageProps,
}

// We are not using `@react.component` since we will never
// use <App/> within our Rescript code. It's only used within `pages/_app.js`

let default = (props: props): React.element => {
  let {component, pageProps} = props

  let content = React.createElement(component, pageProps)
  // let _ = InjectedEthereum.useReloadOnMetamaskChainChanged() // todo - tag: boilerplate copy pasta

  <MiscProvider>
    <LightDarkModeToggle.LightDarkModeToggleProvider>
      <RootLayout> content </RootLayout>
    </LightDarkModeToggle.LightDarkModeToggleProvider>
  </MiscProvider>
}
