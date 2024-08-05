open Belt
open Ink
module Message = {
  @react.component
  let make = (~message: CustomHooks.InitApi.message) => {
    <Text color={message.color->CustomHooks.InitApi.toTheme}>
      {message.content->React.string}
    </Text>
  }
}

module Notifications = {
  @react.component
  let make = (~children) => {
    <>
      <Newline />
      <Text bold=true> {"Notifications:"->React.string} </Text>
      {children}
    </>
  }
}

@react.component
let make = (~config) => {
  let messages = CustomHooks.useMessages(~config)
  <>
    {switch messages {
    | Data([]) | Loading => React.null //Don't show anything while loading or no messages
    | Data(messages) =>
      <Notifications>
        {messages
        ->Array.mapWithIndex((i, message) => {<Message key={i->Int.toString} message />})
        ->React.array}
      </Notifications>
    | Err(_) =>
      <Notifications>
        <Message message={color: Danger, content: "Failed to load messages from envio server"} />
      </Notifications>
    }}
  </>
}
