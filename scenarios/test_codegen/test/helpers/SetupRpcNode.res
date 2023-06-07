type gravatarContract
type deployment = {gravatar: gravatarContract}

@module("./setupNodeAndContracts.js")
external runBasicGravatarTransactions: gravatarContract => Promise.t<unit> = "default"

@module("./setupNodeAndContracts.js")
external deployContracts: unit => Promise.t<deployment> = "deployContracts"
