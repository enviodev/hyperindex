open Style

type instance = {
  rerender: React.element => unit,
  unmount: unit => unit,
  waitUntilExit: unit => promise<unit>,
  clear: unit => unit,
}
type readableStream
type writableStream
type options = {
  stdout?: writableStream,
  stdin?: readableStream,
  exitOnCtrlC?: bool,
  patchConsole?: bool,
  debug?: bool,
}
@module("ink")
external renderInternal: (React.element, ~options: option<options>) => instance = "render"

let render = (~options=?, element) => {
  renderInternal(element, ~options)
}
type measurement = {width: int, height: int}

@module("ink")
external measureElement: React.ref<'a> => measurement = "measureElement"

module Text = {
  type wrapOptions =
    | @as("wrap") Wrap
    | @as("truncate") Truncate
    | @as("truncate-start") TruncateStart
    | @as("truncate-middle") TruncateMiddle
    | @as("truncate-end") TruncateEnd
  @module("ink") @react.component
  external make: (
    ~children: React.element,
    ~color: chalkTheme=?,
    ~backgroundColor: chalkTheme=?,
    ~dimColor: bool=?,
    ~bold: bool=?,
    ~italic: bool=?,
    ~underline: bool=?,
    ~strikethrough: bool=?,
    ~inverse: bool=?,
    ~wrap: wrapOptions=?,
  ) => React.element = "Text"
}

module Box = {
  @module("ink") @react.component
  external make: (
    ~children: React.element=?,
    ~width: numOrStr=?,
    ~height: numOrStr=?,
    ~minWidth: int=?,
    ~minHeight: int=?,
    ~padding: int=?,
    ~paddingTop: int=?,
    ~paddingBottom: int=?,
    ~paddingLeft: int=?,
    ~paddingRight: int=?,
    ~paddingX: int=?,
    ~paddingY: int=?,
    ~margin: int=?,
    ~marginTop: int=?,
    ~marginBottom: int=?,
    ~marginLeft: int=?,
    ~marginRight: int=?,
    ~marginX: int=?,
    ~marginY: int=?,
    ~gap: int=?,
    ~rowGap: int=?,
    ~flexGrow: int=?,
    ~flexShrink: int=?,
    ~flexBasis: numOrStr=?,
    ~flexDirection: flexDirection=?,
    ~flexWrap: flexDirection=?,
    ~alignItems: alignItems=?,
    ~alignSelf: alignSelf=?,
    ~justifyContent: justifyContent=?,
    ~display: display=?,
    ~overflow: overflow=?,
    ~overflowX: overflow=?,
    ~overflowY: overflow=?,
    ~borderStyle: borderStyle=?,
    ~borderColor: chalkTheme=?,
    ~borderTopColor: chalkTheme=?,
    ~borderRightColor: chalkTheme=?,
    ~borderBottomColor: chalkTheme=?,
    ~borderLeftColor: chalkTheme=?,
    ~borderDimColor: bool=?,
    ~borderTopDimColor: bool=?,
    ~borderRightDimColor: bool=?,
    ~borderBottomDimColor: bool=?,
    ~borderLeftDimColor: bool=?,
    ~borderTop: bool=?,
    ~borderRight: bool=?,
    ~borderBottom: bool=?,
    ~borderLeft: bool=?,
  ) => React.element = "Box"
}

module Newline = {
  /**
  Adds one or more newline characters. Must be used within <Text> components.

  */
  @module("ink")
  @react.component
  external make: (~count: int=?) => React.element = "Newline"
}

module Spacer = {
  /**
  A flexible space that expands along the major axis of its containing layout. It's useful as a shortcut for filling all the available spaces between elements.

  For example, using <Spacer> in a <Box> with default flex direction (row) will position "Left" on the left side and will push "Right" to the right side.
  */
  @module("ink")
  @react.component
  external make: unit => React.element = "Spacer"
}

module Static = {
  /**
  <Static> component permanently renders its output above everything else. It's useful for displaying activity like completed tasks or logs - things that are not changing after they're rendered (hence the name "Static").

  It's preferred to use <Static> for use cases like these, when you can't know or control the amount of items that need to be rendered.
  */
  @module("ink")
  @react.component
  external make: (
    ~children: ('a, int) => React.element,
    ~items: array<'a>,
    ~style: styles=?,
  ) => React.element = "Static"
}

module Transform = {
  /**
  Transform a string representation of React components before they are written to output. For example, you might want to apply a gradient to text, add a clickable link or create some text effects. These use cases can't accept React nodes as input, they are expecting a string. That's what <Transform> component does, it gives you an output string of its child components and lets you transform it in any way.

  Note: <Transform> must be applied only to <Text> children components and shouldn't change the dimensions of the output, otherwise layout will be incorrect.
  */
  type outputLine = string
  type index = int
  @module("ink") @react.component
  external make: (
    ~children: string,
    ~tranform: (outputLine, index) => string,
    ~index: int=?,
  ) => React.element = "Transform"
}

module Hooks = {
  type key = {
    leftArrow: bool,
    rightArrow: bool,
    upArrow: bool,
    downArrow: bool,
    return: bool,
    escape: bool,
    ctrl: bool,
    shift: bool,
    tab: bool,
    backspace: bool,
    delete: bool,
    pageDown: bool,
    pageUp: bool,
    meta: bool,
  }
  type input = string
  type inputHandler = (input, key) => unit
  type options = {isActive?: bool}

  @module("ink") external useInput: (inputHandler, ~options: options=?) => unit = "useInput"

  type app = {exit: (~err: exn=?) => unit}
  @module("ink") external useApp: unit => app = "useApp"

  type stdin = {
    stdin: readableStream,
    isRawModeSupported: bool,
    setRawMode: bool => unit,
  }

  @module("ink") external useStdin: unit => stdin = "useStdin"

  type stdout = {
    stdout: writableStream,
    write: string => unit,
  }

  @module("ink") external useStdout: unit => stdout = "useStdout"

  type stderr = {
    stderr: writableStream,
    write: string => unit,
  }

  @module("ink") external useStderr: unit => stderr = "useStderr"

  type focusOptions = {autoFocus?: bool, isActive?: bool, id?: string}
  type focus = {isFocused: bool}
  @module("ink") external useFocus: (~options: focusOptions=?) => focus = "useFocus"

  type focusManager = {
    enableFocus: unit => unit,
    disableFocus: unit => unit,
    focusNext: unit => unit,
    focusPrevious: unit => unit,
    focusId: string => unit,
  }
  @module("ink")
  external useFocusManager: unit => focusManager = "useFocusManager"
}

module Link = {
  /**
  Transform a string representation of React components before they are written to output. For example, you might want to apply a gradient to text, add a clickable link or create some text effects. These use cases can't accept React nodes as input, they are expecting a string. That's what <Transform> component does, it gives you an output string of its child components and lets you transform it in any way.

  Note: <Transform> must be applied only to <Text> children components and shouldn't change the dimensions of the output, otherwise layout will be incorrect.
  */
  type outputLine = string
  type index = int
  @module("ink-link") @react.component
  external make: (~children: React.element=?, ~url: string, ~fallback: bool=?) => React.element =
    "default"
}
