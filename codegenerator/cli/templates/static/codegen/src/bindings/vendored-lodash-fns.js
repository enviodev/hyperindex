/*
 Created by using esbuild command:
 `esbuild --bundle --platform=node --tree-shaking=true <FILE_PATH>`
 on a js file with the following content:
 ```js
  import cloneDeep from "lodash-es/cloneDeep";
  export { cloneDeep };
 ```

 This is simply a treeshaken vendoring of lodash-es/cloneDeep.js

  */
"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if ((from && typeof from === "object") || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, {
          get: () => from[key],
          enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable,
        });
  }
  return to;
};
var __toCommonJS = (mod) =>
  __copyProps(__defProp({}, "__esModule", { value: true }), mod);

// src/bindings/vendored-lodash-fns-entry.js
var vendored_lodash_fns_entry_exports = {};
__export(vendored_lodash_fns_entry_exports, {
  cloneDeep: () => cloneDeep_default,
});
module.exports = __toCommonJS(vendored_lodash_fns_entry_exports);

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_listCacheClear.js
function listCacheClear() {
  this.__data__ = [];
  this.size = 0;
}
var listCacheClear_default = listCacheClear;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/eq.js
function eq(value, other) {
  return value === other || (value !== value && other !== other);
}
var eq_default = eq;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_assocIndexOf.js
function assocIndexOf(array, key) {
  var length = array.length;
  while (length--) {
    if (eq_default(array[length][0], key)) {
      return length;
    }
  }
  return -1;
}
var assocIndexOf_default = assocIndexOf;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_listCacheDelete.js
var arrayProto = Array.prototype;
var splice = arrayProto.splice;
function listCacheDelete(key) {
  var data = this.__data__,
    index = assocIndexOf_default(data, key);
  if (index < 0) {
    return false;
  }
  var lastIndex = data.length - 1;
  if (index == lastIndex) {
    data.pop();
  } else {
    splice.call(data, index, 1);
  }
  --this.size;
  return true;
}
var listCacheDelete_default = listCacheDelete;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_listCacheGet.js
function listCacheGet(key) {
  var data = this.__data__,
    index = assocIndexOf_default(data, key);
  return index < 0 ? void 0 : data[index][1];
}
var listCacheGet_default = listCacheGet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_listCacheHas.js
function listCacheHas(key) {
  return assocIndexOf_default(this.__data__, key) > -1;
}
var listCacheHas_default = listCacheHas;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_listCacheSet.js
function listCacheSet(key, value) {
  var data = this.__data__,
    index = assocIndexOf_default(data, key);
  if (index < 0) {
    ++this.size;
    data.push([key, value]);
  } else {
    data[index][1] = value;
  }
  return this;
}
var listCacheSet_default = listCacheSet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_ListCache.js
function ListCache(entries) {
  var index = -1,
    length = entries == null ? 0 : entries.length;
  this.clear();
  while (++index < length) {
    var entry = entries[index];
    this.set(entry[0], entry[1]);
  }
}
ListCache.prototype.clear = listCacheClear_default;
ListCache.prototype["delete"] = listCacheDelete_default;
ListCache.prototype.get = listCacheGet_default;
ListCache.prototype.has = listCacheHas_default;
ListCache.prototype.set = listCacheSet_default;
var ListCache_default = ListCache;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_stackClear.js
function stackClear() {
  this.__data__ = new ListCache_default();
  this.size = 0;
}
var stackClear_default = stackClear;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_stackDelete.js
function stackDelete(key) {
  var data = this.__data__,
    result = data["delete"](key);
  this.size = data.size;
  return result;
}
var stackDelete_default = stackDelete;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_stackGet.js
function stackGet(key) {
  return this.__data__.get(key);
}
var stackGet_default = stackGet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_stackHas.js
function stackHas(key) {
  return this.__data__.has(key);
}
var stackHas_default = stackHas;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_freeGlobal.js
var freeGlobal =
  typeof global == "object" && global && global.Object === Object && global;
var freeGlobal_default = freeGlobal;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_root.js
var freeSelf =
  typeof self == "object" && self && self.Object === Object && self;
var root = freeGlobal_default || freeSelf || Function("return this")();
var root_default = root;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Symbol.js
var Symbol2 = root_default.Symbol;
var Symbol_default = Symbol2;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getRawTag.js
var objectProto = Object.prototype;
var hasOwnProperty = objectProto.hasOwnProperty;
var nativeObjectToString = objectProto.toString;
var symToStringTag = Symbol_default ? Symbol_default.toStringTag : void 0;
function getRawTag(value) {
  var isOwn = hasOwnProperty.call(value, symToStringTag),
    tag = value[symToStringTag];
  try {
    value[symToStringTag] = void 0;
    var unmasked = true;
  } catch (e) {}
  var result = nativeObjectToString.call(value);
  if (unmasked) {
    if (isOwn) {
      value[symToStringTag] = tag;
    } else {
      delete value[symToStringTag];
    }
  }
  return result;
}
var getRawTag_default = getRawTag;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_objectToString.js
var objectProto2 = Object.prototype;
var nativeObjectToString2 = objectProto2.toString;
function objectToString(value) {
  return nativeObjectToString2.call(value);
}
var objectToString_default = objectToString;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseGetTag.js
var nullTag = "[object Null]";
var undefinedTag = "[object Undefined]";
var symToStringTag2 = Symbol_default ? Symbol_default.toStringTag : void 0;
function baseGetTag(value) {
  if (value == null) {
    return value === void 0 ? undefinedTag : nullTag;
  }
  return symToStringTag2 && symToStringTag2 in Object(value)
    ? getRawTag_default(value)
    : objectToString_default(value);
}
var baseGetTag_default = baseGetTag;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isObject.js
function isObject(value) {
  var type = typeof value;
  return value != null && (type == "object" || type == "function");
}
var isObject_default = isObject;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isFunction.js
var asyncTag = "[object AsyncFunction]";
var funcTag = "[object Function]";
var genTag = "[object GeneratorFunction]";
var proxyTag = "[object Proxy]";
function isFunction(value) {
  if (!isObject_default(value)) {
    return false;
  }
  var tag = baseGetTag_default(value);
  return tag == funcTag || tag == genTag || tag == asyncTag || tag == proxyTag;
}
var isFunction_default = isFunction;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_coreJsData.js
var coreJsData = root_default["__core-js_shared__"];
var coreJsData_default = coreJsData;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_isMasked.js
var maskSrcKey = (function () {
  var uid = /[^.]+$/.exec(
    (coreJsData_default &&
      coreJsData_default.keys &&
      coreJsData_default.keys.IE_PROTO) ||
      "",
  );
  return uid ? "Symbol(src)_1." + uid : "";
})();
function isMasked(func) {
  return !!maskSrcKey && maskSrcKey in func;
}
var isMasked_default = isMasked;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_toSource.js
var funcProto = Function.prototype;
var funcToString = funcProto.toString;
function toSource(func) {
  if (func != null) {
    try {
      return funcToString.call(func);
    } catch (e) {}
    try {
      return func + "";
    } catch (e) {}
  }
  return "";
}
var toSource_default = toSource;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseIsNative.js
var reRegExpChar = /[\\^$.*+?()[\]{}|]/g;
var reIsHostCtor = /^\[object .+?Constructor\]$/;
var funcProto2 = Function.prototype;
var objectProto3 = Object.prototype;
var funcToString2 = funcProto2.toString;
var hasOwnProperty2 = objectProto3.hasOwnProperty;
var reIsNative = RegExp(
  "^" +
    funcToString2
      .call(hasOwnProperty2)
      .replace(reRegExpChar, "\\$&")
      .replace(
        /hasOwnProperty|(function).*?(?=\\\()| for .+?(?=\\\])/g,
        "$1.*?",
      ) +
    "$",
);
function baseIsNative(value) {
  if (!isObject_default(value) || isMasked_default(value)) {
    return false;
  }
  var pattern = isFunction_default(value) ? reIsNative : reIsHostCtor;
  return pattern.test(toSource_default(value));
}
var baseIsNative_default = baseIsNative;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getValue.js
function getValue(object, key) {
  return object == null ? void 0 : object[key];
}
var getValue_default = getValue;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getNative.js
function getNative(object, key) {
  var value = getValue_default(object, key);
  return baseIsNative_default(value) ? value : void 0;
}
var getNative_default = getNative;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Map.js
var Map = getNative_default(root_default, "Map");
var Map_default = Map;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_nativeCreate.js
var nativeCreate = getNative_default(Object, "create");
var nativeCreate_default = nativeCreate;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_hashClear.js
function hashClear() {
  this.__data__ = nativeCreate_default ? nativeCreate_default(null) : {};
  this.size = 0;
}
var hashClear_default = hashClear;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_hashDelete.js
function hashDelete(key) {
  var result = this.has(key) && delete this.__data__[key];
  this.size -= result ? 1 : 0;
  return result;
}
var hashDelete_default = hashDelete;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_hashGet.js
var HASH_UNDEFINED = "__lodash_hash_undefined__";
var objectProto4 = Object.prototype;
var hasOwnProperty3 = objectProto4.hasOwnProperty;
function hashGet(key) {
  var data = this.__data__;
  if (nativeCreate_default) {
    var result = data[key];
    return result === HASH_UNDEFINED ? void 0 : result;
  }
  return hasOwnProperty3.call(data, key) ? data[key] : void 0;
}
var hashGet_default = hashGet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_hashHas.js
var objectProto5 = Object.prototype;
var hasOwnProperty4 = objectProto5.hasOwnProperty;
function hashHas(key) {
  var data = this.__data__;
  return nativeCreate_default
    ? data[key] !== void 0
    : hasOwnProperty4.call(data, key);
}
var hashHas_default = hashHas;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_hashSet.js
var HASH_UNDEFINED2 = "__lodash_hash_undefined__";
function hashSet(key, value) {
  var data = this.__data__;
  this.size += this.has(key) ? 0 : 1;
  data[key] =
    nativeCreate_default && value === void 0 ? HASH_UNDEFINED2 : value;
  return this;
}
var hashSet_default = hashSet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Hash.js
function Hash(entries) {
  var index = -1,
    length = entries == null ? 0 : entries.length;
  this.clear();
  while (++index < length) {
    var entry = entries[index];
    this.set(entry[0], entry[1]);
  }
}
Hash.prototype.clear = hashClear_default;
Hash.prototype["delete"] = hashDelete_default;
Hash.prototype.get = hashGet_default;
Hash.prototype.has = hashHas_default;
Hash.prototype.set = hashSet_default;
var Hash_default = Hash;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_mapCacheClear.js
function mapCacheClear() {
  this.size = 0;
  this.__data__ = {
    hash: new Hash_default(),
    map: new (Map_default || ListCache_default)(),
    string: new Hash_default(),
  };
}
var mapCacheClear_default = mapCacheClear;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_isKeyable.js
function isKeyable(value) {
  var type = typeof value;
  return type == "string" ||
    type == "number" ||
    type == "symbol" ||
    type == "boolean"
    ? value !== "__proto__"
    : value === null;
}
var isKeyable_default = isKeyable;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getMapData.js
function getMapData(map, key) {
  var data = map.__data__;
  return isKeyable_default(key)
    ? data[typeof key == "string" ? "string" : "hash"]
    : data.map;
}
var getMapData_default = getMapData;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_mapCacheDelete.js
function mapCacheDelete(key) {
  var result = getMapData_default(this, key)["delete"](key);
  this.size -= result ? 1 : 0;
  return result;
}
var mapCacheDelete_default = mapCacheDelete;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_mapCacheGet.js
function mapCacheGet(key) {
  return getMapData_default(this, key).get(key);
}
var mapCacheGet_default = mapCacheGet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_mapCacheHas.js
function mapCacheHas(key) {
  return getMapData_default(this, key).has(key);
}
var mapCacheHas_default = mapCacheHas;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_mapCacheSet.js
function mapCacheSet(key, value) {
  var data = getMapData_default(this, key),
    size = data.size;
  data.set(key, value);
  this.size += data.size == size ? 0 : 1;
  return this;
}
var mapCacheSet_default = mapCacheSet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_MapCache.js
function MapCache(entries) {
  var index = -1,
    length = entries == null ? 0 : entries.length;
  this.clear();
  while (++index < length) {
    var entry = entries[index];
    this.set(entry[0], entry[1]);
  }
}
MapCache.prototype.clear = mapCacheClear_default;
MapCache.prototype["delete"] = mapCacheDelete_default;
MapCache.prototype.get = mapCacheGet_default;
MapCache.prototype.has = mapCacheHas_default;
MapCache.prototype.set = mapCacheSet_default;
var MapCache_default = MapCache;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_stackSet.js
var LARGE_ARRAY_SIZE = 200;
function stackSet(key, value) {
  var data = this.__data__;
  if (data instanceof ListCache_default) {
    var pairs = data.__data__;
    if (!Map_default || pairs.length < LARGE_ARRAY_SIZE - 1) {
      pairs.push([key, value]);
      this.size = ++data.size;
      return this;
    }
    data = this.__data__ = new MapCache_default(pairs);
  }
  data.set(key, value);
  this.size = data.size;
  return this;
}
var stackSet_default = stackSet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Stack.js
function Stack(entries) {
  var data = (this.__data__ = new ListCache_default(entries));
  this.size = data.size;
}
Stack.prototype.clear = stackClear_default;
Stack.prototype["delete"] = stackDelete_default;
Stack.prototype.get = stackGet_default;
Stack.prototype.has = stackHas_default;
Stack.prototype.set = stackSet_default;
var Stack_default = Stack;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_arrayEach.js
function arrayEach(array, iteratee) {
  var index = -1,
    length = array == null ? 0 : array.length;
  while (++index < length) {
    if (iteratee(array[index], index, array) === false) {
      break;
    }
  }
  return array;
}
var arrayEach_default = arrayEach;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_defineProperty.js
var defineProperty = (function () {
  try {
    var func = getNative_default(Object, "defineProperty");
    func({}, "", {});
    return func;
  } catch (e) {}
})();
var defineProperty_default = defineProperty;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseAssignValue.js
function baseAssignValue(object, key, value) {
  if (key == "__proto__" && defineProperty_default) {
    defineProperty_default(object, key, {
      configurable: true,
      enumerable: true,
      value: value,
      writable: true,
    });
  } else {
    object[key] = value;
  }
}
var baseAssignValue_default = baseAssignValue;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_assignValue.js
var objectProto6 = Object.prototype;
var hasOwnProperty5 = objectProto6.hasOwnProperty;
function assignValue(object, key, value) {
  var objValue = object[key];
  if (
    !(hasOwnProperty5.call(object, key) && eq_default(objValue, value)) ||
    (value === void 0 && !(key in object))
  ) {
    baseAssignValue_default(object, key, value);
  }
}
var assignValue_default = assignValue;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_copyObject.js
function copyObject(source, props, object, customizer) {
  var isNew = !object;
  object || (object = {});
  var index = -1,
    length = props.length;
  while (++index < length) {
    var key = props[index];
    var newValue = customizer
      ? customizer(object[key], source[key], key, object, source)
      : void 0;
    if (newValue === void 0) {
      newValue = source[key];
    }
    if (isNew) {
      baseAssignValue_default(object, key, newValue);
    } else {
      assignValue_default(object, key, newValue);
    }
  }
  return object;
}
var copyObject_default = copyObject;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseTimes.js
function baseTimes(n, iteratee) {
  var index = -1,
    result = Array(n);
  while (++index < n) {
    result[index] = iteratee(index);
  }
  return result;
}
var baseTimes_default = baseTimes;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isObjectLike.js
function isObjectLike(value) {
  return value != null && typeof value == "object";
}
var isObjectLike_default = isObjectLike;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseIsArguments.js
var argsTag = "[object Arguments]";
function baseIsArguments(value) {
  return isObjectLike_default(value) && baseGetTag_default(value) == argsTag;
}
var baseIsArguments_default = baseIsArguments;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isArguments.js
var objectProto7 = Object.prototype;
var hasOwnProperty6 = objectProto7.hasOwnProperty;
var propertyIsEnumerable = objectProto7.propertyIsEnumerable;
var isArguments = baseIsArguments_default(
  /* @__PURE__ */ (function () {
    return arguments;
  })(),
)
  ? baseIsArguments_default
  : function (value) {
      return (
        isObjectLike_default(value) &&
        hasOwnProperty6.call(value, "callee") &&
        !propertyIsEnumerable.call(value, "callee")
      );
    };
var isArguments_default = isArguments;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isArray.js
var isArray = Array.isArray;
var isArray_default = isArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/stubFalse.js
function stubFalse() {
  return false;
}
var stubFalse_default = stubFalse;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isBuffer.js
var freeExports =
  typeof exports == "object" && exports && !exports.nodeType && exports;
var freeModule =
  freeExports &&
  typeof module == "object" &&
  module &&
  !module.nodeType &&
  module;
var moduleExports = freeModule && freeModule.exports === freeExports;
var Buffer2 = moduleExports ? root_default.Buffer : void 0;
var nativeIsBuffer = Buffer2 ? Buffer2.isBuffer : void 0;
var isBuffer = nativeIsBuffer || stubFalse_default;
var isBuffer_default = isBuffer;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_isIndex.js
var MAX_SAFE_INTEGER = 9007199254740991;
var reIsUint = /^(?:0|[1-9]\d*)$/;
function isIndex(value, length) {
  var type = typeof value;
  length = length == null ? MAX_SAFE_INTEGER : length;
  return (
    !!length &&
    (type == "number" || (type != "symbol" && reIsUint.test(value))) &&
    value > -1 &&
    value % 1 == 0 &&
    value < length
  );
}
var isIndex_default = isIndex;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isLength.js
var MAX_SAFE_INTEGER2 = 9007199254740991;
function isLength(value) {
  return (
    typeof value == "number" &&
    value > -1 &&
    value % 1 == 0 &&
    value <= MAX_SAFE_INTEGER2
  );
}
var isLength_default = isLength;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseIsTypedArray.js
var argsTag2 = "[object Arguments]";
var arrayTag = "[object Array]";
var boolTag = "[object Boolean]";
var dateTag = "[object Date]";
var errorTag = "[object Error]";
var funcTag2 = "[object Function]";
var mapTag = "[object Map]";
var numberTag = "[object Number]";
var objectTag = "[object Object]";
var regexpTag = "[object RegExp]";
var setTag = "[object Set]";
var stringTag = "[object String]";
var weakMapTag = "[object WeakMap]";
var arrayBufferTag = "[object ArrayBuffer]";
var dataViewTag = "[object DataView]";
var float32Tag = "[object Float32Array]";
var float64Tag = "[object Float64Array]";
var int8Tag = "[object Int8Array]";
var int16Tag = "[object Int16Array]";
var int32Tag = "[object Int32Array]";
var uint8Tag = "[object Uint8Array]";
var uint8ClampedTag = "[object Uint8ClampedArray]";
var uint16Tag = "[object Uint16Array]";
var uint32Tag = "[object Uint32Array]";
var typedArrayTags = {};
typedArrayTags[float32Tag] =
  typedArrayTags[float64Tag] =
  typedArrayTags[int8Tag] =
  typedArrayTags[int16Tag] =
  typedArrayTags[int32Tag] =
  typedArrayTags[uint8Tag] =
  typedArrayTags[uint8ClampedTag] =
  typedArrayTags[uint16Tag] =
  typedArrayTags[uint32Tag] =
    true;
typedArrayTags[argsTag2] =
  typedArrayTags[arrayTag] =
  typedArrayTags[arrayBufferTag] =
  typedArrayTags[boolTag] =
  typedArrayTags[dataViewTag] =
  typedArrayTags[dateTag] =
  typedArrayTags[errorTag] =
  typedArrayTags[funcTag2] =
  typedArrayTags[mapTag] =
  typedArrayTags[numberTag] =
  typedArrayTags[objectTag] =
  typedArrayTags[regexpTag] =
  typedArrayTags[setTag] =
  typedArrayTags[stringTag] =
  typedArrayTags[weakMapTag] =
    false;
function baseIsTypedArray(value) {
  return (
    isObjectLike_default(value) &&
    isLength_default(value.length) &&
    !!typedArrayTags[baseGetTag_default(value)]
  );
}
var baseIsTypedArray_default = baseIsTypedArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseUnary.js
function baseUnary(func) {
  return function (value) {
    return func(value);
  };
}
var baseUnary_default = baseUnary;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_nodeUtil.js
var freeExports2 =
  typeof exports == "object" && exports && !exports.nodeType && exports;
var freeModule2 =
  freeExports2 &&
  typeof module == "object" &&
  module &&
  !module.nodeType &&
  module;
var moduleExports2 = freeModule2 && freeModule2.exports === freeExports2;
var freeProcess = moduleExports2 && freeGlobal_default.process;
var nodeUtil = (function () {
  try {
    var types =
      freeModule2 && freeModule2.require && freeModule2.require("util").types;
    if (types) {
      return types;
    }
    return freeProcess && freeProcess.binding && freeProcess.binding("util");
  } catch (e) {}
})();
var nodeUtil_default = nodeUtil;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isTypedArray.js
var nodeIsTypedArray = nodeUtil_default && nodeUtil_default.isTypedArray;
var isTypedArray = nodeIsTypedArray
  ? baseUnary_default(nodeIsTypedArray)
  : baseIsTypedArray_default;
var isTypedArray_default = isTypedArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_arrayLikeKeys.js
var objectProto8 = Object.prototype;
var hasOwnProperty7 = objectProto8.hasOwnProperty;
function arrayLikeKeys(value, inherited) {
  var isArr = isArray_default(value),
    isArg = !isArr && isArguments_default(value),
    isBuff = !isArr && !isArg && isBuffer_default(value),
    isType = !isArr && !isArg && !isBuff && isTypedArray_default(value),
    skipIndexes = isArr || isArg || isBuff || isType,
    result = skipIndexes ? baseTimes_default(value.length, String) : [],
    length = result.length;
  for (var key in value) {
    if (
      (inherited || hasOwnProperty7.call(value, key)) &&
      !(
        skipIndexes && // Safari 9 has enumerable `arguments.length` in strict mode.
        (key == "length" || // Node.js 0.10 has enumerable non-index properties on buffers.
          (isBuff && (key == "offset" || key == "parent")) || // PhantomJS 2 has enumerable non-index properties on typed arrays.
          (isType &&
            (key == "buffer" || key == "byteLength" || key == "byteOffset")) || // Skip index properties.
          isIndex_default(key, length))
      )
    ) {
      result.push(key);
    }
  }
  return result;
}
var arrayLikeKeys_default = arrayLikeKeys;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_isPrototype.js
var objectProto9 = Object.prototype;
function isPrototype(value) {
  var Ctor = value && value.constructor,
    proto = (typeof Ctor == "function" && Ctor.prototype) || objectProto9;
  return value === proto;
}
var isPrototype_default = isPrototype;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_overArg.js
function overArg(func, transform) {
  return function (arg) {
    return func(transform(arg));
  };
}
var overArg_default = overArg;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_nativeKeys.js
var nativeKeys = overArg_default(Object.keys, Object);
var nativeKeys_default = nativeKeys;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseKeys.js
var objectProto10 = Object.prototype;
var hasOwnProperty8 = objectProto10.hasOwnProperty;
function baseKeys(object) {
  if (!isPrototype_default(object)) {
    return nativeKeys_default(object);
  }
  var result = [];
  for (var key in Object(object)) {
    if (hasOwnProperty8.call(object, key) && key != "constructor") {
      result.push(key);
    }
  }
  return result;
}
var baseKeys_default = baseKeys;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isArrayLike.js
function isArrayLike(value) {
  return (
    value != null &&
    isLength_default(value.length) &&
    !isFunction_default(value)
  );
}
var isArrayLike_default = isArrayLike;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/keys.js
function keys(object) {
  return isArrayLike_default(object)
    ? arrayLikeKeys_default(object)
    : baseKeys_default(object);
}
var keys_default = keys;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseAssign.js
function baseAssign(object, source) {
  return object && copyObject_default(source, keys_default(source), object);
}
var baseAssign_default = baseAssign;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_nativeKeysIn.js
function nativeKeysIn(object) {
  var result = [];
  if (object != null) {
    for (var key in Object(object)) {
      result.push(key);
    }
  }
  return result;
}
var nativeKeysIn_default = nativeKeysIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseKeysIn.js
var objectProto11 = Object.prototype;
var hasOwnProperty9 = objectProto11.hasOwnProperty;
function baseKeysIn(object) {
  if (!isObject_default(object)) {
    return nativeKeysIn_default(object);
  }
  var isProto = isPrototype_default(object),
    result = [];
  for (var key in object) {
    if (
      !(key == "constructor" && (isProto || !hasOwnProperty9.call(object, key)))
    ) {
      result.push(key);
    }
  }
  return result;
}
var baseKeysIn_default = baseKeysIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/keysIn.js
function keysIn(object) {
  return isArrayLike_default(object)
    ? arrayLikeKeys_default(object, true)
    : baseKeysIn_default(object);
}
var keysIn_default = keysIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseAssignIn.js
function baseAssignIn(object, source) {
  return object && copyObject_default(source, keysIn_default(source), object);
}
var baseAssignIn_default = baseAssignIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_cloneBuffer.js
var freeExports3 =
  typeof exports == "object" && exports && !exports.nodeType && exports;
var freeModule3 =
  freeExports3 &&
  typeof module == "object" &&
  module &&
  !module.nodeType &&
  module;
var moduleExports3 = freeModule3 && freeModule3.exports === freeExports3;
var Buffer3 = moduleExports3 ? root_default.Buffer : void 0;
var allocUnsafe = Buffer3 ? Buffer3.allocUnsafe : void 0;
function cloneBuffer(buffer, isDeep) {
  if (isDeep) {
    return buffer.slice();
  }
  var length = buffer.length,
    result = allocUnsafe ? allocUnsafe(length) : new buffer.constructor(length);
  buffer.copy(result);
  return result;
}
var cloneBuffer_default = cloneBuffer;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_copyArray.js
function copyArray(source, array) {
  var index = -1,
    length = source.length;
  array || (array = Array(length));
  while (++index < length) {
    array[index] = source[index];
  }
  return array;
}
var copyArray_default = copyArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_arrayFilter.js
function arrayFilter(array, predicate) {
  var index = -1,
    length = array == null ? 0 : array.length,
    resIndex = 0,
    result = [];
  while (++index < length) {
    var value = array[index];
    if (predicate(value, index, array)) {
      result[resIndex++] = value;
    }
  }
  return result;
}
var arrayFilter_default = arrayFilter;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/stubArray.js
function stubArray() {
  return [];
}
var stubArray_default = stubArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getSymbols.js
var objectProto12 = Object.prototype;
var propertyIsEnumerable2 = objectProto12.propertyIsEnumerable;
var nativeGetSymbols = Object.getOwnPropertySymbols;
var getSymbols = !nativeGetSymbols
  ? stubArray_default
  : function (object) {
      if (object == null) {
        return [];
      }
      object = Object(object);
      return arrayFilter_default(nativeGetSymbols(object), function (symbol) {
        return propertyIsEnumerable2.call(object, symbol);
      });
    };
var getSymbols_default = getSymbols;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_copySymbols.js
function copySymbols(source, object) {
  return copyObject_default(source, getSymbols_default(source), object);
}
var copySymbols_default = copySymbols;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_arrayPush.js
function arrayPush(array, values) {
  var index = -1,
    length = values.length,
    offset = array.length;
  while (++index < length) {
    array[offset + index] = values[index];
  }
  return array;
}
var arrayPush_default = arrayPush;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getPrototype.js
var getPrototype = overArg_default(Object.getPrototypeOf, Object);
var getPrototype_default = getPrototype;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getSymbolsIn.js
var nativeGetSymbols2 = Object.getOwnPropertySymbols;
var getSymbolsIn = !nativeGetSymbols2
  ? stubArray_default
  : function (object) {
      var result = [];
      while (object) {
        arrayPush_default(result, getSymbols_default(object));
        object = getPrototype_default(object);
      }
      return result;
    };
var getSymbolsIn_default = getSymbolsIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_copySymbolsIn.js
function copySymbolsIn(source, object) {
  return copyObject_default(source, getSymbolsIn_default(source), object);
}
var copySymbolsIn_default = copySymbolsIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseGetAllKeys.js
function baseGetAllKeys(object, keysFunc, symbolsFunc) {
  var result = keysFunc(object);
  return isArray_default(object)
    ? result
    : arrayPush_default(result, symbolsFunc(object));
}
var baseGetAllKeys_default = baseGetAllKeys;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getAllKeys.js
function getAllKeys(object) {
  return baseGetAllKeys_default(object, keys_default, getSymbols_default);
}
var getAllKeys_default = getAllKeys;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getAllKeysIn.js
function getAllKeysIn(object) {
  return baseGetAllKeys_default(object, keysIn_default, getSymbolsIn_default);
}
var getAllKeysIn_default = getAllKeysIn;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_DataView.js
var DataView = getNative_default(root_default, "DataView");
var DataView_default = DataView;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Promise.js
var Promise2 = getNative_default(root_default, "Promise");
var Promise_default = Promise2;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Set.js
var Set = getNative_default(root_default, "Set");
var Set_default = Set;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_WeakMap.js
var WeakMap = getNative_default(root_default, "WeakMap");
var WeakMap_default = WeakMap;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_getTag.js
var mapTag2 = "[object Map]";
var objectTag2 = "[object Object]";
var promiseTag = "[object Promise]";
var setTag2 = "[object Set]";
var weakMapTag2 = "[object WeakMap]";
var dataViewTag2 = "[object DataView]";
var dataViewCtorString = toSource_default(DataView_default);
var mapCtorString = toSource_default(Map_default);
var promiseCtorString = toSource_default(Promise_default);
var setCtorString = toSource_default(Set_default);
var weakMapCtorString = toSource_default(WeakMap_default);
var getTag = baseGetTag_default;
if (
  (DataView_default &&
    getTag(new DataView_default(new ArrayBuffer(1))) != dataViewTag2) ||
  (Map_default && getTag(new Map_default()) != mapTag2) ||
  (Promise_default && getTag(Promise_default.resolve()) != promiseTag) ||
  (Set_default && getTag(new Set_default()) != setTag2) ||
  (WeakMap_default && getTag(new WeakMap_default()) != weakMapTag2)
) {
  getTag = function (value) {
    var result = baseGetTag_default(value),
      Ctor = result == objectTag2 ? value.constructor : void 0,
      ctorString = Ctor ? toSource_default(Ctor) : "";
    if (ctorString) {
      switch (ctorString) {
        case dataViewCtorString:
          return dataViewTag2;
        case mapCtorString:
          return mapTag2;
        case promiseCtorString:
          return promiseTag;
        case setCtorString:
          return setTag2;
        case weakMapCtorString:
          return weakMapTag2;
      }
    }
    return result;
  };
}
var getTag_default = getTag;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_initCloneArray.js
var objectProto13 = Object.prototype;
var hasOwnProperty10 = objectProto13.hasOwnProperty;
function initCloneArray(array) {
  var length = array.length,
    result = new array.constructor(length);
  if (
    length &&
    typeof array[0] == "string" &&
    hasOwnProperty10.call(array, "index")
  ) {
    result.index = array.index;
    result.input = array.input;
  }
  return result;
}
var initCloneArray_default = initCloneArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_Uint8Array.js
var Uint8Array2 = root_default.Uint8Array;
var Uint8Array_default = Uint8Array2;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_cloneArrayBuffer.js
function cloneArrayBuffer(arrayBuffer) {
  var result = new arrayBuffer.constructor(arrayBuffer.byteLength);
  new Uint8Array_default(result).set(new Uint8Array_default(arrayBuffer));
  return result;
}
var cloneArrayBuffer_default = cloneArrayBuffer;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_cloneDataView.js
function cloneDataView(dataView, isDeep) {
  var buffer = isDeep
    ? cloneArrayBuffer_default(dataView.buffer)
    : dataView.buffer;
  return new dataView.constructor(
    buffer,
    dataView.byteOffset,
    dataView.byteLength,
  );
}
var cloneDataView_default = cloneDataView;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_cloneRegExp.js
var reFlags = /\w*$/;
function cloneRegExp(regexp) {
  var result = new regexp.constructor(regexp.source, reFlags.exec(regexp));
  result.lastIndex = regexp.lastIndex;
  return result;
}
var cloneRegExp_default = cloneRegExp;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_cloneSymbol.js
var symbolProto = Symbol_default ? Symbol_default.prototype : void 0;
var symbolValueOf = symbolProto ? symbolProto.valueOf : void 0;
function cloneSymbol(symbol) {
  return symbolValueOf ? Object(symbolValueOf.call(symbol)) : {};
}
var cloneSymbol_default = cloneSymbol;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_cloneTypedArray.js
function cloneTypedArray(typedArray, isDeep) {
  var buffer = isDeep
    ? cloneArrayBuffer_default(typedArray.buffer)
    : typedArray.buffer;
  return new typedArray.constructor(
    buffer,
    typedArray.byteOffset,
    typedArray.length,
  );
}
var cloneTypedArray_default = cloneTypedArray;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_initCloneByTag.js
var boolTag2 = "[object Boolean]";
var dateTag2 = "[object Date]";
var mapTag3 = "[object Map]";
var numberTag2 = "[object Number]";
var regexpTag2 = "[object RegExp]";
var setTag3 = "[object Set]";
var stringTag2 = "[object String]";
var symbolTag = "[object Symbol]";
var arrayBufferTag2 = "[object ArrayBuffer]";
var dataViewTag3 = "[object DataView]";
var float32Tag2 = "[object Float32Array]";
var float64Tag2 = "[object Float64Array]";
var int8Tag2 = "[object Int8Array]";
var int16Tag2 = "[object Int16Array]";
var int32Tag2 = "[object Int32Array]";
var uint8Tag2 = "[object Uint8Array]";
var uint8ClampedTag2 = "[object Uint8ClampedArray]";
var uint16Tag2 = "[object Uint16Array]";
var uint32Tag2 = "[object Uint32Array]";
function initCloneByTag(object, tag, isDeep) {
  var Ctor = object.constructor;
  switch (tag) {
    case arrayBufferTag2:
      return cloneArrayBuffer_default(object);
    case boolTag2:
    case dateTag2:
      return new Ctor(+object);
    case dataViewTag3:
      return cloneDataView_default(object, isDeep);
    case float32Tag2:
    case float64Tag2:
    case int8Tag2:
    case int16Tag2:
    case int32Tag2:
    case uint8Tag2:
    case uint8ClampedTag2:
    case uint16Tag2:
    case uint32Tag2:
      return cloneTypedArray_default(object, isDeep);
    case mapTag3:
      return new Ctor();
    case numberTag2:
    case stringTag2:
      return new Ctor(object);
    case regexpTag2:
      return cloneRegExp_default(object);
    case setTag3:
      return new Ctor();
    case symbolTag:
      return cloneSymbol_default(object);
  }
}
var initCloneByTag_default = initCloneByTag;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseCreate.js
var objectCreate = Object.create;
var baseCreate = /* @__PURE__ */ (function () {
  function object() {}
  return function (proto) {
    if (!isObject_default(proto)) {
      return {};
    }
    if (objectCreate) {
      return objectCreate(proto);
    }
    object.prototype = proto;
    var result = new object();
    object.prototype = void 0;
    return result;
  };
})();
var baseCreate_default = baseCreate;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_initCloneObject.js
function initCloneObject(object) {
  return typeof object.constructor == "function" && !isPrototype_default(object)
    ? baseCreate_default(getPrototype_default(object))
    : {};
}
var initCloneObject_default = initCloneObject;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseIsMap.js
var mapTag4 = "[object Map]";
function baseIsMap(value) {
  return isObjectLike_default(value) && getTag_default(value) == mapTag4;
}
var baseIsMap_default = baseIsMap;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isMap.js
var nodeIsMap = nodeUtil_default && nodeUtil_default.isMap;
var isMap = nodeIsMap ? baseUnary_default(nodeIsMap) : baseIsMap_default;
var isMap_default = isMap;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseIsSet.js
var setTag4 = "[object Set]";
function baseIsSet(value) {
  return isObjectLike_default(value) && getTag_default(value) == setTag4;
}
var baseIsSet_default = baseIsSet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/isSet.js
var nodeIsSet = nodeUtil_default && nodeUtil_default.isSet;
var isSet = nodeIsSet ? baseUnary_default(nodeIsSet) : baseIsSet_default;
var isSet_default = isSet;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/_baseClone.js
var CLONE_DEEP_FLAG = 1;
var CLONE_FLAT_FLAG = 2;
var CLONE_SYMBOLS_FLAG = 4;
var argsTag3 = "[object Arguments]";
var arrayTag2 = "[object Array]";
var boolTag3 = "[object Boolean]";
var dateTag3 = "[object Date]";
var errorTag2 = "[object Error]";
var funcTag3 = "[object Function]";
var genTag2 = "[object GeneratorFunction]";
var mapTag5 = "[object Map]";
var numberTag3 = "[object Number]";
var objectTag3 = "[object Object]";
var regexpTag3 = "[object RegExp]";
var setTag5 = "[object Set]";
var stringTag3 = "[object String]";
var symbolTag2 = "[object Symbol]";
var weakMapTag3 = "[object WeakMap]";
var arrayBufferTag3 = "[object ArrayBuffer]";
var dataViewTag4 = "[object DataView]";
var float32Tag3 = "[object Float32Array]";
var float64Tag3 = "[object Float64Array]";
var int8Tag3 = "[object Int8Array]";
var int16Tag3 = "[object Int16Array]";
var int32Tag3 = "[object Int32Array]";
var uint8Tag3 = "[object Uint8Array]";
var uint8ClampedTag3 = "[object Uint8ClampedArray]";
var uint16Tag3 = "[object Uint16Array]";
var uint32Tag3 = "[object Uint32Array]";
var cloneableTags = {};
cloneableTags[argsTag3] =
  cloneableTags[arrayTag2] =
  cloneableTags[arrayBufferTag3] =
  cloneableTags[dataViewTag4] =
  cloneableTags[boolTag3] =
  cloneableTags[dateTag3] =
  cloneableTags[float32Tag3] =
  cloneableTags[float64Tag3] =
  cloneableTags[int8Tag3] =
  cloneableTags[int16Tag3] =
  cloneableTags[int32Tag3] =
  cloneableTags[mapTag5] =
  cloneableTags[numberTag3] =
  cloneableTags[objectTag3] =
  cloneableTags[regexpTag3] =
  cloneableTags[setTag5] =
  cloneableTags[stringTag3] =
  cloneableTags[symbolTag2] =
  cloneableTags[uint8Tag3] =
  cloneableTags[uint8ClampedTag3] =
  cloneableTags[uint16Tag3] =
  cloneableTags[uint32Tag3] =
    true;
cloneableTags[errorTag2] =
  cloneableTags[funcTag3] =
  cloneableTags[weakMapTag3] =
    false;
function baseClone(value, bitmask, customizer, key, object, stack) {
  var result,
    isDeep = bitmask & CLONE_DEEP_FLAG,
    isFlat = bitmask & CLONE_FLAT_FLAG,
    isFull = bitmask & CLONE_SYMBOLS_FLAG;
  if (customizer) {
    result = object ? customizer(value, key, object, stack) : customizer(value);
  }
  if (result !== void 0) {
    return result;
  }
  if (!isObject_default(value)) {
    return value;
  }
  var isArr = isArray_default(value);
  if (isArr) {
    result = initCloneArray_default(value);
    if (!isDeep) {
      return copyArray_default(value, result);
    }
  } else {
    var tag = getTag_default(value),
      isFunc = tag == funcTag3 || tag == genTag2;
    if (isBuffer_default(value)) {
      return cloneBuffer_default(value, isDeep);
    }
    if (tag == objectTag3 || tag == argsTag3 || (isFunc && !object)) {
      result = isFlat || isFunc ? {} : initCloneObject_default(value);
      if (!isDeep) {
        return isFlat
          ? copySymbolsIn_default(value, baseAssignIn_default(result, value))
          : copySymbols_default(value, baseAssign_default(result, value));
      }
    } else {
      if (!cloneableTags[tag]) {
        return object ? value : {};
      }
      result = initCloneByTag_default(value, tag, isDeep);
    }
  }
  stack || (stack = new Stack_default());
  var stacked = stack.get(value);
  if (stacked) {
    return stacked;
  }
  stack.set(value, result);
  if (isSet_default(value)) {
    value.forEach(function (subValue) {
      result.add(
        baseClone(subValue, bitmask, customizer, subValue, value, stack),
      );
    });
  } else if (isMap_default(value)) {
    value.forEach(function (subValue, key2) {
      result.set(
        key2,
        baseClone(subValue, bitmask, customizer, key2, value, stack),
      );
    });
  }
  var keysFunc = isFull
    ? isFlat
      ? getAllKeysIn_default
      : getAllKeys_default
    : isFlat
      ? keysIn_default
      : keys_default;
  var props = isArr ? void 0 : keysFunc(value);
  arrayEach_default(props || value, function (subValue, key2) {
    if (props) {
      key2 = subValue;
      subValue = value[key2];
    }
    assignValue_default(
      result,
      key2,
      baseClone(subValue, bitmask, customizer, key2, value, stack),
    );
  });
  return result;
}
var baseClone_default = baseClone;

// ../node_modules/.pnpm/lodash-es@4.17.21/node_modules/lodash-es/cloneDeep.js
var CLONE_DEEP_FLAG2 = 1;
var CLONE_SYMBOLS_FLAG2 = 4;
function cloneDeep(value) {
  return baseClone_default(value, CLONE_DEEP_FLAG2 | CLONE_SYMBOLS_FLAG2);
}
var cloneDeep_default = cloneDeep;
// Annotate the CommonJS export names for ESM import in node:
0 &&
  (module.exports = {
    cloneDeep,
  });
