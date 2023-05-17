type contract

@module("./setupNodeAndContracts.js")
external setupNodeAndContracts: contract => Promise.t<unit> = "default"

@module("./setupNodeAndContracts.js")
external deployContract: unit => Promise.t<contract> = "deployContract"
