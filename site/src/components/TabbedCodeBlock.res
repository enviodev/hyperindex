// todo: leave as is for now consider coming back to this with an embed or something

type supportedLanguage = Javascript | Typescript | Rescript

@react.component
let make = () => {
  let (selectedLanguage, setSelectedLanguage) = React.useState(_ => Javascript)

  <div className="md:w-code-block h-code-block bg-gray-800 rounded text-white">
    <div className="flex flex-row">
      <div
        className="p-2 m-2 border border-white" onClick={_ => setSelectedLanguage(_ => Javascript)}>
        {"Javascript"->React.string}
      </div>
      <div
        className="p-2 m-2 border border-white" onClick={_ => setSelectedLanguage(_ => Typescript)}>
        {"typescript"->React.string}
      </div>
      <div
        className="p-2 m-2 border border-white" onClick={_ => setSelectedLanguage(_ => Rescript)}>
        {"Rescript"->React.string}
      </div>
    </div>
    {switch selectedLanguage {
    | Javascript => <code> {"javascript"->React.string} </code>
    | Typescript => <code> {"typescript"->React.string} </code>
    | Rescript =>
      <div>
        <code>
          {`
    Handlers.GravatarContract. registerNewGravatarHandler((~event, ~context) => {`->React.string}
        </code>
        <br />
        <code>
          {`let gravatarObject: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount: 1,
    `->React.string}
        </code>
        <br />
        <code>
          {`  
  }
   context.gravatar.insert(gravatarObject)
})`->React.string}
        </code>
      </div>
    }}
  </div>
}
