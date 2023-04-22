module Home = {
  @react.component
  let make = () => {
    <p> {"We're a boilerplate"->React.string} </p>
  }
}

let default = () => <Home />
