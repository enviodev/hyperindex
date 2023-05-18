// Dev tip: Make sure the encapsulating component has a 'relative' className
module Layover = {
  @react.component
  let make = (~contentComponent=React.null, ~hoverComponent=<span />) =>
    <span className={Styles.generalStyles["has-tooltip"]}>
      <span
        className={`text-xs w-full h-full ${Styles.generalStyles["tooltip"]} rounded p-6 bg-gray-100 opacity-90 font-default font-normal`}>
        {contentComponent}
      </span>
      {hoverComponent}
    </span>
}

type toolTipPosition = Top | TopRight | TopLeft | Bottom | BottomRight | BottomLeft | Left | Right

@react.component
let make = (
  ~tip="",
  ~contentComponent=React.null,
  ~hoverComponent=<span className="text-xs cursor-default"> {`ℹ️`->React.string} </span>,
  ~position: toolTipPosition=Top,
  ~children=React.null,
) => {
  let positionStyle = switch position {
  | Top => "bottom-[150%] left-1/2 -translate-x-1/2"
  | TopLeft => "bottom-[100%] right-[50%] -translate-y-[1rem] "
  | TopRight => "bottom-[100%] left-[50%] -translate-y-[1rem] "
  | Bottom => "top-[150%] left-1/2 -translate-x-1/2"
  | BottomLeft => "top-[100%] right-[50%] translate-y-[1rem]"
  | BottomRight => "top-[100%] left-[50%] translate-y-[1rem]"
  | Left => "right-[100%] top-1/2 -translate-y-1/2 -translate-x-[1rem]"
  | Right => "left-[100%] top-1/2 -translate-y-1/2 translate-x-[1rem]"
  }

  let tipParagraphArray = React.useMemo1(() => {
    let tipWordsArray = tip->Js.String2.split(" ")
    let tipArray = []

    while tipWordsArray->Array.length > 0 {
      let tenWordArr = tipWordsArray->Js.Array2.spliceInPlace(~pos=0, ~remove=8, ~add=[])
      let tenWordSentence = tenWordArr->Array.joinWith(" ", word => word)
      tipArray->Js.Array2.push(tenWordSentence)->ignore
    }
    tipArray
  }, [tip])

  <span className={Styles.generalStyles["has-tooltip"] ++ " relative"}>
    <span
      className={`text-xs ${Styles.generalStyles["tooltip"]} whitespace-nowrap text-left  p-4 border border-gray-900 rounded p-1 bg-gray-100 opacity-90 font-default font-normal ${positionStyle}`}>
      {tipParagraphArray
      ->Array.mapWithIndex((index, tipParagraph) => {
        <p key={index->Int.toString}> {tipParagraph->React.string} </p>
      })
      ->React.array}
      {contentComponent}
    </span>
    {children}
    {hoverComponent}
  </span>
}
