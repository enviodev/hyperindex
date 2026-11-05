// How often a HyperSync source is asked for the height while nothing is pushing
// one. Every ecosystem's client talks to the same service, so they wait alike.
let pollingInterval: int

// Every HyperSync-backed source needs a token to reach the service, so a
// missing one fails at construction with the message that says how to get one,
// rather than as a 401 per request.
let requireApiToken: option<string> => string
