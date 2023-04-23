module Home = {
  @react.component
  let make = () => {
    <p className="uppercase"> {"We're a boilerplate"->React.string} </p>
  }
}

let default = () => <Home />
