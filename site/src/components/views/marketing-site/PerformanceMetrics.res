open Typography

module MetricBlock = {
  @react.component
  let make = (~aboveText, ~higlightText, ~belowText) => {
    <div className="flex flex-col my-6">
      <p> {aboveText->React.string} </p>
      <Heading2 className="ml-0 my-0 mr-0 md:max-w-max"> {higlightText->React.string} </Heading2>
      <p> {belowText->React.string} </p>
    </div>
  }
}

@react.component
let make = () => {
  <section className="flex flex-col justify-center items-center my-10 h-80-percent-screen">
    // todo min height
    <Heading2 className="my-8 text-center"> {"Unmatched performance."->React.string} </Heading2>
    <div
      className="w-full mx-auto text-center md:text-left max-w-5xl flex flex-col md:flex-row justify-center items-center">
      <div className="justify-left w-full md:w-30-percent">
        <MetricBlock aboveText="less than" higlightText="200ms" belowText="system latency" />
        <MetricBlock aboveText="guarenteed" higlightText="99.99%" belowText="uptime" />
        <MetricBlock aboveText="sync" higlightText=">50,000" belowText="blocks/second" />
      </div>
      <div
        className="h-40 md:h-oversized w-full md:w-half relative flex justify-right items-center">
        <Next.Image
          src={Routes.cdnFolderRoute(
            ~asset=`/envio/landing/performance-whale-${LightDarkModeToggle.useModeUrlVariant()}.png`,
          )}
          layout=#fill
          objectFit="contain"
        />
      </div>
    </div>
  </section>
}
