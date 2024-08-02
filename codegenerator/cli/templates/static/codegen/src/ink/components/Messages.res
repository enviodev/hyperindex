open Belt
open Ink
module Message = {
  @react.component
  let make = (~message: CustomHooks.InitApi.message) => {
    <Text
      color={switch message.kind {
      | Warning => Secondary
      | Info => Info
      | Destructive => Danger
      }}>
      {message.content->React.string}
    </Text>
  }
}

@react.component
let make = (~config) => {
  let messages = CustomHooks.useMessages(~config)
  <>
    {switch messages {
    | Data(messages) =>
      <>
        {messages
        ->Array.mapWithIndex((i, message) => {<Message key={i->Int.toString} message />})
        ->React.array}
      </>
    | Loading => React.null //Don't show anything while loading
    | Err(_) =>
      <Message message={kind: Destructive, content: "Failed to load messages from envio server"} />
    }}
  </>
}
