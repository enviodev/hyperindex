// graph-node's own derived-loaders runner test
// (tests/runner-tests/derived-loaders), its mapping and helpers verbatim: a
// derived field's load() sees entities saved earlier in the same handler, in
// the same block and in an earlier block, without the ones removed since and
// with the latest saves, for String and Bytes ids alike.
let manifest = `
specVersion: 0.0.5
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
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Foo
      abis:
        - name: Contract
          file: ./abis/Contract.json
      eventHandlers:
        - event: TestEvent(string)
          handler: handleTestEvent
      file: ./src/mapping.ts
`

let schema = `
type BFoo @entity {
  id: Bytes!
  value: Int8!
  bar: [BBar!]! @derivedFrom(field: "fooValue")
}

type BBar @entity {
  id: Bytes!
  value: Int8!
  value2: Int8!
  fooValue: BFoo!
}

type BBarTestResult @entity {
  id: Bytes!
  value: Int8!
  value2: Int8!
  fooValue: BFoo!
}

type Foo @entity {
  id: ID!
  value: Int8!
  bar: [Bar!]! @derivedFrom(field: "fooValue")
}

type Bar @entity {
  id: ID!
  value: Int8!
  value2: Int8!
  fooValue: Foo!
}

type BarTestResult @entity {
  id: ID!
  value: Int8!
  value2: Int8!
  fooValue: Foo!
}

type TestResult @entity {
  id: ID!
  barDerived: [BarTestResult!]
  bBarDerived: [BBarTestResult!]
}
`

let abi = `[{"type":"event","name":"TestEvent","anonymous":false,"inputs":[{"name":"testCommand","type":"string","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Contract.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Contract.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/mapping.ts",
      `
import { Bytes, store } from "@graphprotocol/graph-ts";
import { TestEvent } from "../generated/Contract/Contract";
import { Bar, Foo, BFoo, BBar, TestResult } from "../generated/schema";
import {
  assertBBarsArrayEqual,
  assertBBarsEqual,
  assertBarsArrayEqual,
  assertBarsEqual,
  createBBar,
  createBar,
  saveBBarsToTestResult,
  saveBarsToTestResult,
  logTestResult,
} from "./helpers";

export function handleTestEvent(event: TestEvent): void {
  let testResult = new TestResult(event.params.testCommand);
  handleTestEventForID(event, testResult);
  handleTestEventForBytesAsIDs(event, testResult);
  logTestResult(testResult);
  testResult.save();
}

function handleTestEventForID(event: TestEvent, testResult: TestResult): void {
  // This test is to check that the derived entities are loaded correctly
  // in the case where the derived entities are created in the same handler call
  // ie: updates are coming from 'entity_cache.handler_updates'
  if (event.params.testCommand == "1_0") {
    let foo = new Foo("0");
    foo.value = 0;
    foo.save();

    let bar = createBar("0", "0", 0, 0);
    let bar1 = createBar("1", "0", 0, 0);
    let bar2 = createBar("2", "0", 0, 0);

    let fooLoaded = Foo.load("0");
    let barDerived = fooLoaded!.bar.load();

    saveBarsToTestResult(barDerived, testResult, event.params.testCommand);

    // bar0, bar1, bar2 should be loaded
    assertBarsArrayEqual(barDerived, [bar, bar1, bar2]);
  }

  // This test is to check that the derived entities are loaded correctly
  // in the case where the derived entities are created in the same block
  // ie: updates are coming from 'entity_cache.updates'
  if (event.params.testCommand == "1_1") {
    let fooLoaded = Foo.load("0");

    let barLoaded = Bar.load("0");
    barLoaded!.value = 1;
    barLoaded!.save();

    // remove bar1 to test that it is not loaded
    // This tests the case where the entity is present in 'entity_cache.updates' but is removed by
    // An update from 'entity_cache.handler_updates'
    store.remove("Bar", "1");

    let barDerivedLoaded = fooLoaded!.bar.load();
    saveBarsToTestResult(
      barDerivedLoaded,
      testResult,
      event.params.testCommand
    );

    // bar1 should not be loaded as it was removed
    assert(barDerivedLoaded.length == 2, "barDerivedLoaded.length != 2");
    // bar0 should be loaded with the updated value
    assertBarsEqual(barDerivedLoaded[0], barLoaded!);
  }

  if (event.params.testCommand == "2_0") {
    let fooLoaded = Foo.load("0");
    let barDerived = fooLoaded!.bar.load();

    // update bar0
    // This tests the case where the entity is present in 'store' but is updated by
    // An update from 'entity_cache.handler_updates'
    let barLoaded = Bar.load("0");
    barLoaded!.value = 2;
    barLoaded!.save();

    // remove bar2 to test that it is not loaded
    // This tests the case where the entity is present in store but is removed by
    // An update from 'entity_cache.handler_updates'
    store.remove("Bar", "2");

    let barDerivedLoaded = fooLoaded!.bar.load();
    assert(barDerivedLoaded.length == 1, "barDerivedLoaded.length != 1");
    // bar0 should be loaded with the updated value
    assertBarsEqual(barDerivedLoaded[0], barLoaded!);

    saveBarsToTestResult(
      barDerivedLoaded,
      testResult,
      event.params.testCommand
    );
  }
}

// Same as handleTestEventForID but uses Bytes as IDs
function handleTestEventForBytesAsIDs(
  event: TestEvent,
  testResult: TestResult
): void {
  if (event.params.testCommand == "1_0") {
    let bFoo = new BFoo(Bytes.fromUTF8("0"));
    bFoo.value = 0;
    bFoo.save();

    let bBar = createBBar(Bytes.fromUTF8("0"), Bytes.fromUTF8("0"), 0, 0);
    let bBar1 = createBBar(Bytes.fromUTF8("1"), Bytes.fromUTF8("0"), 0, 0);
    let bBar2 = createBBar(Bytes.fromUTF8("2"), Bytes.fromUTF8("0"), 0, 0);

    let bFooLoaded = BFoo.load(Bytes.fromUTF8("0"));
    let bBarDerived: BBar[] = bFooLoaded!.bar.load();

    saveBBarsToTestResult(bBarDerived, testResult, event.params.testCommand);

    assertBBarsArrayEqual(bBarDerived, [bBar, bBar1, bBar2]);
  }

  if (event.params.testCommand == "1_1") {
    let bFooLoaded = BFoo.load(Bytes.fromUTF8("0"));
    let bBarDerived = bFooLoaded!.bar.load();

    let bBarLoaded = BBar.load(Bytes.fromUTF8("0"));
    bBarLoaded!.value = 1;
    bBarLoaded!.save();

    store.remove("BBar", Bytes.fromUTF8("1").toHex());

    let bBarDerivedLoaded = bFooLoaded!.bar.load();
    saveBBarsToTestResult(
      bBarDerivedLoaded,
      testResult,
      event.params.testCommand
    );

    assert(bBarDerivedLoaded.length == 2, "bBarDerivedLoaded.length != 2");
    assertBBarsEqual(bBarDerivedLoaded[0], bBarLoaded!);
  }

  if (event.params.testCommand == "2_0") {
    let bFooLoaded = BFoo.load(Bytes.fromUTF8("0"));
    let bBarDerived = bFooLoaded!.bar.load();

    let bBarLoaded = BBar.load(Bytes.fromUTF8("0"));
    bBarLoaded!.value = 2;
    bBarLoaded!.save();

    store.remove("BBar", Bytes.fromUTF8("2").toHex());

    let bBarDerivedLoaded = bFooLoaded!.bar.load();
    saveBBarsToTestResult(
      bBarDerivedLoaded,
      testResult,
      event.params.testCommand
    );

    assert(bBarDerivedLoaded.length == 1, "bBarDerivedLoaded.length != 1");
    assertBBarsEqual(bBarDerivedLoaded[0], bBarLoaded!);
  }
}`,
    ),
    (
      "src/helpers.ts",
      `
import { Bytes, log } from "@graphprotocol/graph-ts";
import {
  BBar,
  BBarTestResult,
  Bar,
  BarTestResult,
  TestResult,
} from "../generated/schema";

/**
 * Asserts that two 'Bar' instances are equal.
 */
export function assertBarsEqual(a: Bar, b: Bar): void {
  assert(
    a.id == b.id &&
      a.value == b.value &&
      a.value2 == b.value2 &&
      a.fooValue == b.fooValue,
    "Bar instances are not equal"
  );
}

/**
 * Asserts that two 'BBar' instances are equal.
 */
export function assertBBarsEqual(
  a: BBar,
  b: BBar,
  message: string = "BBar instances are not equal"
): void {
  assert(
    a.id.toHex() == b.id.toHex() &&
      a.value == b.value &&
      a.value2 == b.value2 &&
      a.fooValue.toHex() == b.fooValue.toHex(),
    message
  );
}

/**
 * Creates a new 'Bar' entity and saves it.
 */
export function createBar(
  id: string,
  fooValue: string,
  value: i64,
  value2: i64
): Bar {
  let bar = new Bar(id);
  bar.fooValue = fooValue;
  bar.value = value;
  bar.value2 = value2;
  bar.save();
  return bar;
}

/**
 * Creates a new 'BBar' entity and saves it.
 */
export function createBBar(
  id: Bytes,
  fooValue: Bytes,
  value: i64,
  value2: i64
): BBar {
  let bBar = new BBar(id);
  bBar.fooValue = fooValue;
  bBar.value = value;
  bBar.value2 = value2;
  bBar.save();
  return bBar;
}

/**
 * A function to loop over an array of 'Bar' instances and assert that the values are equal.
 */
export function assertBarsArrayEqual(bars: Bar[], expected: Bar[]): void {
  assert(bars.length == expected.length, "bars.length != expected.length");
  for (let i = 0; i < bars.length; i++) {
    assertBarsEqual(bars[i], expected[i]);
  }
}

/**
 * A function to loop over an array of 'BBar' instances and assert that the values are equal.
 */
export function assertBBarsArrayEqual(bBars: BBar[], expected: BBar[]): void {
  assert(bBars.length == expected.length, "bBars.length != expected.length");
  for (let i = 0; i < bBars.length; i++) {
    assertBBarsEqual(bBars[i], expected[i]);
  }
}

export function convertBarToBarTestResult(
  barInstance: Bar,
  testId: string
): BarTestResult {
  const barTestResult = new BarTestResult(barInstance.id + "_" + testId);

  barTestResult.value = barInstance.value;
  barTestResult.value2 = barInstance.value2;
  barTestResult.fooValue = barInstance.fooValue;
  barTestResult.save();

  return barTestResult;
}

export function convertbBarToBBarTestResult(
  bBarInstance: BBar,
  testId: string
): BBarTestResult {
  const bBarTestResult = new BBarTestResult(
    Bytes.fromUTF8(bBarInstance.id.toString() + "_" + testId)
  );

  bBarTestResult.value = bBarInstance.value;
  bBarTestResult.value2 = bBarInstance.value2;
  bBarTestResult.fooValue = bBarInstance.fooValue;
  bBarTestResult.save();

  return bBarTestResult;
}

// convertBarArrayToBarTestResultArray
export function saveBarsToTestResult(
  barArray: Bar[],
  testResult: TestResult,
  testID: string
): void {
  let result: string[] = [];
  for (let i = 0; i < barArray.length; i++) {
    result.push(convertBarToBarTestResult(barArray[i], testID).id);
  }
  testResult.barDerived = result;
}

// convertBBarArrayToBBarTestResultArray
export function saveBBarsToTestResult(
  bBarArray: BBar[],
  testResult: TestResult,
  testID: string
): void {
  let result: Bytes[] = [];
  for (let i = 0; i < bBarArray.length; i++) {
    result.push(convertbBarToBBarTestResult(bBarArray[i], testID).id);
  }
  testResult.bBarDerived = result;
}

export function logTestResult(testResult: TestResult): void {
  log.info("TestResult with ID: {} has barDerived: {} and bBarDerived: {}", [
    testResult.id,
    testResult.barDerived ? testResult.barDerived!.join(", ") : "null",
    testResult.bBarDerived
      ? testResult
          .bBarDerived!.map<string>((b) => b.toHex())
          .join(", ")
      : "null",
  ]);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("graph-node's derived-loaders mapping", () => {
  it("loads derived entities saved in the handler, the block and earlier blocks", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Contract", event: "TestEvent", params: { testCommand: "1_0" }, block: { number: 1 } },
            { contract: "Contract", event: "TestEvent", params: { testCommand: "1_1" }, block: { number: 1 } },
            { contract: "Contract", event: "TestEvent", params: { testCommand: "2_0" }, block: { number: 2 } },
          ],
        },
      },
    });
    const results = (await indexer.TestResult.getAll()).sort((a: any, b: any) => (a.id < b.id ? -1 : 1));
    t.expect(results.map((r: any) => [r.id, r.barDerived, r.bBarDerived])).toEqual([
      ["1_0", ["0_1_0", "1_1_0", "2_1_0"], ["0x305f315f30", "0x315f315f30", "0x325f315f30"]],
      ["1_1", ["0_1_1", "2_1_1"], ["0x305f315f31", "0x325f315f31"]],
      ["2_0", ["0_2_0"], ["0x305f325f30"]],
    ]);
  });
});
`,
)
