open Typography

@react.component
let make = () => {
  <section className="flex flex-col">
    <div className="my-4 relative flex flex-row justify-center items-center">
      <div
        className="h-60-percent-screen w-full mx-auto text-center md:text-left max-w-6xl flex flex-col md:flex-row justify-between items-center">
        <TabbedCodeBlock />
        <div className="justify-right w-full md:w-40-percent text-right">
          <BigParagraph className="text-3xl my-4">
            {"Write code you know"->React.string}
          </BigParagraph>
          <BigParagraph className="font-thin">
            {"Ship faster in a familiar language. Use  Javascript, Typescript or Rescript."->React.string}
          </BigParagraph>
        </div>
      </div>
    </div>
    <div className="my-4 relative flex flex-row justify-center items-center">
      <div
        className="h-60-percent-screen w-full mx-auto text-center md:text-left max-w-6xl flex flex-col md:flex-row justify-between items-center">
        <div className="justify-left w-full md:w-40-percent">
          <BigParagraph className="text-3xl my-4">
            {"Minimal maintenance"->React.string}
          </BigParagraph>
          <BigParagraph className="font-thin">
            {"Generate automated backups and tests. Get real time notifications, analytics and error logs. Never worry about runtime errors."->React.string}
          </BigParagraph>
        </div>
        <div
          className="h-40 md:h-undersized w-full md:w-half relative flex justify-right items-center">
          <Next.Image
            src={Routes.cdnFolderRoute(
              ~asset=`/envio/landing/usp-diver-${LightDarkModeToggle.useModeUrlVariant()}.png`,
            )}
            layout=#fill
            objectPosition="right"
            objectFit="contain"
          />
        </div>
      </div>
    </div>
    <div className="my-4 relative flex flex-row justify-center items-center">
      <div
        className="h-60-percent-screen w-full mx-auto text-center md:text-left max-w-6xl flex flex-col md:flex-row justify-between items-center">
        <div
          className="h-40 md:h-undersized w-full md:w-half relative flex justify-left items-center">
          <Next.Image
            src={Routes.cdnFolderRoute(
              ~asset=`/envio/landing/usp-jellyfish-couple-${LightDarkModeToggle.useModeUrlVariant()}.png`,
            )}
            layout=#fill
            objectPosition="left"
            objectFit="contain"
          />
        </div>
        <div className="justify-right w-full md:w-40-percent text-right">
          <BigParagraph className="text-3xl my-4"> {"Sync Quickly"->React.string} </BigParagraph>
          <BigParagraph className="font-thin">
            {"Test, troubleshoot and iterate quickly with high speed historical data syncing. "->React.string}
          </BigParagraph>
        </div>
      </div>
    </div>
  </section>
}
