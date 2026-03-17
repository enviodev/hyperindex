// Runtime proxy that intercepts property access on block/transaction objects.
// Throws a friendly error when the user accesses a field that was not included in field_selection.

type proxy<'a> = 'a

let makeFieldSelectionProxy: (
  'raw,
  ~selectedFields: Js.Dict.t<bool>,
  ~entityType: string,
  ~eventName: string,
) => proxy<'result> = %raw(`function(raw, selectedFields, entityType, eventName) {
  return new Proxy(raw, {
    get(target, prop, receiver) {
      if (typeof prop === 'symbol' || prop === 'toJSON' || prop === 'constructor' || prop === 'valueOf' || prop === 'toString') {
        return Reflect.get(target, prop, receiver);
      }
      if (selectedFields[prop]) {
        return Reflect.get(target, prop, receiver);
      }
      throw new Error(
        "Accessing " + entityType + '."' + prop + '" requires adding "' + prop + '" to field_selection.' + entityType + '_fields for the event "' + eventName + '" in config.yaml.\n' +
        "See: https://docs.envio.dev/docs/configuration-file#field-selection"
      );
    }
  });
}`)

let makeBlockHandlerProxy: 'raw => proxy<'result> = %raw(`function(raw) {
  return new Proxy(raw, {
    get(target, prop, receiver) {
      if (typeof prop === 'symbol' || prop === 'toJSON' || prop === 'constructor' || prop === 'valueOf' || prop === 'toString') {
        return Reflect.get(target, prop, receiver);
      }
      if (prop === 'number' || prop === 'height' || prop === 'slot') {
        return Reflect.get(target, prop, receiver);
      }
      throw new Error(
        'Accessing block."' + prop + '" is not yet supported for block handlers. Please reach out to the Envio team to request support for this feature.'
      );
    }
  });
}`)

// Build a lookup dict from an array of field names for O(1) access checks.
// Generic over the field name type to accept @unboxed variants (which are strings at runtime).
let makeLookupDict: array<'fieldName> => Js.Dict.t<bool> = %raw(`function(fields) {
  var dict = {};
  for (var i = 0; i < fields.length; i++) {
    dict[fields[i]] = true;
  }
  return dict;
}`)
