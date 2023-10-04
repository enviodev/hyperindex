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
type deferredState<'a> = Pending | Resolved('a) | Rejected(exn)

type resolveCb<'a> = 'a => unit
type rejectCb = exn => unit

type t<'a> = {
  value: ref<deferredState<'a>>,
  thenCallbacks: ref<array<'a => unit>>,
  catchCallbacks: ref<array<exn => unit>>,
  resolve: resolveCb<'a>,
  reject: rejectCb,
}

/**
internal: Takes a ref to a callbacks array, runs them and resets to an 
empty array. Note better performance might be achievable with
an optimized queue library but the expectation is that there 
should not be too many values on a callback array
*/
let runCallbacks = (val: 'a, callbacks: ref<array<'a => unit>>) => {
  open Belt
  //Run each callback
  callbacks.contents->Array.forEach(cb => cb(val))
  //set callbacks to empty
  callbacks := []
}

/**
internal: instantiates an empty deferred object
*/
let makeEmpty = () => {
  let val = ref(Pending)
  let thenCallbacks = ref([])
  let catchCallbacks = ref([])
  {
    value: val,
    thenCallbacks,
    catchCallbacks,
    resolve: res => {
      val := Resolved(res)
      res->runCallbacks(thenCallbacks)
    },
    reject: exn => {
      val := Rejected(exn)
      exn->runCallbacks(catchCallbacks)
    },
  }
}

type deferredConstructor<'a> = (resolveCb<'a>, rejectCb) => unit
/**
Instantiates a deferred callback with a resolve and reject hook as 
parameters
*/
let make = (constructorFn: deferredConstructor<'a>): t<'a> => {
  let deferred = makeEmpty()

  //Set timeout will use the macro task queue and deprioritise the callback on
  //the event loop. Applies to browser and NodeJs
  Js.Global.setTimeout(() => {
    constructorFn(val => deferred.resolve(val), exn => deferred.reject(exn))
  }, 0)->ignore

  deferred
}

/**
Takes a deferred object and runs the given callback on
resolve
*/
let thenResolve = (self: t<'a>, cb: 'a => 'b): t<'b> => {
  let deferred = makeEmpty()

  let handleVal = val => {
    let cbVal = cb(val)
    deferred.resolve(cbVal)
  }

  switch self.value.contents {
  | Resolved(val) => val->handleVal
  | Rejected(exn) => deferred.reject(exn)
  | Pending => self.thenCallbacks.contents->Js.Array2.push(handleVal)->ignore
  }

  deferred
}

/**
Takes a deferred object and runs the given callback on
catch. Callback must return a deferred object.
*/
let catch = (self: t<'a>, cb: exn => t<'a>): t<'a> => {
  switch self.value.contents {
  | Resolved(_) => self
  | Rejected(exn) => cb(exn)
  | Pending =>
    let deferred = makeEmpty()
    let handleExn = exn => {
      cb(exn)->thenResolve(val => deferred.resolve(val))->ignore
    }
    self.catchCallbacks.contents->Js.Array2.push(handleExn)->ignore
    deferred
  }
}

/**
Instantiates a deferred object that is immediately resolved
*/
let resolve = val => {
  let deferred = makeEmpty()
  deferred.resolve(val)
  deferred
}

/**
Instantiates a deferred object that is immediately rejected
*/
let reject = exn => {
  let deferred = makeEmpty()
  deferred.reject(exn)
  deferred
}

/**
Takes an array of deferred objects, waits for them to
resolve and returns a single deferred object with the
an array of the resolved values
*/
let all = (defs: array<t<'a>>): t<array<'a>> => {
  //The returned deferred object
  let deferred = makeEmpty()
  //The array of vals that will be resolved once populated
  let vals = []
  open Belt

  //Use while loop for the ability to break out of a
  //loop early
  let currentIndex = ref(0)

  let rec pollForNewVals = () => {
    //loop break value
    let breakLoop = ref(false)
    while !breakLoop.contents {
      switch defs[currentIndex.contents] {
      //In the case that there is none at the current index
      //We are at the end of the array and we can resolve vals
      //and break out of the loop
      | None =>
        deferred.resolve(vals)
        breakLoop := true
      //In the event of an item present we take action based on
      //its status
      | Some(item) =>
        //Function to add a value to the the vals array and increment
        //the index for the loop
        let itemResolveCb = val => {
          vals->Js.Array2.push(val)->ignore
          currentIndex := currentIndex.contents + 1
        }
        switch item.value.contents {
        //If it is resolved, add the value and continue
        //the loop
        | Resolved(val) => itemResolveCb(val)
        //If it is pending, add a callback to the deferred object
        //that will add the value to the array and then recurse
        //break out of the loop since the callback will start the loop
        //again
        | Pending =>
          item
          ->thenResolve(val => {
            itemResolveCb(val)
            pollForNewVals()
          })
          ->ignore
          breakLoop := true
        //If it's rejected end early and reject with the exn
        //on the deferred item
        | Rejected(exn) =>
          deferred.reject(exn)
          breakLoop := true
        }
      }
    }
  }

  //Start the loop through the values
  pollForNewVals()

  deferred
}

/**
Acts like a map function but instead defers each callback and returns a deferred object
of the mapped array
*/
let mapArrayDeferred = (arr: array<'a>, cb: 'a => deferredConstructor<'b>): t<array<'b>> => {
  arr
  ->Belt.Array.map(item => {
    let const = cb(item)

    make(const)
  })
  ->all
}

/**
Converts a deferred object into a promise
*/
let asPromise = (self: t<'a>): promise<'a> => {
  Promise.make((res, rej) => {
    self
    ->thenResolve(val => {
      res(. val)
    })
    ->catch(exn => {
      rej(. exn)
      reject(exn)
    })
    ->ignore
  })
}
