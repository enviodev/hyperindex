module PrimaryButton = {
  @react.component
  let make = (~children, ~className=?, ~disabled=false, ~onClick=_ => ()) => {
    <button
      onClick
      disabled
      className={`${Styles.bgAnimate["background-animate"]} rounded m-2 px-6 py-4 text-xl font-bold bg-gradient-to-r from-primary to-secondary ` ++
      className->Option.getWithDefault("")}>
      {children}
    </button>
  }
}

module InversePrimaryButton = {
  @react.component
  let make = (~children, ~className=?, ~disabled=false, ~onClick=_ => ()) => {
    <button
      onClick
      disabled
      className={` rounded m-2 px-6 py-4 text-xl font-bold bg-transparent border-2`}>
      <span
        className={`${Styles.bgAnimate["background-animate"]}  bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text ` ++
        className->Option.getWithDefault("")}>
        {children}
      </span>
    </button>
  }
}
