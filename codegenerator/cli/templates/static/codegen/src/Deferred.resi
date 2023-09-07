/**
This module is to help defer callbacks that are low priority
to help with unblocking the event loop on large iterations for example.

The aim is to have an interface like a promise but instead of
placing callbacks on the micro task queue along with promise 
callbacks it will get placed on the macro task queue where the
event loop will prioritise promise callback and deprioritise 
callbacks created instantiated with a "Deferred" object

It uses a setTimeout callback to make the behaviour consistent across
runtimes (NodeJs, browser etc.) as opposed to setImmediate, nextTick 
which are placed at different orders in the event loop on different
runtimes
*/
/**
An object similar to a promise that helps interface with a callback
that gets deferred to the macro task queue
*/
type t<'a>
type resolveCb<'a> = 'a => unit
type rejectCb = exn => unit
type deferredConstructor<'a> = (resolveCb<'a>, rejectCb) => unit

/**
Instantiates a deferred callback with a resolve and reject hook as 
parameters
*/
let make: deferredConstructor<'a> => t<'a>

/**
Takes a deferred object and runs the given callback on
resolve
*/
let thenResolve: (t<'a>, 'a => 'b) => t<'b>

/**
Takes a deferred object and runs the given callback on
catch. Callback must return a deferred object.
*/
let catch: (t<'a>, exn => t<'a>) => t<'a>

/**
Instantiates a deferred object that is immediately resolved
*/
let resolve: 'a => t<'a>

/**
Instantiates a deferred object that is immediately rejected
*/
let reject: exn => t<'a>

/**
Takes an array of deferred objects, waits for them to
resolve and returns a single deferred object with the
an array of the resolved values
*/
let all: array<t<'a>> => t<array<'a>>

/**
Acts like a map function but instead defers each callback and returns a deferred object
of the mapped array
*/
let mapArrayDeferred: (array<'a>, 'a => deferredConstructor<'b>) => t<array<'b>>

/**
Converts a deferred object into a promise
*/
let asPromise: t<'a> => promise<'a>
