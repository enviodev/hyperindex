module Home = {
  @react.component
  let make = () => {
    let isAlreadyAUser = false // todo logic will go here if is an exsiting user to take them to the login screen or directly to their dashboard if they are connected/logged in

    switch isAlreadyAUser {
    | true => <p className="uppercase"> {"dashboard / login"->React.string} </p>
    | false => <MarketingSite />
    }
  }
}

let default = () => <Home />
