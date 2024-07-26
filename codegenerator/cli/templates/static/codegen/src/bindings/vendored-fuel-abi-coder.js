"use strict";

// Copyright (C) Fuel Labs <contact@fuel.sh> (https://fuel.network/)

// This is a vendored compiled file from @fuel-ts/abi-coder@0.86.0 package
// We want to change a few decoding functions, to avoid having our own decoders
// and optimise the decodign process as much as possible.
// As a more maintainable option we might consider forking the repo and publishing
// a patched version under the @envio-dev org.
// Initially I've tried using pnpm patch,
// but it didn't work for us, since it include patch in the root of the repo, which is user's indexer.

// Here's the list of the changes:
// 1. Changed enum decoder to always return data in a format {case: <Variant name>, payload: <Payload data>}.
//    Where Payload data shoudl be unit if it's not provided.
// 1.1. Adjust OptionCoder
// 2. Changed BigNumberCoder to return BigInt instead of BN.js 
// 3. Exposed AbiCoder and added getLogDecoder static method, to do all prep work once

// Here's the generated diff from pnpm patch

// diff --git a/dist/index.js b/dist/index.js
// index bbb0bdfd7d506d311d2160f81b22a59ded3e4f70..653e0b400358e2e67c84c27bb2e120a2e4115717 100644
// --- a/dist/index.js
// +++ b/dist/index.js
// @@ -25,6 +25,7 @@ var __publicField = (obj, key, value) => {
//  // src/index.ts
//  var src_exports = {};
//  __export(src_exports, {
// +  AbiCoder: () => AbiCoder,
//    ASSET_ID_LEN: () => ASSET_ID_LEN,
//    ArrayCoder: () => ArrayCoder,
//    B256Coder: () => B256Coder,
// @@ -272,7 +273,7 @@ var BigNumberCoder = class extends Coder {
//      if (bytes.length !== this.encodedLength) {
//        throw new import_errors4.FuelError(import_errors4.ErrorCode.DECODE_ERROR, `Invalid ${this.type} byte data size.`);
//      }
// -    return [(0, import_math3.bn)(bytes), offset + this.encodedLength];
// +    return [BigInt(import_math3.bn(bytes)), offset + this.encodedLength];
//    }
//  };

// @@ -408,7 +409,7 @@ var EnumCoder = class extends Coder {
// -    if (isFullyNativeEnum(this.coders)) {
// -      return this.#decodeNativeEnum(caseKey, newOffset);
// -    }
// -    return [{ [caseKey]: decoded }, newOffset];
// +    return [{ case: caseKey, payload: decoded }, newOffset];
//    }
//  };

// @@ -1035,6 +1036,20 @@ var AbiCoder = class {
//      const resolvedAbiType = new ResolvedAbiType(abi, argument);
//      return getCoderForEncoding(options.encoding)(resolvedAbiType, options);
//    }
// +  static getLogDecoder(abi, logId, options = {
// +    padToWordSize: false
// +  }) {
// +    const loggedType = abi.loggedTypes.find((type) => type.logId === logId);
// +    if (!loggedType) {
// +      throw new import_errors20.FuelError(
// +        import_errors20.ErrorCode.LOG_TYPE_NOT_FOUND,
// +        `Log type with logId '${logId}' doesn't exist in the ABI.`
// +      );
// +    }
// +    const resolvedAbiType = new ResolvedAbiType(abi, loggedType.loggedType);
// +    const internalCoder = getCoderForEncoding(options.encoding)(resolvedAbiType, options);
// +    return (data) => internalCoder.decode(import_utils12.arrayify(data), 0)[0];
// +  }
//    static encode(abi, argument, value, options) {
//      return this.getCoder(abi, argument, options).encode(value);
//    }
// @@ -1239,8 +1254,10 @@ var Interface = class {
//      return findTypeById(this.jsonAbi, typeId);
//    }
//  };
// +
//  // Annotate the CommonJS export names for ESM import in node:
//  0 && (module.exports = {
// +  AbiCoder,
//    ASSET_ID_LEN,
//    ArrayCoder,
//    B256Coder,


"use strict";
var __defProp = Object.defineProperty;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __hasOwnProp = Object.prototype.hasOwnProperty;
var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, { get: all[name], enumerable: true });
};
var __copyProps = (to, from, except, desc) => {
  if (from && typeof from === "object" || typeof from === "function") {
    for (let key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(to, key) && key !== except)
        __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
  }
  return to;
};
var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);
var __publicField = (obj, key, value) => {
  __defNormalProp(obj, typeof key !== "symbol" ? key + "" : key, value);
  return value;
};


// src/index.ts
var src_exports = {};
__export(src_exports, {
  ASSET_ID_LEN: () => ASSET_ID_LEN,
  AbiCoder: () => AbiCoder,
  ArrayCoder: () => ArrayCoder,
  B256Coder: () => B256Coder,
  B512Coder: () => B512Coder,
  BYTES_32: () => BYTES_32,
  BigNumberCoder: () => BigNumberCoder,
  BooleanCoder: () => BooleanCoder,
  ByteCoder: () => ByteCoder,
  CONTRACT_ID_LEN: () => CONTRACT_ID_LEN,
  Coder: () => Coder,
  ENCODING_V1: () => ENCODING_V1,
  EnumCoder: () => EnumCoder,
  INPUT_COIN_FIXED_SIZE: () => INPUT_COIN_FIXED_SIZE,
  Interface: () => Interface,
  NumberCoder: () => NumberCoder,
  OptionCoder: () => OptionCoder,
  RawSliceCoder: () => RawSliceCoder,
  SCRIPT_FIXED_SIZE: () => SCRIPT_FIXED_SIZE,
  StdStringCoder: () => StdStringCoder,
  StrSliceCoder: () => StrSliceCoder,
  StringCoder: () => StringCoder,
  StructCoder: () => StructCoder,
  TupleCoder: () => TupleCoder,
  UTXO_ID_LEN: () => UTXO_ID_LEN,
  VecCoder: () => VecCoder,
  WORD_SIZE: () => WORD_SIZE,
  calculateVmTxMemory: () => calculateVmTxMemory
});
module.exports = __toCommonJS(src_exports);

// src/encoding/coders/AbstractCoder.ts
var Coder = class {
  name;
  type;
  encodedLength;
  constructor(name, type, encodedLength) {
    this.name = name;
    this.type = type;
    this.encodedLength = encodedLength;
  }
};

// src/encoding/coders/ArrayCoder.ts
var import_errors = require("@fuel-ts/errors");
var import_utils = require("@fuel-ts/utils");

// src/utils/constants.ts
var U8_CODER_TYPE = "u8";
var U16_CODER_TYPE = "u16";
var U32_CODER_TYPE = "u32";
var U64_CODER_TYPE = "u64";
var U256_CODER_TYPE = "u256";
var RAW_PTR_CODER_TYPE = "raw untyped ptr";
var RAW_SLICE_CODER_TYPE = "raw untyped slice";
var BOOL_CODER_TYPE = "bool";
var B256_CODER_TYPE = "b256";
var B512_CODER_TYPE = "struct B512";
var OPTION_CODER_TYPE = "enum Option";
var VEC_CODER_TYPE = "struct Vec";
var BYTES_CODER_TYPE = "struct Bytes";
var STD_STRING_CODER_TYPE = "struct String";
var STR_SLICE_CODER_TYPE = "str";
var stringRegEx = /str\[(?<length>[0-9]+)\]/;
var arrayRegEx = /\[(?<item>[\w\s\\[\]]+);\s*(?<length>[0-9]+)\]/;
var structRegEx = /^struct (?<name>\w+)$/;
var enumRegEx = /^enum (?<name>\w+)$/;
var tupleRegEx = /^\((?<items>.*)\)$/;
var genericRegEx = /^generic (?<name>\w+)$/;
var ENCODING_V1 = "1";
var WORD_SIZE = 8;
var BYTES_32 = 32;
var UTXO_ID_LEN = BYTES_32 + 2;
var ASSET_ID_LEN = BYTES_32;
var CONTRACT_ID_LEN = BYTES_32;
var ADDRESS_LEN = BYTES_32;
var NONCE_LEN = BYTES_32;
var TX_LEN = WORD_SIZE * 4;
var TX_POINTER_LEN = WORD_SIZE * 2;
var MAX_BYTES = 2 ** 32 - 1;
var calculateVmTxMemory = ({ maxInputs }) => BYTES_32 + // Tx ID
  ASSET_ID_LEN + // Base asset ID
  // Asset ID/Balance coin input pairs
  maxInputs * (ASSET_ID_LEN + WORD_SIZE) + WORD_SIZE;
var SCRIPT_FIXED_SIZE = WORD_SIZE + // Identifier
  WORD_SIZE + // Gas limit
  WORD_SIZE + // Script size
  WORD_SIZE + // Script data size
  WORD_SIZE + // Policies
  WORD_SIZE + // Inputs size
  WORD_SIZE + // Outputs size
  WORD_SIZE + // Witnesses size
  BYTES_32;
var INPUT_COIN_FIXED_SIZE = WORD_SIZE + // Identifier
  TX_LEN + // Utxo Length
  WORD_SIZE + // Output Index
  ADDRESS_LEN + // Owner
  WORD_SIZE + // Amount
  ASSET_ID_LEN + // Asset id
  TX_POINTER_LEN + // TxPointer
  WORD_SIZE + // Witnesses index
  WORD_SIZE + // Predicate size
  WORD_SIZE + // Predicate data size
  WORD_SIZE;
var INPUT_MESSAGE_FIXED_SIZE = WORD_SIZE + // Identifier
  ADDRESS_LEN + // Sender
  ADDRESS_LEN + // Recipient
  WORD_SIZE + // Amount
  NONCE_LEN + // Nonce
  WORD_SIZE + // witness_index
  WORD_SIZE + // Data size
  WORD_SIZE + // Predicate size
  WORD_SIZE + // Predicate data size
  WORD_SIZE;

// src/utils/utilities.ts
var isUint8Array = (value) => value instanceof Uint8Array;
var hasNestedOption = (coders) => {
  const array = Array.isArray(coders) ? coders : Object.values(coders);
  for (const node of array) {
    if (node.type === OPTION_CODER_TYPE) {
      return true;
    }
    if ("coder" in node && node.coder.type === OPTION_CODER_TYPE) {
      return true;
    }
    if ("coders" in node) {
      const child = hasNestedOption(node.coders);
      if (child) {
        return true;
      }
    }
  }
  return false;
};

// src/encoding/coders/ArrayCoder.ts
var ArrayCoder = class extends Coder {
  coder;
  length;
  #hasNestedOption;
  constructor(coder, length) {
    super("array", `[${coder.type}; ${length}]`, length * coder.encodedLength);
    this.coder = coder;
    this.length = length;
    this.#hasNestedOption = hasNestedOption([coder]);
  }
  encode(value) {
    if (!Array.isArray(value)) {
      throw new import_errors.FuelError(import_errors.ErrorCode.ENCODE_ERROR, `Expected array value.`);
    }
    if (this.length !== value.length) {
      throw new import_errors.FuelError(import_errors.ErrorCode.ENCODE_ERROR, `Types/values length mismatch.`);
    }
    return (0, import_utils.concat)(Array.from(value).map((v) => this.coder.encode(v)));
  }
  decode(data, offset) {
    if (!this.#hasNestedOption && data.length < this.encodedLength || data.length > MAX_BYTES) {
      throw new import_errors.FuelError(import_errors.ErrorCode.DECODE_ERROR, `Invalid array data size.`);
    }
    let newOffset = offset;
    const decodedValue = Array(this.length).fill(0).map(() => {
      let decoded;
      [decoded, newOffset] = this.coder.decode(data, newOffset);
      return decoded;
    });
    return [decodedValue, newOffset];
  }
};

// src/encoding/coders/B256Coder.ts
var import_errors2 = require("@fuel-ts/errors");
var import_math = require("@fuel-ts/math");
var import_utils2 = require("@fuel-ts/utils");
var B256Coder = class extends Coder {
  constructor() {
    super("b256", "b256", WORD_SIZE * 4);
  }
  encode(value) {
    let encodedValue;
    try {
      encodedValue = (0, import_utils2.arrayify)(value);
    } catch (error) {
      throw new import_errors2.FuelError(import_errors2.ErrorCode.ENCODE_ERROR, `Invalid ${this.type}.`);
    }
    if (encodedValue.length !== this.encodedLength) {
      throw new import_errors2.FuelError(import_errors2.ErrorCode.ENCODE_ERROR, `Invalid ${this.type}.`);
    }
    return encodedValue;
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors2.FuelError(import_errors2.ErrorCode.DECODE_ERROR, `Invalid b256 data size.`);
    }
    let bytes = data.slice(offset, offset + this.encodedLength);
    const decoded = (0, import_math.bn)(bytes);
    if (decoded.isZero()) {
      bytes = new Uint8Array(32);
    }
    if (bytes.length !== this.encodedLength) {
      throw new import_errors2.FuelError(import_errors2.ErrorCode.DECODE_ERROR, `Invalid b256 byte data size.`);
    }
    return [(0, import_math.toHex)(bytes, 32), offset + 32];
  }
};

// src/encoding/coders/B512Coder.ts
var import_errors3 = require("@fuel-ts/errors");
var import_math2 = require("@fuel-ts/math");
var import_utils3 = require("@fuel-ts/utils");
var B512Coder = class extends Coder {
  constructor() {
    super("b512", "struct B512", WORD_SIZE * 8);
  }
  encode(value) {
    let encodedValue;
    try {
      encodedValue = (0, import_utils3.arrayify)(value);
    } catch (error) {
      throw new import_errors3.FuelError(import_errors3.ErrorCode.ENCODE_ERROR, `Invalid ${this.type}.`);
    }
    if (encodedValue.length !== this.encodedLength) {
      throw new import_errors3.FuelError(import_errors3.ErrorCode.ENCODE_ERROR, `Invalid ${this.type}.`);
    }
    return encodedValue;
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors3.FuelError(import_errors3.ErrorCode.DECODE_ERROR, `Invalid b512 data size.`);
    }
    let bytes = data.slice(offset, offset + this.encodedLength);
    const decoded = (0, import_math2.bn)(bytes);
    if (decoded.isZero()) {
      bytes = new Uint8Array(64);
    }
    if (bytes.length !== this.encodedLength) {
      throw new import_errors3.FuelError(import_errors3.ErrorCode.DECODE_ERROR, `Invalid b512 byte data size.`);
    }
    return [(0, import_math2.toHex)(bytes, this.encodedLength), offset + this.encodedLength];
  }
};

// src/encoding/coders/BigNumberCoder.ts
var import_errors4 = require("@fuel-ts/errors");
var import_math3 = require("@fuel-ts/math");
var encodedLengths = {
  u64: WORD_SIZE,
  u256: WORD_SIZE * 4
};
var BigNumberCoder = class extends Coder {
  constructor(baseType) {
    super("bigNumber", baseType, encodedLengths[baseType]);
  }
  encode(value) {
    let bytes;
    try {
      bytes = (0, import_math3.toBytes)(value, this.encodedLength);
    } catch (error) {
      throw new import_errors4.FuelError(import_errors4.ErrorCode.ENCODE_ERROR, `Invalid ${this.type}.`);
    }
    return bytes;
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors4.FuelError(import_errors4.ErrorCode.DECODE_ERROR, `Invalid ${this.type} data size.`);
    }
    let bytes = data.slice(offset, offset + this.encodedLength);
    bytes = bytes.slice(0, this.encodedLength);
    if (bytes.length !== this.encodedLength) {
      throw new import_errors4.FuelError(import_errors4.ErrorCode.DECODE_ERROR, `Invalid ${this.type} byte data size.`);
    }
    return [BigInt(import_math3.bn(bytes)), offset + this.encodedLength];
  }
};

// src/encoding/coders/BooleanCoder.ts
var import_errors5 = require("@fuel-ts/errors");
var import_math4 = require("@fuel-ts/math");
var BooleanCoder = class extends Coder {
  options;
  constructor(options = {
    padToWordSize: false
  }) {
    const encodedLength = options.padToWordSize ? WORD_SIZE : 1;
    super("boolean", "boolean", encodedLength);
    this.options = options;
  }
  encode(value) {
    const isTrueBool = value === true || value === false;
    if (!isTrueBool) {
      throw new import_errors5.FuelError(import_errors5.ErrorCode.ENCODE_ERROR, `Invalid boolean value.`);
    }
    return (0, import_math4.toBytes)(value ? 1 : 0, this.encodedLength);
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors5.FuelError(import_errors5.ErrorCode.DECODE_ERROR, `Invalid boolean data size.`);
    }
    const bytes = (0, import_math4.bn)(data.slice(offset, offset + this.encodedLength));
    if (bytes.isZero()) {
      return [false, offset + this.encodedLength];
    }
    if (!bytes.eq((0, import_math4.bn)(1))) {
      throw new import_errors5.FuelError(import_errors5.ErrorCode.DECODE_ERROR, `Invalid boolean value.`);
    }
    return [true, offset + this.encodedLength];
  }
};

// src/encoding/coders/ByteCoder.ts
var import_errors6 = require("@fuel-ts/errors");
var import_math5 = require("@fuel-ts/math");
var ByteCoder = class extends Coder {
  constructor() {
    super("struct", "struct Bytes", WORD_SIZE);
  }
  encode(value) {
    const bytes = value instanceof Uint8Array ? value : new Uint8Array(value);
    const lengthBytes = new BigNumberCoder("u64").encode(bytes.length);
    return new Uint8Array([...lengthBytes, ...bytes]);
  }
  decode(data, offset) {
    if (data.length < WORD_SIZE) {
      throw new import_errors6.FuelError(import_errors6.ErrorCode.DECODE_ERROR, `Invalid byte data size.`);
    }
    const offsetAndLength = offset + WORD_SIZE;
    const lengthBytes = data.slice(offset, offsetAndLength);
    const length = (0, import_math5.bn)(new BigNumberCoder("u64").decode(lengthBytes, 0)[0]).toNumber();
    const dataBytes = data.slice(offsetAndLength, offsetAndLength + length);
    if (dataBytes.length !== length) {
      throw new import_errors6.FuelError(import_errors6.ErrorCode.DECODE_ERROR, `Invalid bytes byte data size.`);
    }
    return [dataBytes, offsetAndLength + length];
  }
};
__publicField(ByteCoder, "memorySize", 1);

// src/encoding/coders/EnumCoder.ts
var import_errors7 = require("@fuel-ts/errors");
var import_math6 = require("@fuel-ts/math");
var import_utils4 = require("@fuel-ts/utils");
var isFullyNativeEnum = (enumCoders) => Object.values(enumCoders).every(
  // @ts-expect-error complicated types
  ({ type, coders }) => type === "()" && JSON.stringify(coders) === JSON.stringify([])
);
var EnumCoder = class extends Coder {
  name;
  coders;
  #caseIndexCoder;
  #encodedValueSize;
  #shouldValidateLength;
  constructor(name, coders) {
    const caseIndexCoder = new BigNumberCoder("u64");
    const encodedValueSize = Object.values(coders).reduce(
      (max, coder) => Math.max(max, coder.encodedLength),
      0
    );
    super(`enum ${name}`, `enum ${name}`, caseIndexCoder.encodedLength + encodedValueSize);
    this.name = name;
    this.coders = coders;
    this.#caseIndexCoder = caseIndexCoder;
    this.#encodedValueSize = encodedValueSize;
    this.#shouldValidateLength = !(this.type === OPTION_CODER_TYPE || hasNestedOption(coders));
  }
  #encodeNativeEnum(value) {
    const valueCoder = this.coders[value];
    const encodedValue = valueCoder.encode([]);
    const caseIndex = Object.keys(this.coders).indexOf(value);
    const padding = new Uint8Array(this.#encodedValueSize - valueCoder.encodedLength);
    return (0, import_utils4.concat)([this.#caseIndexCoder.encode(caseIndex), padding, encodedValue]);
  }
  encode(value) {
    if (typeof value === "string" && this.coders[value]) {
      return this.#encodeNativeEnum(value);
    }
    const [caseKey, ...empty] = Object.keys(value);
    if (!caseKey) {
      throw new import_errors7.FuelError(import_errors7.ErrorCode.INVALID_DECODE_VALUE, "A field for the case must be provided.");
    }
    if (empty.length !== 0) {
      throw new import_errors7.FuelError(import_errors7.ErrorCode.INVALID_DECODE_VALUE, "Only one field must be provided.");
    }
    const valueCoder = this.coders[caseKey];
    const caseIndex = Object.keys(this.coders).indexOf(caseKey);
    const encodedValue = valueCoder.encode(value[caseKey]);
    return new Uint8Array([...this.#caseIndexCoder.encode(caseIndex), ...encodedValue]);
  }

  #decodeNativeEnum(caseKey, newOffset) {
    return [caseKey, newOffset];
  }
  decode(data, offset) {
    if (this.#shouldValidateLength && data.length < this.#encodedValueSize) {
      throw new import_errors7.FuelError(import_errors7.ErrorCode.DECODE_ERROR, `Invalid enum data size.`);
    }
    const caseBytes = new BigNumberCoder("u64").decode(data, offset)[0];
    const caseIndex = (0, import_math6.toNumber)(caseBytes);
    const caseKey = Object.keys(this.coders)[caseIndex];
    if (!caseKey) {
      throw new import_errors7.FuelError(
        import_errors7.ErrorCode.INVALID_DECODE_VALUE,
        `Invalid caseIndex "${caseIndex}". Valid cases: ${Object.keys(this.coders)}.`
      );
    }
    const valueCoder = this.coders[caseKey];
    const offsetAndCase = offset + WORD_SIZE;
    const [decoded, newOffset] = valueCoder.decode(data, offsetAndCase);
    return [{ case: caseKey, payload: decoded }, newOffset];
  }
};

// src/encoding/coders/NumberCoder.ts
var import_errors8 = require("@fuel-ts/errors");
var import_math7 = require("@fuel-ts/math");
var getLength = (baseType) => {
  switch (baseType) {
    case "u8":
      return 1;
    case "u16":
      return 2;
    case "u32":
      return 4;
    default:
      throw new import_errors8.FuelError(import_errors8.ErrorCode.TYPE_NOT_SUPPORTED, `Invalid number type: ${baseType}`);
  }
};
var NumberCoder = class extends Coder {
  baseType;
  options;
  constructor(baseType, options = {
    padToWordSize: false
  }) {
    const length = options.padToWordSize ? WORD_SIZE : getLength(baseType);
    super("number", baseType, length);
    this.baseType = baseType;
    this.options = options;
  }
  encode(value) {
    let bytes;
    try {
      bytes = (0, import_math7.toBytes)(value);
    } catch (error) {
      throw new import_errors8.FuelError(import_errors8.ErrorCode.ENCODE_ERROR, `Invalid ${this.baseType}.`);
    }
    if (bytes.length > this.encodedLength) {
      throw new import_errors8.FuelError(import_errors8.ErrorCode.ENCODE_ERROR, `Invalid ${this.baseType}, too many bytes.`);
    }
    return (0, import_math7.toBytes)(bytes, this.encodedLength);
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors8.FuelError(import_errors8.ErrorCode.DECODE_ERROR, `Invalid number data size.`);
    }
    const bytes = data.slice(offset, offset + this.encodedLength);
    if (bytes.length !== this.encodedLength) {
      throw new import_errors8.FuelError(import_errors8.ErrorCode.DECODE_ERROR, `Invalid number byte data size.`);
    }
    return [(0, import_math7.toNumber)(bytes), offset + this.encodedLength];
  }
};

// src/encoding/coders/OptionCoder.ts
var OptionCoder = class extends EnumCoder {
  encode(value) {
    const result = super.encode(this.toSwayOption(value));
    return result;
  }
  toSwayOption(input) {
    if (input !== void 0) {
      return { Some: input };
    }
    return { None: [] };
  }
  decode(data, offset) {
    const [decoded, newOffset] = super.decode(data, offset);
    return [decoded.case === "Some" ? decoded.payload : void 0, newOffset];
  }
  toOption(output) {
    if (output.case === "Some") {
      return output.payload;
    }
    return void 0;
  }
};

// src/encoding/coders/RawSliceCoder.ts
var import_errors9 = require("@fuel-ts/errors");
var import_math8 = require("@fuel-ts/math");
var RawSliceCoder = class extends Coder {
  constructor() {
    super("raw untyped slice", "raw untyped slice", WORD_SIZE);
  }
  encode(value) {
    if (!Array.isArray(value)) {
      throw new import_errors9.FuelError(import_errors9.ErrorCode.ENCODE_ERROR, `Expected array value.`);
    }
    const internalCoder = new ArrayCoder(new NumberCoder("u8"), value.length);
    const bytes = internalCoder.encode(value);
    const lengthBytes = new BigNumberCoder("u64").encode(bytes.length);
    return new Uint8Array([...lengthBytes, ...bytes]);
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors9.FuelError(import_errors9.ErrorCode.DECODE_ERROR, `Invalid raw slice data size.`);
    }
    const offsetAndLength = offset + WORD_SIZE;
    const lengthBytes = data.slice(offset, offsetAndLength);
    const length = (0, import_math8.bn)(new BigNumberCoder("u64").decode(lengthBytes, 0)[0]).toNumber();
    const dataBytes = data.slice(offsetAndLength, offsetAndLength + length);
    if (dataBytes.length !== length) {
      throw new import_errors9.FuelError(import_errors9.ErrorCode.DECODE_ERROR, `Invalid raw slice byte data size.`);
    }
    const internalCoder = new ArrayCoder(new NumberCoder("u8"), length);
    const [decodedValue] = internalCoder.decode(dataBytes, 0);
    return [decodedValue, offsetAndLength + length];
  }
};

// src/encoding/coders/StdStringCoder.ts
var import_errors10 = require("@fuel-ts/errors");
var import_math9 = require("@fuel-ts/math");
var import_utils5 = require("@fuel-ts/utils");
var StdStringCoder = class extends Coder {
  constructor() {
    super("struct", "struct String", WORD_SIZE);
  }
  encode(value) {
    const bytes = (0, import_utils5.toUtf8Bytes)(value);
    const lengthBytes = new BigNumberCoder("u64").encode(value.length);
    return new Uint8Array([...lengthBytes, ...bytes]);
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors10.FuelError(import_errors10.ErrorCode.DECODE_ERROR, `Invalid std string data size.`);
    }
    const offsetAndLength = offset + WORD_SIZE;
    const lengthBytes = data.slice(offset, offsetAndLength);
    const length = (0, import_math9.bn)(new BigNumberCoder("u64").decode(lengthBytes, 0)[0]).toNumber();
    const dataBytes = data.slice(offsetAndLength, offsetAndLength + length);
    if (dataBytes.length !== length) {
      throw new import_errors10.FuelError(import_errors10.ErrorCode.DECODE_ERROR, `Invalid std string byte data size.`);
    }
    return [(0, import_utils5.toUtf8String)(dataBytes), offsetAndLength + length];
  }
};
__publicField(StdStringCoder, "memorySize", 1);

// src/encoding/coders/StrSliceCoder.ts
var import_errors11 = require("@fuel-ts/errors");
var import_math10 = require("@fuel-ts/math");
var import_utils6 = require("@fuel-ts/utils");
var StrSliceCoder = class extends Coder {
  constructor() {
    super("strSlice", "str", WORD_SIZE);
  }
  encode(value) {
    const bytes = (0, import_utils6.toUtf8Bytes)(value);
    const lengthBytes = new BigNumberCoder("u64").encode(value.length);
    return new Uint8Array([...lengthBytes, ...bytes]);
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors11.FuelError(import_errors11.ErrorCode.DECODE_ERROR, `Invalid string slice data size.`);
    }
    const offsetAndLength = offset + WORD_SIZE;
    const lengthBytes = data.slice(offset, offsetAndLength);
    const length = (0, import_math10.bn)(new BigNumberCoder("u64").decode(lengthBytes, 0)[0]).toNumber();
    const bytes = data.slice(offsetAndLength, offsetAndLength + length);
    if (bytes.length !== length) {
      throw new import_errors11.FuelError(import_errors11.ErrorCode.DECODE_ERROR, `Invalid string slice byte data size.`);
    }
    return [(0, import_utils6.toUtf8String)(bytes), offsetAndLength + length];
  }
};
__publicField(StrSliceCoder, "memorySize", 1);

// src/encoding/coders/StringCoder.ts
var import_errors12 = require("@fuel-ts/errors");
var import_utils7 = require("@fuel-ts/utils");
var StringCoder = class extends Coder {
  constructor(length) {
    super("string", `str[${length}]`, length);
  }
  encode(value) {
    if (value.length !== this.encodedLength) {
      throw new import_errors12.FuelError(import_errors12.ErrorCode.ENCODE_ERROR, `Value length mismatch during encode.`);
    }
    return (0, import_utils7.toUtf8Bytes)(value);
  }
  decode(data, offset) {
    if (data.length < this.encodedLength) {
      throw new import_errors12.FuelError(import_errors12.ErrorCode.DECODE_ERROR, `Invalid string data size.`);
    }
    const bytes = data.slice(offset, offset + this.encodedLength);
    if (bytes.length !== this.encodedLength) {
      throw new import_errors12.FuelError(import_errors12.ErrorCode.DECODE_ERROR, `Invalid string byte data size.`);
    }
    return [(0, import_utils7.toUtf8String)(bytes), offset + this.encodedLength];
  }
};

// src/encoding/coders/StructCoder.ts
var import_errors13 = require("@fuel-ts/errors");
var import_utils8 = require("@fuel-ts/utils");
var StructCoder = class extends Coder {
  name;
  coders;
  #hasNestedOption;
  constructor(name, coders) {
    const encodedLength = Object.values(coders).reduce(
      (acc, coder) => acc + coder.encodedLength,
      0
    );
    super("struct", `struct ${name}`, encodedLength);
    this.name = name;
    this.coders = coders;
    this.#hasNestedOption = hasNestedOption(coders);
  }
  encode(value) {
    return (0, import_utils8.concatBytes)(
      Object.keys(this.coders).map((fieldName) => {
        const fieldCoder = this.coders[fieldName];
        const fieldValue = value[fieldName];
        if (!(fieldCoder instanceof OptionCoder) && fieldValue == null) {
          throw new import_errors13.FuelError(
            import_errors13.ErrorCode.ENCODE_ERROR,
            `Invalid ${this.type}. Field "${fieldName}" not present.`
          );
        }
        return fieldCoder.encode(fieldValue);
      })
    );
  }
  decode(data, offset) {
    if (!this.#hasNestedOption && data.length < this.encodedLength) {
      throw new import_errors13.FuelError(import_errors13.ErrorCode.DECODE_ERROR, `Invalid struct data size.`);
    }
    let newOffset = offset;
    const decodedValue = Object.keys(this.coders).reduce((obj, fieldName) => {
      const fieldCoder = this.coders[fieldName];
      let decoded;
      [decoded, newOffset] = fieldCoder.decode(data, newOffset);
      obj[fieldName] = decoded;
      return obj;
    }, {});
    return [decodedValue, newOffset];
  }
};

// src/encoding/coders/TupleCoder.ts
var import_errors14 = require("@fuel-ts/errors");
var import_utils9 = require("@fuel-ts/utils");
var TupleCoder = class extends Coder {
  coders;
  #hasNestedOption;
  constructor(coders) {
    const encodedLength = coders.reduce((acc, coder) => acc + coder.encodedLength, 0);
    super("tuple", `(${coders.map((coder) => coder.type).join(", ")})`, encodedLength);
    this.coders = coders;
    this.#hasNestedOption = hasNestedOption(coders);
  }
  encode(value) {
    if (this.coders.length !== value.length) {
      throw new import_errors14.FuelError(import_errors14.ErrorCode.ENCODE_ERROR, `Types/values length mismatch.`);
    }
    return (0, import_utils9.concatBytes)(this.coders.map((coder, i) => coder.encode(value[i])));
  }
  decode(data, offset) {
    if (!this.#hasNestedOption && data.length < this.encodedLength) {
      throw new import_errors14.FuelError(import_errors14.ErrorCode.DECODE_ERROR, `Invalid tuple data size.`);
    }
    let newOffset = offset;
    const decodedValue = this.coders.map((coder) => {
      let decoded;
      [decoded, newOffset] = coder.decode(data, newOffset);
      return decoded;
    });
    return [decodedValue, newOffset];
  }
};

// src/encoding/coders/VecCoder.ts
var import_errors15 = require("@fuel-ts/errors");
var import_math11 = require("@fuel-ts/math");
var import_utils10 = require("@fuel-ts/utils");
var VecCoder = class extends Coder {
  coder;
  #hasNestedOption;
  constructor(coder) {
    super("struct", `struct Vec`, coder.encodedLength + WORD_SIZE);
    this.coder = coder;
    this.#hasNestedOption = hasNestedOption([coder]);
  }
  encode(value) {
    if (!Array.isArray(value) && !isUint8Array(value)) {
      throw new import_errors15.FuelError(
        import_errors15.ErrorCode.ENCODE_ERROR,
        `Expected array value, or a Uint8Array. You can use arrayify to convert a value to a Uint8Array.`
      );
    }
    const lengthCoder = new BigNumberCoder("u64");
    if (isUint8Array(value)) {
      return new Uint8Array([...lengthCoder.encode(value.length), ...value]);
    }
    const bytes = value.map((v) => this.coder.encode(v));
    const lengthBytes = lengthCoder.encode(value.length);
    return new Uint8Array([...lengthBytes, ...(0, import_utils10.concatBytes)(bytes)]);
  }
  decode(data, offset) {
    if (!this.#hasNestedOption && data.length < this.encodedLength || data.length > MAX_BYTES) {
      throw new import_errors15.FuelError(import_errors15.ErrorCode.DECODE_ERROR, `Invalid vec data size.`);
    }
    const offsetAndLength = offset + WORD_SIZE;
    const lengthBytes = data.slice(offset, offsetAndLength);
    const length = (0, import_math11.bn)(new BigNumberCoder("u64").decode(lengthBytes, 0)[0]).toNumber();
    const dataLength = length * this.coder.encodedLength;
    const dataBytes = data.slice(offsetAndLength, offsetAndLength + dataLength);
    if (!this.#hasNestedOption && dataBytes.length !== dataLength) {
      throw new import_errors15.FuelError(import_errors15.ErrorCode.DECODE_ERROR, `Invalid vec byte data size.`);
    }
    let newOffset = offsetAndLength;
    const chunks = [];
    for (let i = 0; i < length; i++) {
      const [decoded, optionOffset] = this.coder.decode(data, newOffset);
      chunks.push(decoded);
      newOffset = optionOffset;
    }
    return [chunks, newOffset];
  }
};

// src/Interface.ts
var import_errors20 = require("@fuel-ts/errors");
var import_utils12 = require("@fuel-ts/utils");

// src/utils/json-abi.ts
var import_errors16 = require("@fuel-ts/errors");
var getEncodingVersion = (encoding) => {
  switch (encoding) {
    case void 0:
    case ENCODING_V1:
      return ENCODING_V1;
    default:
      throw new import_errors16.FuelError(
        import_errors16.ErrorCode.UNSUPPORTED_ENCODING_VERSION,
        `Encoding version '${encoding}' is unsupported.`
      );
  }
};
var findFunctionByName = (abi, name) => {
  const fn = abi.functions.find((f) => f.name === name);
  if (!fn) {
    throw new import_errors16.FuelError(
      import_errors16.ErrorCode.FUNCTION_NOT_FOUND,
      `Function with name '${name}' doesn't exist in the ABI`
    );
  }
  return fn;
};
var findTypeById = (abi, typeId) => {
  const type = abi.types.find((t) => t.typeId === typeId);
  if (!type) {
    throw new import_errors16.FuelError(
      import_errors16.ErrorCode.TYPE_NOT_FOUND,
      `Type with typeId '${typeId}' doesn't exist in the ABI.`
    );
  }
  return type;
};
var findNonEmptyInputs = (abi, inputs) => inputs.filter((input) => findTypeById(abi, input.type).type !== "()");
var findVectorBufferArgument = (components) => {
  const bufferComponent = components.find((c) => c.name === "buf");
  const bufferTypeArgument = bufferComponent?.originalTypeArguments?.[0];
  if (!bufferComponent || !bufferTypeArgument) {
    throw new import_errors16.FuelError(
      import_errors16.ErrorCode.INVALID_COMPONENT,
      `The Vec type provided is missing or has a malformed 'buf' component.`
    );
  }
  return bufferTypeArgument;
};

// src/ResolvedAbiType.ts
var ResolvedAbiType = class {
  abi;
  name;
  type;
  originalTypeArguments;
  components;
  constructor(abi, argument) {
    this.abi = abi;
    this.name = argument.name;
    const type = findTypeById(abi, argument.type);
    this.type = type.type;
    this.originalTypeArguments = argument.typeArguments;
    this.components = ResolvedAbiType.getResolvedGenericComponents(
      abi,
      argument,
      type.components,
      type.typeParameters ?? ResolvedAbiType.getImplicitGenericTypeParameters(abi, type.components)
    );
  }
  static getResolvedGenericComponents(abi, arg, components, typeParameters) {
    if (components === null) {
      return null;
    }
    if (typeParameters === null || typeParameters.length === 0) {
      return components.map((c) => new ResolvedAbiType(abi, c));
    }
    const typeParametersAndArgsMap = typeParameters.reduce(
      (obj, typeParameter, typeParameterIndex) => {
        const o = { ...obj };
        o[typeParameter] = structuredClone(
          arg.typeArguments?.[typeParameterIndex]
        );
        return o;
      },
      {}
    );
    const resolvedComponents = this.resolveGenericArgTypes(
      abi,
      components,
      typeParametersAndArgsMap
    );
    return resolvedComponents.map((c) => new ResolvedAbiType(abi, c));
  }
  static resolveGenericArgTypes(abi, args, typeParametersAndArgsMap) {
    return args.map((arg) => {
      if (typeParametersAndArgsMap[arg.type] !== void 0) {
        return {
          ...typeParametersAndArgsMap[arg.type],
          name: arg.name
        };
      }
      if (arg.typeArguments) {
        return {
          ...structuredClone(arg),
          typeArguments: this.resolveGenericArgTypes(
            abi,
            arg.typeArguments,
            typeParametersAndArgsMap
          )
        };
      }
      const argType = findTypeById(abi, arg.type);
      const implicitTypeParameters = this.getImplicitGenericTypeParameters(abi, argType.components);
      if (implicitTypeParameters && implicitTypeParameters.length > 0) {
        return {
          ...structuredClone(arg),
          typeArguments: implicitTypeParameters.map((itp) => typeParametersAndArgsMap[itp])
        };
      }
      return arg;
    });
  }
  static getImplicitGenericTypeParameters(abi, args, implicitGenericParametersParam) {
    if (!Array.isArray(args)) {
      return null;
    }
    const implicitGenericParameters = implicitGenericParametersParam ?? [];
    args.forEach((a) => {
      const argType = findTypeById(abi, a.type);
      if (genericRegEx.test(argType.type)) {
        implicitGenericParameters.push(argType.typeId);
        return;
      }
      if (!Array.isArray(a.typeArguments)) {
        return;
      }
      this.getImplicitGenericTypeParameters(abi, a.typeArguments, implicitGenericParameters);
    });
    return implicitGenericParameters.length > 0 ? implicitGenericParameters : null;
  }
  getSignature() {
    const prefix = this.getArgSignaturePrefix();
    const content = this.getArgSignatureContent();
    return `${prefix}${content}`;
  }
  getArgSignaturePrefix() {
    const structMatch = structRegEx.test(this.type);
    if (structMatch) {
      return "s";
    }
    const arrayMatch = arrayRegEx.test(this.type);
    if (arrayMatch) {
      return "a";
    }
    const enumMatch = enumRegEx.test(this.type);
    if (enumMatch) {
      return "e";
    }
    return "";
  }
  getArgSignatureContent() {
    if (this.type === "raw untyped ptr") {
      return "rawptr";
    }
    if (this.type === "raw untyped slice") {
      return "rawslice";
    }
    const strMatch = stringRegEx.exec(this.type)?.groups;
    if (strMatch) {
      return `str[${strMatch.length}]`;
    }
    if (this.components === null) {
      return this.type;
    }
    const arrayMatch = arrayRegEx.exec(this.type)?.groups;
    if (arrayMatch) {
      return `[${this.components[0].getSignature()};${arrayMatch.length}]`;
    }
    const typeArgumentsSignature = this.originalTypeArguments !== null ? `<${this.originalTypeArguments.map((a) => new ResolvedAbiType(this.abi, a).getSignature()).join(",")}>` : "";
    const componentsSignature = `(${this.components.map((c) => c.getSignature()).join(",")})`;
    return `${typeArgumentsSignature}${componentsSignature}`;
  }
};

// src/encoding/strategies/getCoderForEncoding.ts
var import_errors18 = require("@fuel-ts/errors");

// src/encoding/strategies/getCoderV1.ts
var import_errors17 = require("@fuel-ts/errors");

// src/encoding/strategies/getCoders.ts
function getCoders(components, options) {
  const { getCoder: getCoder2 } = options;
  return components.reduce((obj, component) => {
    const o = obj;
    o[component.name] = getCoder2(component, options);
    return o;
  }, {});
}

// src/encoding/strategies/getCoderV1.ts
var getCoder = (resolvedAbiType, _options) => {
  switch (resolvedAbiType.type) {
    case U8_CODER_TYPE:
    case U16_CODER_TYPE:
    case U32_CODER_TYPE:
      return new NumberCoder(resolvedAbiType.type);
    case U64_CODER_TYPE:
    case RAW_PTR_CODER_TYPE:
      return new BigNumberCoder("u64");
    case U256_CODER_TYPE:
      return new BigNumberCoder("u256");
    case RAW_SLICE_CODER_TYPE:
      return new RawSliceCoder();
    case BOOL_CODER_TYPE:
      return new BooleanCoder();
    case B256_CODER_TYPE:
      return new B256Coder();
    case B512_CODER_TYPE:
      return new B512Coder();
    case BYTES_CODER_TYPE:
      return new ByteCoder();
    case STD_STRING_CODER_TYPE:
      return new StdStringCoder();
    case STR_SLICE_CODER_TYPE:
      return new StrSliceCoder();
    default:
      break;
  }
  const stringMatch = stringRegEx.exec(resolvedAbiType.type)?.groups;
  if (stringMatch) {
    const length = parseInt(stringMatch.length, 10);
    return new StringCoder(length);
  }
  const components = resolvedAbiType.components;
  const arrayMatch = arrayRegEx.exec(resolvedAbiType.type)?.groups;
  if (arrayMatch) {
    const length = parseInt(arrayMatch.length, 10);
    const arg = components[0];
    if (!arg) {
      throw new import_errors17.FuelError(
        import_errors17.ErrorCode.INVALID_COMPONENT,
        `The provided Array type is missing an item of 'component'.`
      );
    }
    const arrayElementCoder = getCoder(arg);
    return new ArrayCoder(arrayElementCoder, length);
  }
  if (resolvedAbiType.type === VEC_CODER_TYPE) {
    const arg = findVectorBufferArgument(components);
    const argType = new ResolvedAbiType(resolvedAbiType.abi, arg);
    const itemCoder = getCoder(argType, { encoding: ENCODING_V1 });
    return new VecCoder(itemCoder);
  }
  const structMatch = structRegEx.exec(resolvedAbiType.type)?.groups;
  if (structMatch) {
    const coders = getCoders(components, { getCoder });
    return new StructCoder(structMatch.name, coders);
  }
  const enumMatch = enumRegEx.exec(resolvedAbiType.type)?.groups;
  if (enumMatch) {
    const coders = getCoders(components, { getCoder });
    const isOptionEnum = resolvedAbiType.type === OPTION_CODER_TYPE;
    if (isOptionEnum) {
      return new OptionCoder(enumMatch.name, coders);
    }
    return new EnumCoder(enumMatch.name, coders);
  }
  const tupleMatch = tupleRegEx.exec(resolvedAbiType.type)?.groups;
  if (tupleMatch) {
    const coders = components.map((component) => getCoder(component, { encoding: ENCODING_V1 }));
    return new TupleCoder(coders);
  }
  throw new import_errors17.FuelError(
    import_errors17.ErrorCode.CODER_NOT_FOUND,
    `Coder not found: ${JSON.stringify(resolvedAbiType)}.`
  );
};

// src/encoding/strategies/getCoderForEncoding.ts
function getCoderForEncoding(encoding = ENCODING_V1) {
  switch (encoding) {
    case ENCODING_V1:
      return getCoder;
    default:
      throw new import_errors18.FuelError(
        import_errors18.ErrorCode.UNSUPPORTED_ENCODING_VERSION,
        `Encoding version ${encoding} is unsupported.`
      );
  }
}

// src/AbiCoder.ts
var AbiCoder = class {
  static getCoder(abi, argument, options = {
    padToWordSize: false
  }) {
    const resolvedAbiType = new ResolvedAbiType(abi, argument);
    return getCoderForEncoding(options.encoding)(resolvedAbiType, options);
  }
  static getLogDecoder(abi, logId, options = {
    padToWordSize: false
  }) {
    const loggedType = abi.loggedTypes.find((type) => type.logId === logId);
    if (!loggedType) {
      throw new import_errors20.FuelError(
        import_errors20.ErrorCode.LOG_TYPE_NOT_FOUND,
        `Log type with logId '${logId}' doesn't exist in the ABI.`
      );
    }
    const resolvedAbiType = new ResolvedAbiType(abi, loggedType.loggedType);
    const internalCoder = getCoderForEncoding(options.encoding)(resolvedAbiType, options);
    return (data) => internalCoder.decode(import_utils12.arrayify(data), 0)[0];
  }
  static encode(abi, argument, value, options) {
    return this.getCoder(abi, argument, options).encode(value);
  }
  static decode(abi, argument, data, offset, options) {
    return this.getCoder(abi, argument, options).decode(data, offset);
  }
};

// src/FunctionFragment.ts
var import_crypto = require("@fuel-ts/crypto");
var import_errors19 = require("@fuel-ts/errors");
var import_hasher = require("@fuel-ts/hasher");
var import_math12 = require("@fuel-ts/math");
var import_utils11 = require("@fuel-ts/utils");
var FunctionFragment = class {
  signature;
  selector;
  selectorBytes;
  encoding;
  name;
  jsonFn;
  attributes;
  jsonAbi;
  constructor(jsonAbi, name) {
    this.jsonAbi = jsonAbi;
    this.jsonFn = findFunctionByName(this.jsonAbi, name);
    this.name = name;
    this.signature = FunctionFragment.getSignature(this.jsonAbi, this.jsonFn);
    this.selector = FunctionFragment.getFunctionSelector(this.signature);
    this.selectorBytes = new StdStringCoder().encode(name);
    this.encoding = getEncodingVersion(jsonAbi.encoding);
    this.attributes = this.jsonFn.attributes ?? [];
  }
  static getSignature(abi, fn) {
    const inputsSignatures = fn.inputs.map(
      (input) => new ResolvedAbiType(abi, input).getSignature()
    );
    return `${fn.name}(${inputsSignatures.join(",")})`;
  }
  static getFunctionSelector(functionSignature) {
    const hashedFunctionSignature = (0, import_hasher.sha256)((0, import_crypto.bufferFromString)(functionSignature, "utf-8"));
    return (0, import_math12.bn)(hashedFunctionSignature.slice(0, 10)).toHex(8);
  }
  encodeArguments(values) {
    FunctionFragment.verifyArgsAndInputsAlign(values, this.jsonFn.inputs, this.jsonAbi);
    const shallowCopyValues = values.slice();
    const nonEmptyInputs = findNonEmptyInputs(this.jsonAbi, this.jsonFn.inputs);
    if (Array.isArray(values) && nonEmptyInputs.length !== values.length) {
      shallowCopyValues.length = this.jsonFn.inputs.length;
      shallowCopyValues.fill(void 0, values.length);
    }
    const coders = nonEmptyInputs.map(
      (t) => AbiCoder.getCoder(this.jsonAbi, t, {
        encoding: this.encoding
      })
    );
    return new TupleCoder(coders).encode(shallowCopyValues);
  }
  static verifyArgsAndInputsAlign(args, inputs, abi) {
    if (args.length === inputs.length) {
      return;
    }
    const inputTypes = inputs.map((input) => findTypeById(abi, input.type));
    const optionalInputs = inputTypes.filter(
      (x) => x.type === OPTION_CODER_TYPE || x.type === "()"
    );
    if (optionalInputs.length === inputTypes.length) {
      return;
    }
    if (inputTypes.length - optionalInputs.length === args.length) {
      return;
    }
    const errorMsg = `Mismatch between provided arguments and expected ABI inputs. Provided ${args.length} arguments, but expected ${inputs.length - optionalInputs.length} (excluding ${optionalInputs.length} optional inputs).`;
    throw new import_errors19.FuelError(import_errors19.ErrorCode.ABI_TYPES_AND_VALUES_MISMATCH, errorMsg);
  }
  decodeArguments(data) {
    const bytes = (0, import_utils11.arrayify)(data);
    const nonEmptyInputs = findNonEmptyInputs(this.jsonAbi, this.jsonFn.inputs);
    if (nonEmptyInputs.length === 0) {
      if (bytes.length === 0) {
        return void 0;
      }
      throw new import_errors19.FuelError(
        import_errors19.ErrorCode.DECODE_ERROR,
        `Types/values length mismatch during decode. ${JSON.stringify({
          count: {
            types: this.jsonFn.inputs.length,
            nonEmptyInputs: nonEmptyInputs.length,
            values: bytes.length
          },
          value: {
            args: this.jsonFn.inputs,
            nonEmptyInputs,
            values: bytes
          }
        })}`
      );
    }
    const result = nonEmptyInputs.reduce(
      (obj, input) => {
        const coder = AbiCoder.getCoder(this.jsonAbi, input, { encoding: this.encoding });
        const [decodedValue, decodedValueByteSize] = coder.decode(bytes, obj.offset);
        return {
          decoded: [...obj.decoded, decodedValue],
          offset: obj.offset + decodedValueByteSize
        };
      },
      { decoded: [], offset: 0 }
    );
    return result.decoded;
  }
  decodeOutput(data) {
    const outputAbiType = findTypeById(this.jsonAbi, this.jsonFn.output.type);
    if (outputAbiType.type === "()") {
      return [void 0, 0];
    }
    const bytes = (0, import_utils11.arrayify)(data);
    const coder = AbiCoder.getCoder(this.jsonAbi, this.jsonFn.output, {
      encoding: this.encoding
    });
    return coder.decode(bytes, 0);
  }
  /**
   * Checks if the function is read-only i.e. it only reads from storage, does not write to it.
   *
   * @returns True if the function is read-only or pure, false otherwise.
   */
  isReadOnly() {
    const storageAttribute = this.attributes.find((attr) => attr.name === "storage");
    return !storageAttribute?.arguments.includes("write");
  }
};

// src/Interface.ts
var Interface = class {
  functions;
  configurables;
  jsonAbi;
  encoding;
  constructor(jsonAbi) {
    this.jsonAbi = jsonAbi;
    this.encoding = getEncodingVersion(jsonAbi.encoding);
    this.functions = Object.fromEntries(
      this.jsonAbi.functions.map((x) => [x.name, new FunctionFragment(this.jsonAbi, x.name)])
    );
    this.configurables = Object.fromEntries(this.jsonAbi.configurables.map((x) => [x.name, x]));
  }
  /**
   * Returns function fragment for a dynamic input.
   * @param nameOrSignatureOrSelector - name (e.g. 'transfer'), signature (e.g. 'transfer(address,uint256)') or selector (e.g. '0x00000000a9059cbb') of the function fragment
   */
  getFunction(nameOrSignatureOrSelector) {
    const fn = Object.values(this.functions).find(
      (f) => f.name === nameOrSignatureOrSelector || f.signature === nameOrSignatureOrSelector || f.selector === nameOrSignatureOrSelector
    );
    if (fn !== void 0) {
      return fn;
    }
    throw new import_errors20.FuelError(
      import_errors20.ErrorCode.FUNCTION_NOT_FOUND,
      `function ${nameOrSignatureOrSelector} not found: ${JSON.stringify(fn)}.`
    );
  }
  decodeFunctionData(functionFragment, data) {
    const fragment = typeof functionFragment === "string" ? this.getFunction(functionFragment) : functionFragment;
    return fragment.decodeArguments(data);
  }
  encodeFunctionData(functionFragment, values) {
    const fragment = typeof functionFragment === "string" ? this.getFunction(functionFragment) : functionFragment;
    return fragment.encodeArguments(values);
  }
  // Decode the result of a function call
  decodeFunctionResult(functionFragment, data) {
    const fragment = typeof functionFragment === "string" ? this.getFunction(functionFragment) : functionFragment;
    return fragment.decodeOutput(data);
  }
  decodeLog(data, logId) {
    const loggedType = this.jsonAbi.loggedTypes.find((type) => type.logId === logId);
    if (!loggedType) {
      throw new import_errors20.FuelError(
        import_errors20.ErrorCode.LOG_TYPE_NOT_FOUND,
        `Log type with logId '${logId}' doesn't exist in the ABI.`
      );
    }
    return AbiCoder.decode(this.jsonAbi, loggedType.loggedType, (0, import_utils12.arrayify)(data), 0, {
      encoding: this.encoding
    });
  }
  encodeConfigurable(name, value) {
    const configurable = this.jsonAbi.configurables.find((c) => c.name === name);
    if (!configurable) {
      throw new import_errors20.FuelError(
        import_errors20.ErrorCode.CONFIGURABLE_NOT_FOUND,
        `A configurable with the '${name}' was not found in the ABI.`
      );
    }
    return AbiCoder.encode(this.jsonAbi, configurable.configurableType, value, {
      encoding: this.encoding
    });
  }
  getTypeById(typeId) {
    return findTypeById(this.jsonAbi, typeId);
  }
};
// Annotate the CommonJS export names for ESM import in node:
0 && (module.exports = {
  ASSET_ID_LEN,
  ArrayCoder,
  B256Coder,
  B512Coder,
  BYTES_32,
  BigNumberCoder,
  BooleanCoder,
  ByteCoder,
  CONTRACT_ID_LEN,
  Coder,
  ENCODING_V1,
  EnumCoder,
  INPUT_COIN_FIXED_SIZE,
  Interface,
  NumberCoder,
  OptionCoder,
  RawSliceCoder,
  SCRIPT_FIXED_SIZE,
  StdStringCoder,
  StrSliceCoder,
  StringCoder,
  StructCoder,
  TupleCoder,
  UTXO_ID_LEN,
  VecCoder,
  WORD_SIZE,
  AbiCoder,
  calculateVmTxMemory
});
//# sourceMappingURL=index.js.map
