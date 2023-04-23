@react.component
let make = (~children) => {
  <div className={`flex lg:justify-center min-h-screen`}>
    <div className="w-full font-base">
      <div className="flex flex-col h-screen">
        // Banner goes here
        <div className="m-auto  w-full"> {children} </div>
      </div>
    </div>
    //  absolute always visible components go here
  </div>
}
