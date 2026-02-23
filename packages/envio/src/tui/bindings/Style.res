type chalkTheme =
  | @as("#9860E5") Primary
  | @as("#FFBB2F") Secondary
  | @as("#6CBFEE") Info
  | @as("#FF8269") Danger
  | @as("#3B8C3D") Success
  | @as("white") White
  | @as("gray") Gray

@unboxed type numOrStr = Num(int) | Str(string)

type textWrap =
  | @as("wrap") Wrap
  | @as("end") End
  | @as("middle") Middle
  | @as("truncate-end") TruncateEnd
  | @as("truncate") Truncate
  | @as("truncate-middle") TruncateMiddle
  | @as("truncate-start") TruncateStart

type position =
  | @as("absolute") Absolute
  | @as("relative") Relative

type flexDirection =
  | @as("row") Row
  | @as("column") Column
  | @as("row-reverse") RowReverse
  | @as("column-reverse") ColumnReverse

type flexWrap =
  | @as("nowrap") NoWrap
  | @as("wrap") Wrap
  | @as("wrap-reverse") WrapReverse

type alignItems =
  | @as("flex-start") FlexStart
  | @as("center") Center
  | @as("flex-end") FlexEnd
  | @as("stretch") Stretch

type alignSelf =
  | @as("flex-start") FlexStartSelf
  | @as("center") CenterSelf
  | @as("flex-end") FlexEndSelf
  | @as("auto") Auto

type justifyContent =
  | @as("flex-start") JustifyFlexStart
  | @as("flex-end") JustifyFlexEnd
  | @as("space-between") SpaceBetween
  | @as("space-around") SpaceAround
  | @as("center") JustifyCenter

type display =
  | @as("flex") Flex
  | @as("none") None

type overflow =
  | @as("visible") Visible
  | @as("hidden") Hidden

type borderStyle =
  | @as("single") Single
  | @as("double") Double
  | @as("round") Round
  | @as("bold") Bold
  | @as("singleDouble") SingleDouble
  | @as("doubleSingle") DoubleSingle
  | @as("classic") Classic

type styles = {
  textWrap?: textWrap,
  position?: position,
  columnGap?: int,
  rowGap?: int,
  gap?: int,
  margin?: int,
  marginX?: int,
  marginY?: int,
  marginTop?: int,
  marginBottom?: int,
  marginLeft?: int,
  marginRight?: int,
  padding?: int,
  paddingX?: int,
  paddingY?: int,
  paddingTop?: int,
  paddingBottom?: int,
  paddingLeft?: int,
  paddingRight?: int,
  flexGrow?: int,
  flexShrink?: int,
  flexDirection?: flexDirection,
  flexBasis?: numOrStr,
  flexWrap?: flexWrap,
  alignItems?: alignItems,
  alignSelf?: alignSelf,
  justifyContent?: justifyContent,
  width?: numOrStr,
  height?: numOrStr,
  minWidth?: numOrStr,
  minHeight?: numOrStr,
  display?: display,
  borderStyle?: borderStyle,
  borderTop?: bool,
  borderBottom?: bool,
  borderLeft?: bool,
  borderRight?: bool,
  borderColor?: chalkTheme,
  borderTopColor?: chalkTheme,
  borderBottomColor?: chalkTheme,
  borderLeftColor?: chalkTheme,
  borderRightColor?: chalkTheme,
  borderDimColor?: bool,
  borderTopDimColor?: bool,
  borderBottomDimColor?: bool,
  borderLeftDimColor?: bool,
  borderRightDimColor?: bool,
  overflow?: overflow,
  overflowX?: overflow,
  overflowY?: overflow,
}
