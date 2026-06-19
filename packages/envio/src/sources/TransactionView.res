// The user-facing `event.transaction` for store-backed ecosystems. Each field
// is a getter that pulls a single value from the Rust store on first access and
// memoises it, so unread fields (notably `input`) never cross the boundary.
// `fields` is the ecosystem's ordered field list; its index is the field code
// shared with Rust (see `Evm.res` transactionFields / the Rust `EvmTxField`).

// Builds a lazily-resolving view. The prototype (one getter per field) is built
// once per `fields` array and shared across all views.
let make: (
  array<string>,
  TransactionStore.t,
  int,
  string,
) => Internal.eventTransaction = %raw(`(function () {
  var protoCache = new WeakMap();
  function getProto(fields) {
    var proto = protoCache.get(fields);
    if (proto) return proto;
    proto = {};
    fields.forEach(function (name, i) {
      Object.defineProperty(proto, name, {
        enumerable: true,
        configurable: true,
        get: function () {
          var v = this.__store.getTransactionField(this.__block, this.__txId, i);
          // napi returns null for an absent field (Rust None); ReScript options
          // expect undefined.
          if (v === null) v = undefined;
          // Memoise: replace the prototype getter with an own value.
          Object.defineProperty(this, name, {
            value: v,
            enumerable: true,
            configurable: true,
          });
          return v;
        },
      });
    });
    protoCache.set(fields, proto);
    return proto;
  }
  return function (fields, store, blockNumber, transactionId) {
    var view = Object.create(getProto(fields));
    Object.defineProperty(view, "__store", { value: store });
    Object.defineProperty(view, "__block", { value: blockNumber });
    Object.defineProperty(view, "__txId", { value: transactionId });
    return view;
  };
})()`)

// Eagerly materialise every field into a plain dict (for raw_events, where all
// selected fields are serialised anyway).
let toDict: (
  array<string>,
  TransactionStore.t,
  int,
  string,
) => dict<unknown> = %raw(`function (fields, store, blockNumber, transactionId) {
  var out = {};
  fields.forEach(function (name, i) {
    var v = store.getTransactionField(blockNumber, transactionId, i);
    if (v !== null && v !== undefined) out[name] = v;
  });
  return out;
}`)
