open Typography

@react.component
let make = () => {
  <section className="w-full text-center  flex flex-col justify-center items-center">
    <Heading2> {"By builders. For builders"->React.string} </Heading2>
    <BigParagraph className="m-2 md:max-w-50p">
      {"Float Shipping has been building blockchain indexers since DeFi began.
        Envio was initially designed to power high speed trading in Float."->React.string}
    </BigParagraph>
    <div className="flex flex-row justify-center items-center my-6">
      <BigParagraph className=" m-2 text-right">
        {"Visit the testnet deployment of"->React.string}
      </BigParagraph>
      <div className={"relative mr-auto"}>
        <Hyperlink href=Routes.floatTestnet openInNewTab=true>
          <div className={"relative h-[80px] w-[200px] mr-auto"}>
            <Next.Image
              src={Routes.cdnFolderRoute(
                ~asset=`/envio/builders/float-${LightDarkModeToggle.useModeUrlVariant()}.svg`,
              )}
              layout=#fill
              objectFit="contain"
            />
          </div>
        </Hyperlink>
      </div>
    </div>
    //     <BigParagraph className="m-2 md:max-w-50p md:px-10">
    //       {"Envio is built by Float Shipping. We’ve worked on indexers since DeFi began.
    // Our tech has indexed data for:"->React.string}
    //     </BigParagraph>
    // <div className="max-w-6xl w-full grid grid-cols-2 md:grid-cols-5 gap-4 md:gap-8 p-10 md:p-24">
    //   <div style={ReactDOM.Style.make(~paddingTop="100%", ())} className={"relative"}>
    //     <Next.Image
    //       src={Routes.cdnFolderRoute(
    //         ~asset=`/envio/builders/float-${LightDarkModeToggle.useModeUrlVariant()}.svg`,
    //       )}
    //       layout=#fill
    //       objectFit="contain"
    //     />
    //   </div>
    //   <div style={ReactDOM.Style.make(~paddingTop="100%", ())} className={"relative"}>
    //     <Next.Image
    //       src={Routes.cdnFolderRoute(
    //         ~asset=`/envio/builders/safe-${LightDarkModeToggle.useModeUrlVariant()}.svg`,
    //       )}
    //       layout=#fill
    //       objectFit="contain"
    //     />
    //   </div>
    //   <div style={ReactDOM.Style.make(~paddingTop="100%", ())} className={"relative"}>
    //     <Next.Image
    //       src={Routes.cdnFolderRoute(
    //         ~asset=`/envio/builders/arweave-${LightDarkModeToggle.useModeUrlVariant()}.svg`,
    //       )}
    //       layout=#fill
    //       objectFit="contain"
    //     />
    //   </div>
    //   <div style={ReactDOM.Style.make(~paddingTop="100%", ())} className={"relative"}>
    //     <Next.Image
    //       src={Routes.cdnFolderRoute(
    //         ~asset=`/envio/builders/skale-${LightDarkModeToggle.useModeUrlVariant()}.svg`,
    //       )}
    //       layout=#fill
    //       objectFit="contain"
    //     />
    //   </div>
    //   <div style={ReactDOM.Style.make(~paddingTop="100%", ())} className={"relative"}>
    //     <Next.Image
    //       src={Routes.cdnFolderRoute(
    //         ~asset=`/envio/builders/pooltogether-${LightDarkModeToggle.useModeUrlVariant()}.svg`,
    //       )}
    //       layout=#fill
    //       objectFit="contain"
    //     />
    //   </div>
    // </div>
  </section>
}
