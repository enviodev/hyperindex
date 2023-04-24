module PrimaryButton = {
  @react.component
  let make = (~children) => {
    <button
      className="rounded m-2 px-6 py-4 text-xl font-bold bg-gradient-to-r from-primary to-secondary">
      {children}
    </button>
  }
}

module InversePrimaryButton = {
  @react.component
  let make = (~children) => {
    <button className="rounded m-2 px-6 py-4 text-xl font-bold bg-transparent border-2">
      <span
        className="bg-gradient-to-r from-primary to-secondary inline-block text-transparent bg-clip-text">
        {children}
      </span>
    </button>
  }
}
