type investorLogo = {
  name: string,
  imgName: string,
  imageFormat: string,
  objectFit: string,
  extraClassNames: string,
}

let investors = [
  {
    name: "Ideo CoLab Ventures",
    imgName: "ideo_colab",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "mx-4",
  },
  {
    name: "Maven11 Capital",
    imgName: "maven_11",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "",
  },
  {
    name: "Meta Cartel",
    imgName: "meta_cartel",
    imageFormat: "png",
    objectFit: "contain",
    extraClassNames: "mx-2",
  },
  {
    name: "Paribu Ventures",
    imgName: "paribu",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "mx-1",
  },
  {
    name: "Rabacap",
    imgName: "raba",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "",
  },
  {
    name: "Degen Score",
    imgName: "degen_score",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "mx-2",
  },
  {
    name: "Encode Club",
    imgName: "encode_club",
    imageFormat: "png",
    objectFit: "contain",
    extraClassNames: "mx-2",
  },
  {
    name: "Asensive Assets",
    imgName: "ascensive_assets",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "mx-1",
  },
  {
    name: "6th Man Ventures",
    imgName: "6th_man_ventures",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "mx-4",
  },
  {
    name: "Keychain Capital",
    imgName: "keychain_capital",
    imageFormat: "png",
    objectFit: "contain",
    extraClassNames: "",
  },
  {
    name: "Contango Digital Assets",
    imgName: "contango_digital_assets",
    imageFormat: "png",
    objectFit: "contain",
    extraClassNames: "",
  },
  {
    name: "Daedalus",
    imgName: "daedalus",
    imageFormat: "png",
    objectFit: "contain",
    extraClassNames: "",
  },
  {
    name: "Morning Star Ventures",
    imgName: "morning_star_ventures",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "",
  },
  {
    name: "CVVC",
    imgName: "cvvc",
    imageFormat: "svg",
    objectFit: "contain",
    extraClassNames: "mx-6",
  },
]

let twRoundedSizeToRem = size =>
  switch size {
  | "rounded-xl" => "0.75rem"
  | "rounded-lg" => "0.5rem"
  | "rounded-md" => "0.375rem"
  | "rounded"
  | _ => "0.25rem"
  }
@react.component
let make = () => {
  let borderRadius = "rounded-xl"

  <section className="w-full flex flex-col justify-center items-center">
    <Typography.Heading2> {"Backed by the best"->React.string} </Typography.Heading2>
    <div className="max-w-6xl w-full grid grid-cols-2 md:grid-cols-5 gap-8 p-24">
      {investors
      ->Array.mapWithIndex((i, investor) => {
        let imagePath = Routes.cdnFolderRoute(
          ~asset="/envio/investors/" ++
          investor.imgName ++
          `-${LightDarkModeToggle.useModeUrlVariant()}.` ++
          investor.imageFormat,
        )

        imagePath->Js.log
        <div
          key={i->Int.toString}
          className={borderRadius ++ " relative " ++ investor.extraClassNames}
          style={ReactDOM.Style.make(~paddingTop="100%", ())}>
          <Next.Image
            src={Routes.cdnFolderRoute(
              ~asset="/envio/investors/" ++
              investor.imgName ++
              `-${LightDarkModeToggle.useModeUrlVariant()}.` ++
              investor.imageFormat,
            )}
            layout=#fill
            objectFit=investor.objectFit
            style={ReactDOM.Style.make(~borderRadius=borderRadius->twRoundedSizeToRem, ())}
          />
        </div>
      })
      ->React.array}
    </div>
  </section>
}
