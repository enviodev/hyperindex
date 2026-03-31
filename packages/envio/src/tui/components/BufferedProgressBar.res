open Ink
open Belt
@react.component
let make = (~loaded, ~buffered=?, ~outOf, ~barWidth=36, ~loadingColor=Style.Secondary) => {
  let maxCount = barWidth

  let loadedFraction = loaded->Int.toFloat /. outOf->Int.toFloat
  let loadedCount = Pervasives.min(
    Js.Math.floor_float(maxCount->Js.Int.toFloat *. loadedFraction)->Belt.Float.toInt,
    maxCount,
  )

  let bufferedCount = buffered->Option.mapWithDefault(loadedCount, buffered => {
    let bufferedFraction = buffered->Int.toFloat /. outOf->Int.toFloat
    Pervasives.min(
      Js.Math.floor_float(maxCount->Js.Int.toFloat *. bufferedFraction)->Belt.Float.toInt,
      maxCount,
    )
  })
  let loadedFraction = loadedFraction > 0.0 ? loadedFraction : 0.0
  let loadedPercentageStr = (loadedFraction *. 100.)->Int.fromFloat->Int.toString ++ "% "

  let loadedPercentageStrCount = loadedPercentageStr->String.length
  let loadedSpaces = Pervasives.max(loadedCount - loadedPercentageStrCount, 0)
  let loadedCount = Pervasives.max(loadedCount, loadedPercentageStrCount)
  let bufferedCount = Pervasives.max(bufferedCount, loadedCount)

  <Box>
    <Text backgroundColor={loadingColor} color={Gray}>
      <Text> {" "->Js.String2.repeat(loadedSpaces)->React.string} </Text>
      <Text> {loadedPercentageStr->React.string} </Text>
    </Text>
    <Text backgroundColor={Gray}>
      {" "->Js.String2.repeat(bufferedCount - loadedCount)->React.string}
    </Text>
    <Text backgroundColor={White}>
      {" "->Js.String2.repeat(maxCount - bufferedCount)->React.string}
    </Text>
  </Box>
}
