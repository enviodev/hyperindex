open Ink
open Belt
@react.component
let make = (~loaded, ~buffered=?, ~outOf, ~barWidth=36, ~loadingColor=Style.Secondary) => {
  let maxCount = barWidth

  let loadedFraction = loaded->Int.toFloat /. outOf->Int.toFloat
  let loadedCount = Pervasives.min(
    Math.floor(maxCount->Int.toFloat *. loadedFraction)->Belt.Float.toInt,
    maxCount,
  )

  let bufferedCount = buffered->Option.mapWithDefault(loadedCount, buffered => {
    let bufferedFraction = buffered->Int.toFloat /. outOf->Int.toFloat
    Pervasives.min(
      Math.floor(maxCount->Int.toFloat *. bufferedFraction)->Belt.Float.toInt,
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
      <Text> {" "->String.repeat(loadedSpaces)->React.string} </Text>
      <Text> {loadedPercentageStr->React.string} </Text>
    </Text>
    <Text backgroundColor={Gray}>
      {" "->String.repeat(bufferedCount - loadedCount)->React.string}
    </Text>
    <Text backgroundColor={White}>
      {" "->String.repeat(maxCount - bufferedCount)->React.string}
    </Text>
  </Box>
}
