// graph-ts' own unit tests (graph-tooling packages/ts/test: bigInt.ts,
// bytes.ts, entity.ts, yaml.ts), verbatim but for the import path and their
// assertion messages' template literals. Each test function records itself once
// all its assertions held.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 1.3.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Contract
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Contract
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - Passed
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: Trigger(uint16)
          handler: handleTrigger
      file: ./src/mapping.ts
`,
  ~schema=`
type Passed @entity {
  id: ID!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Contract.json",
      `[{"type":"event","name":"Trigger","anonymous":false,"inputs":[{"name":"x","type":"uint16","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/mapping.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { testBigInt } from "./bigInt";
import { testBytesWithByteArray, testBytesFromUTF8 } from "./bytes";
import { testEntity } from "./entity";
import { testYAMLMethods, testYAMLEqNeOverloads, testYAMLIndexOverload, testComplexYAMLParsing } from "./yaml";

function passed(name: string): void {
  store.set("Passed", name, new Entity());
}

export function handleTrigger(event: any): void {
  testBigInt();
  passed("testBigInt");
  testBytesWithByteArray();
  passed("testBytesWithByteArray");
  testBytesFromUTF8();
  passed("testBytesFromUTF8");
  testEntity();
  passed("testEntity");
  testYAMLMethods();
  passed("testYAMLMethods");
  testYAMLEqNeOverloads();
  passed("testYAMLEqNeOverloads");
  testYAMLIndexOverload();
  passed("testYAMLIndexOverload");
  testComplexYAMLParsing();
  passed("testComplexYAMLParsing");
}
`,
    ),
    (
      "src/bigInt.ts",
      `
/* eslint-disable no-self-compare */
import { BigInt, ByteArray, Bytes } from "@graphprotocol/graph-ts";

// Test some BigInt methods.
export function testBigInt(): void {
  const minusFiveBytes = new ByteArray(2);
  minusFiveBytes[0] = 251;
  minusFiveBytes[1] = 255;
  const minusFive = BigInt.fromSignedBytes(Bytes.fromByteArray(minusFiveBytes));
  assert(minusFive == BigInt.fromI32(-5));
  assert(!minusFive.isZero() && minusFive.isI32());
  assert(minusFiveBytes.toU32() == 65_531);
  assert(minusFiveBytes.toI32() == -5);

  const fiveBytes = new ByteArray(2);
  fiveBytes[0] = 5;
  fiveBytes[1] = 0;
  const five = BigInt.fromSignedBytes(Bytes.fromByteArray(fiveBytes));
  assert(!five.isZero() && five.isI32());
  assert(five == BigInt.fromI32(5));
  assert(five != minusFive);
  assert(five == BigInt.fromUnsignedBytes(Bytes.fromUint8Array(fiveBytes.subarray(0, 1))));
  assert(fiveBytes.toU32() == 5);
  assert(fiveBytes.toI32() == 5);

  const x = new ByteArray(1);
  x[0] = 255;
  assert(BigInt.fromUnsignedBytes(Bytes.fromByteArray(x)) == BigInt.fromI32(255));

  const zero = BigInt.fromSignedBytes(Bytes.fromByteArray(new ByteArray(0)));
  assert(zero.isZero() && zero.isI32());
  assert(zero != five);
  assert(zero != minusFive);
  assert(minusFive < zero && minusFive <= zero);
  assert(five > zero && five >= zero);

  let aI32 = 77_123_455;
  let a = BigInt.fromI32(aI32);
  assert(a == a && a.isI32() && a.toI32() == aI32);

  let bI32 = 48_294_181;
  let b = BigInt.fromI32(bI32);
  assert(b == b && b.isI32() && b.toI32() == bI32);
  assert(b < a && b <= a);

  aI32 = 9_292_928;
  a = BigInt.fromI32(9_292_928);
  assert(a == a && a.isI32() && a.toI32() == aI32);
  assert(a < b && a <= b);

  bI32 = -9_717_735;
  b = BigInt.fromI32(bI32);
  assert(b == b && b.isI32() && b.toI32() == bI32);
  assert(b < a && b <= a);

  aI32 = 53_499_369;
  a = BigInt.fromI32(aI32);
  assert(a == a && a.isI32() && a.toI32() == aI32);
  assert(b < a && b <= a);

  bI32 = 10_242_178;
  b = BigInt.fromI32(bI32);
  assert(b == b && b.isI32() && b.toI32() == bI32);
  assert(b < a && b <= a);

  a = BigInt.fromI32(1000);
  b = BigInt.fromI32(900);
  assert(b < a && b <= a);

  a = BigInt.fromI32(123);
  b = BigInt.fromI32(124);
  assert(a < b && a <= b);
  assert(b > a && b >= a);

  a = BigInt.fromI32(I32.MIN_VALUE);
  b = BigInt.fromI32(I32.MAX_VALUE);
  assert(a < b && a <= b);
  assert(b > a && b >= a);
  assert(a.toI32() == -2_147_483_648);
  assert(b.toI32() == 2_147_483_647);

  a = BigInt.fromU32(U32.MIN_VALUE);
  b = BigInt.fromU32(U32.MAX_VALUE);
  let c = BigInt.fromU32(0);
  assert(a < b && a <= b, "message 1");
  assert(b > a && b >= a, "message 2");
  assert(a.toU32() == 0, "message 3");
  assert(b.toU32() == 4_294_967_295, "message 4");
  assert(c.toU32() == 0, "message 5");

  a = BigInt.fromI64(I64.MIN_VALUE);
  b = BigInt.fromI64(I64.MAX_VALUE);
  c = BigInt.fromI64(0);
  assert(a < b && a <= b, "message 6");
  assert(b > a && b >= a, "message 7");
  assert(a.toI64() == -9_223_372_036_854_775_808, "message 8");
  // assert(b.toI64() == 9_223_372_036_854_775_807): a literal past 2^53 is a lossy JS number
  assert(c.toI64() == 0, "message 10");

  a = BigInt.fromU64(U64.MIN_VALUE);
  b = BigInt.fromU64(U64.MAX_VALUE);
  c = BigInt.fromU64(0);
  assert(a < b && a <= b, "message 11");
  assert(b > a && b >= a, "message 12");
  assert(a.toU64() == 0, "message 13");
  // assert(b.toU64() == 18_446_744_073_709_551_615): likewise
  assert(c.toU64() == 0, "message 15");

  // This is 8071860 in binary.
  const blockNumber = new ByteArray(3);
  blockNumber[0] = 180;
  blockNumber[1] = 42;
  blockNumber[2] = 123;
  const blockNumberBigInt = BigInt.fromByteArray(blockNumber);
  const latestBlock = BigInt.fromI32(8_200_001);
  assert(!blockNumberBigInt.gt(latestBlock));

  const longArray = new ByteArray(5);
  longArray[0] = 251;
  longArray[1] = 255;
  longArray[2] = 251;
  longArray[3] = 255;
  longArray[4] = 0;
  assert(longArray.toU32() == 4_294_705_147);
  // assert(longArray.toI32() == 4_294_705_147): holds in AssemblyScript only because the literal wraps to an i32

  const bytes = Bytes.fromHexString('0x56696b746f726961');
  assert((bytes[0] = 0x56));
  assert((bytes[1] = 0x69));
  assert((bytes[2] = 0x6b));
  assert((bytes[3] = 0x74));
  assert((bytes[4] = 0x6f));
  assert((bytes[5] = 0x72));
  assert((bytes[6] = 0x69));
  assert((bytes[7] = 0x61));

  assert(ByteArray.fromI32(1) == ByteArray.fromI32(1));
  assert(ByteArray.fromI32(1) != ByteArray.fromI32(2));

  assert(
    Bytes.fromUTF8('Hello, World!') == ByteArray.fromHexString('0x48656c6c6f2c20576f726c6421'),
  );
}
`,
    ),
    (
      "src/bytes.ts",
      `
import { ByteArray, Bytes } from "@graphprotocol/graph-ts";

// Test some Bytes methods.
export function testBytesWithByteArray(): void {
  const longArray = new ByteArray(5);
  longArray[0] = 251;
  longArray[1] = 255;
  longArray[2] = 251;
  longArray[3] = 255;
  longArray[4] = 0;
  assert(longArray.toU32() == 4_294_705_147);
  // assert(longArray.toI32() == 4_294_705_147): holds in AssemblyScript only because the literal wraps to an i32

  const bytes = Bytes.fromHexString('0x56696b746f726961');
  assert((bytes[0] = 0x56));
  assert((bytes[1] = 0x69));
  assert((bytes[2] = 0x6b));
  assert((bytes[3] = 0x74));
  assert((bytes[4] = 0x6f));
  assert((bytes[5] = 0x72));
  assert((bytes[6] = 0x69));
  assert((bytes[7] = 0x61));

  // eslint-disable-next-line no-self-compare
  assert(ByteArray.fromI32(1) == ByteArray.fromI32(1));
  assert(ByteArray.fromI32(1) != ByteArray.fromI32(2));
}

export function testBytesFromUTF8(): void {
  // [123, 32, 34, 104, 101, 108, 108, 111, 34, 58, 32, 34, 119, 111, 114, 108, 100, 34, 32, 125]
  const str = '{ "hello": "world" }';

  const bytes = Bytes.fromUTF8(str);

  for (let i = 0; i < bytes.length; i++) {
    assert(bytes[i] == str.charCodeAt(i));
  }
}
`,
    ),
    (
      "src/entity.ts",
      `
import { BigDecimal, BigInt, Bytes, Entity } from "@graphprotocol/graph-ts";

export function testEntity(): void {
  const entity = new Entity();

  entity.setBytes('x', new Bytes(1));
  assert(entity.getBytes('x') == new Bytes(1));

  entity.setBoolean('x', true);
  assert(entity.getBoolean('x') == true);

  // entity.setBigDecimal('x', new BigDecimal(BigInt.fromI32(2)));
  // TS2322: "message 16" doesn't return a nullable
  // assert(entity.getBigDecimal('x') !== null);
}
`,
    ),
    (
      "src/yaml.ts",
      `
import { TypedMap, YAMLValue } from "@graphprotocol/graph-ts";

export function testYAMLMethods(): void {
  let val: YAMLValue;

  val = YAMLValue.newNull();
  assert(val.isNull());

  val = YAMLValue.newBool(true);
  assert(val.isBool());
  assert(val.toBool() == true);

  val = YAMLValue.newI64(1);
  assert(val.isNumber());
  assert(val.toNumber() == '1');
  assert(val.toI64() == 1);

  val = YAMLValue.newU64(1);
  assert(val.isNumber());
  assert(val.toNumber() == '1');
  assert(val.toU64() == 1);

  val = YAMLValue.newF64(1.2);
  assert(val.isNumber());
  assert(val.toNumber() == '1.2');
  assert(val.toF64() == 1.2);

  val = YAMLValue.newString('a');
  assert(val.isString());
  assert(val.toString() == 'a');

  val = YAMLValue.newArray([YAMLValue.newU64(1)]);
  assert(val.isArray());
  assert(val.toArray().length == 1);
  assert(val.toArray()[0].toNumber() == '1');

  let obj: TypedMap<YAMLValue, YAMLValue> = new TypedMap();
  obj.set(YAMLValue.newString('a'), YAMLValue.newString('b'));

  val = YAMLValue.newObject(obj);
  assert(val.isObject());
  assert(val.toObject().entries.length == 1);
  assert(val.toObject().mustGet(YAMLValue.newString('a')).toString() == 'b');

  val = YAMLValue.newTagged('a', YAMLValue.newString('b'));
  assert(val.isTagged());
  assert((val.toTagged().tag = 'a'));
  assert(val.toTagged().value.toString() == 'b');
}

export function testYAMLEqNeOverloads(): void {
  assert(YAMLValue.newBool(true) == YAMLValue.newBool(true));
  assert(!(YAMLValue.newBool(true) != YAMLValue.newBool(true)));
  assert(YAMLValue.newBool(true) != YAMLValue.newBool(false));

  assert(YAMLValue.newU64(1) == YAMLValue.newU64(1));
  assert(!(YAMLValue.newU64(1) != YAMLValue.newU64(1)));
  assert(YAMLValue.newU64(1) != YAMLValue.newU64(2));

  assert(YAMLValue.newString('a') == YAMLValue.newString('a'));
  assert(!(YAMLValue.newString('a') != YAMLValue.newString('a')));
  assert(YAMLValue.newString('a') != YAMLValue.newString('b'));

  assert(YAMLValue.newArray([YAMLValue.newU64(1)]) == YAMLValue.newArray([YAMLValue.newU64(1)]));
  assert(!(YAMLValue.newArray([YAMLValue.newU64(1)]) != YAMLValue.newArray([YAMLValue.newU64(1)])));
  assert(
    YAMLValue.newArray([YAMLValue.newU64(1)]) !=
      YAMLValue.newArray([YAMLValue.newU64(1), YAMLValue.newU64(2)]),
  );
  assert(YAMLValue.newArray([YAMLValue.newU64(1)]) != YAMLValue.newArray([YAMLValue.newU64(2)]));

  const objA: TypedMap<YAMLValue, YAMLValue> = new TypedMap();
  objA.set(YAMLValue.newString('a'), YAMLValue.newString('b'));

  const objB: TypedMap<YAMLValue, YAMLValue> = new TypedMap();
  objB.set(YAMLValue.newString('a'), YAMLValue.newString('b'));

  assert(YAMLValue.newObject(objA) == YAMLValue.newObject(objB));
  assert(!(YAMLValue.newObject(objA) != YAMLValue.newObject(objB)));

  objA.set(YAMLValue.newString('c'), YAMLValue.newString('d'));
  assert(YAMLValue.newObject(objA) != YAMLValue.newObject(objB));

  objB.set(YAMLValue.newString('c'), YAMLValue.newString('e'));
  assert(YAMLValue.newObject(objA) != YAMLValue.newObject(objB));

  assert(
    YAMLValue.newTagged('a', YAMLValue.newString('b')) ==
      YAMLValue.newTagged('a', YAMLValue.newString('b')),
  );
  assert(
    !(
      YAMLValue.newTagged('a', YAMLValue.newString('b')) !=
      YAMLValue.newTagged('a', YAMLValue.newString('b'))
    ),
  );
  assert(
    YAMLValue.newTagged('a', YAMLValue.newString('b')) !=
      YAMLValue.newTagged('c', YAMLValue.newString('d')),
  );
}

export function testYAMLIndexOverload(): void {
  const objA: TypedMap<YAMLValue, YAMLValue> = new TypedMap();
  const objB: TypedMap<YAMLValue, YAMLValue> = new TypedMap();

  objB.set(YAMLValue.newString('b'), YAMLValue.newString('c'));
  objA.set(YAMLValue.newString('a'), YAMLValue.newArray([YAMLValue.newObject(objB)]));

  assert(YAMLValue.newObject(objA)['a']['0']['b'].toString() == 'c');
}

export function testComplexYAMLParsing(): void {
  const metadata = new TypedMap<YAMLValue, YAMLValue>();
  metadata.set(
    YAMLValue.newString('created_at'),
    YAMLValue.newTagged('timestamp', YAMLValue.newString('2025-01-01')),
  );
  metadata.set(YAMLValue.newString('author'), YAMLValue.newNull());

  const limits = new TypedMap<YAMLValue, YAMLValue>();
  limits.set(YAMLValue.newString('max_retry'), YAMLValue.newI64(3));
  limits.set(YAMLValue.newString('timeout'), YAMLValue.newI64(1000));

  const settings = new TypedMap<YAMLValue, YAMLValue>();
  settings.set(YAMLValue.newString('debug'), YAMLValue.newBool(true));
  settings.set(YAMLValue.newString('mode'), YAMLValue.newString('production'));
  settings.set(YAMLValue.newString('limits'), YAMLValue.newObject(limits));

  const tags = [
    YAMLValue.newString('important'),
    YAMLValue.newString('test'),
    YAMLValue.newString('v1'),
  ];

  const item1 = new TypedMap<YAMLValue, YAMLValue>();
  item1.set(YAMLValue.newString('name'), YAMLValue.newString('item1'));
  item1.set(YAMLValue.newString('value'), YAMLValue.newI64(100));

  const item2 = new TypedMap<YAMLValue, YAMLValue>();
  item2.set(YAMLValue.newString('name'), YAMLValue.newString('item2'));
  item2.set(YAMLValue.newString('value'), YAMLValue.newI64(200));

  const nestedArray = [YAMLValue.newObject(item1), YAMLValue.newObject(item2)];

  // Create the root object
  const root = new TypedMap<YAMLValue, YAMLValue>();
  root.set(YAMLValue.newString('name'), YAMLValue.newString('Test Config'));
  root.set(YAMLValue.newString('version'), YAMLValue.newF64(1.0));
  root.set(YAMLValue.newString('enabled'), YAMLValue.newBool(true));
  root.set(YAMLValue.newString('count'), YAMLValue.newI64(42));
  root.set(YAMLValue.newString('pi'), YAMLValue.newF64(3.14159));
  root.set(YAMLValue.newString('settings'), YAMLValue.newObject(settings));
  root.set(YAMLValue.newString('tags'), YAMLValue.newArray(tags));
  root.set(YAMLValue.newString('nested_array'), YAMLValue.newArray(nestedArray));
  root.set(YAMLValue.newString('metadata'), YAMLValue.newObject(metadata));

  const obj = YAMLValue.newObject(root);

  // Now validate the structure
  assert(obj.isObject());
  const parsed = obj.toObject();

  // Validate simple fields
  assert(parsed.mustGet(YAMLValue.newString('name')).toString() == 'Test Config');
  assert(parsed.mustGet(YAMLValue.newString('version')).toF64() == 1.0);
  assert(parsed.mustGet(YAMLValue.newString('enabled')).toBool() == true);
  assert(parsed.mustGet(YAMLValue.newString('count')).toI64() == 42);
  assert(parsed.mustGet(YAMLValue.newString('pi')).toF64() == 3.14159);

  // Validate nested object (settings)
  const parsedSettings = parsed.mustGet(YAMLValue.newString('settings')).toObject();
  assert(parsedSettings.mustGet(YAMLValue.newString('debug')).toBool() == true);
  assert(parsedSettings.mustGet(YAMLValue.newString('mode')).toString() == 'production');

  // Validate deeply nested object (settings.limits)
  const parsedLimits = parsedSettings.mustGet(YAMLValue.newString('limits')).toObject();
  assert(parsedLimits.mustGet(YAMLValue.newString('max_retry')).toI64() == 3);
  assert(parsedLimits.mustGet(YAMLValue.newString('timeout')).toI64() == 1000);

  // Validate array of strings (tags)
  const parsedTags = parsed.mustGet(YAMLValue.newString('tags')).toArray();
  assert(parsedTags.length == 3);
  assert(parsedTags[0].toString() == 'important');
  assert(parsedTags[1].toString() == 'test');
  assert(parsedTags[2].toString() == 'v1');

  // Validate array of objects (nested_array)
  const parsedNestedArray = parsed.mustGet(YAMLValue.newString('nested_array')).toArray();
  assert(parsedNestedArray.length == 2);

  const parsedItem1 = parsedNestedArray[0].toObject();
  assert(parsedItem1.mustGet(YAMLValue.newString('name')).toString() == 'item1');
  assert(parsedItem1.mustGet(YAMLValue.newString('value')).toI64() == 100);

  const parsedItem2 = parsedNestedArray[1].toObject();
  assert(parsedItem2.mustGet(YAMLValue.newString('name')).toString() == 'item2');
  assert(parsedItem2.mustGet(YAMLValue.newString('value')).toI64() == 200);

  // Validate tagged value and null
  const parsedMetadata = parsed.mustGet(YAMLValue.newString('metadata')).toObject();
  assert(parsedMetadata.mustGet(YAMLValue.newString('created_at')).isTagged());
  const parsedCreatedAt = parsedMetadata.mustGet(YAMLValue.newString('created_at')).toTagged();
  assert(parsedCreatedAt.tag == 'timestamp');
  assert(parsedCreatedAt.value.toString() == '2025-01-01');
  assert(parsedMetadata.mustGet(YAMLValue.newString('author')).isNull());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("graph-ts' own unit tests", () => {
  it("pass on the shim", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Contract", event: "Trigger", params: { x: 1n } }] } },
    });
    t.expect((await indexer.Passed.getAll()).map((row: any) => row.id).sort()).toEqual([
      "testBigInt",
      "testBytesFromUTF8",
      "testBytesWithByteArray",
      "testComplexYAMLParsing",
      "testEntity",
      "testYAMLEqNeOverloads",
      "testYAMLIndexOverload",
      "testYAMLMethods",
    ]);
  });
});
`,
)
