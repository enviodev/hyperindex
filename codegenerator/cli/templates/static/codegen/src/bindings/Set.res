type t<'value>

/*
 * Constructor
 */
@ocaml.doc("Creates a new `Set` object.") @new
external make: unit => t<'value> = "Set"

@ocaml.doc("Creates a new `Set` object.") @new
external fromEntries: array<'value> => t<'value> = "Set"

/*
 * Instance properties
 */
@ocaml.doc("Returns the number of values in the `Set` object.") @get
external size: t<'value> => int = "size"

/*
 * Instance methods
 */
@ocaml.doc("Appends `value` to the `Set` object. Returns the `Set` object with added value.") @send
external add: (t<'value>, 'value) => t<'value> = "add"

@ocaml.doc("Removes all elements from the `Set` object.") @send
external clear: t<'value> => unit = "clear"

@ocaml.doc(
  "Removes the element associated to the `value` and returns a boolean asserting whether an element was successfully removed or not. `Set.prototype.has(value)` will return `false` afterwards."
)
@send
external delete: (t<'value>, 'value) => bool = "delete"

@ocaml.doc(
  "Returns a boolean asserting whether an element is present with the given value in the `Set` object or not."
)
@send
external has: (t<'value>, 'value) => bool = "has"

/*
 * Iteration methods
 */
/*
/// NOTE - if we need iteration we can add this back - currently it requires the `rescript-js-iterator` library.
@ocaml.doc(
  "Returns a new iterator object that yields the **values** for each element in the `Set` object in insertion order."
)
@send
external values: t<'value> => Js_iterator.t<'value> = "values"

@ocaml.doc("An alias for `Set.prototype.values()`.") @send
external keys: t<'value> => Js_iterator.t<'value> = "values"

@ocaml.doc("Returns a new iterator object that contains **an array of [value, value]** for each element in the `Set` object, in insertion order.

This is similar to the [Map](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Map) object, so that each entry's `key` is the same as its `value` for a `Set`.")
@send
external entries: t<'value> => Js_iterator.t<('value, 'value)> = "entries"
*/
@ocaml.doc(
  "Calls `callbackFn` once for each value present in the `Set` object, in insertion order."
)
@send
external forEach: (t<'value>, 'value => unit) => unit = "forEach"

@ocaml.doc(
  "Calls `callbackFn` once for each value present in the `Set` object, in insertion order."
)
@send
external forEachWithSet: (t<'value>, ('value, 'value, t<'value>) => unit) => unit = "forEach"
